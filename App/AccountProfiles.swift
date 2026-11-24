import Foundation
import SwiftUI
import WebKit

/// Account metadata only. Authentication secrets remain in each platform's
/// WebKit profile or the platform-specific Keychain service.
struct ParcelAccountProfile: Codable, Identifiable, Hashable {
    let id: String
    let platform: String
    var nickname: String
    var createdAt: Double
    var isLegacy: Bool
}

@MainActor enum ParcelAccounts {
    private static let storageKey = "native.account.profiles.v1"
    private static let platforms = ["taobao", "jd", "pdd", "fengchao"]
    private static var generations: [String: Int] = [:]
    private static var unlinking = Set<String>()
    static func syncGeneration(_ accountID: String) -> Int { generations[accountID, default: 0] }
    static func canSync(_ platform: String, accountID: String) -> Bool {
        !unlinking.contains(accountID) && accounts(for: platform).contains { $0.id == accountID }
    }
    static func invalidateSync(_ accountID: String) {
        generations[accountID, default: 0] += 1
        NativeWebAutoSync.shared.cancelAccount(accountID)
    }

    static func canonical(_ platform: String) -> String {
        platform == "cainiao" ? "taobao" : platform
    }
    static func legacyID(_ platform: String) -> String {
        "legacy:" + canonical(platform)
    }
    private static var saved: [ParcelAccountProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ParcelAccountProfile].self, from: data)) ?? []
    }
    private static func write(_ list: [ParcelAccountProfile]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
    static func accounts(for platform: String) -> [ParcelAccountProfile] {
        let kind = canonical(platform)
        guard platforms.contains(kind) else { return [] }
        let legacyName = UserDefaults.standard.string(
            forKey: "native.account.legacy.name." + kind) ?? "原有账号"
        let legacy = ParcelAccountProfile(id: legacyID(kind), platform: kind,
                                          nickname: legacyName, createdAt: 0, isLegacy: true)
        return [legacy] + saved.filter { $0.platform == kind }
    }
    static func activeID(for platform: String) -> String {
        let kind = canonical(platform)
        let selected = UserDefaults.standard.string(forKey: "native.account.active." + kind) ?? ""
        return accounts(for: kind).contains(where: { $0.id == selected }) ? selected : legacyID(kind)
    }
    static func select(_ accountID: String, for platform: String) {
        let kind = canonical(platform)
        guard accounts(for: kind).contains(where: { $0.id == accountID }) else { return }
        UserDefaults.standard.set(accountID, forKey: "native.account.active." + kind)
    }
    // A new account is only a draft until the platform verifies its login.
    // Closing the login sheet must never create an unauthorized account.
    static func prepare(_ platform: String) -> ParcelAccountProfile {
        let kind = canonical(platform)
        // "legacy:<platform>" is an always-present compatibility slot,
        // not a real added account. Never count it as account #1.
        let real = saved.filter { $0.platform == kind }
        let occupied = Set(real.compactMap { account -> Int? in
            guard account.nickname.hasPrefix("账号 ") else { return nil }
            return Int(account.nickname.dropFirst("账号 ".count))
        })
        var number = 1
        while occupied.contains(number) { number += 1 }
        return ParcelAccountProfile(id: UUID().uuidString, platform: kind,
                                    nickname: "账号 \(number)",
                                    createdAt: Date().timeIntervalSince1970,
                                    isLegacy: false)
    }

    /// Migrate the old off-by-one default names only when there is no real
    /// legacy login and ALL stored names still follow that original sequence.
    /// Custom nicknames and existing authenticated legacy accounts are kept.
    static func repairDefaultNames(for platform: String, legacyAuthorized: Bool) {
        guard !legacyAuthorized else { return }
        let kind = canonical(platform)
        var all = saved
        let indices = all.indices.filter { all[$0].platform == kind }
        guard !indices.isEmpty else { return }
        for (offset, i) in indices.enumerated() {
            guard all[i].nickname == "账号 \(offset + 2)" else { return }
        }
        for (offset, i) in indices.enumerated() {
            all[i].nickname = "账号 \(offset + 1)"
        }
        write(all)
    }
    static func commitIfAuthorized(_ draft: ParcelAccountProfile) async -> Bool {
        guard !draft.isLegacy, platforms.contains(draft.platform),
              await hasSession(draft.platform, accountID: draft.id) else { return false }
        var list = saved
        if !list.contains(where: { $0.id == draft.id }) {
            list.append(draft)
            write(list)
        }
        return true
    }
    static func discard(_ draft: ParcelAccountProfile) async {
        guard !draft.isLegacy,
              !saved.contains(where: { $0.id == draft.id }),
              let uuid = UUID(uuidString: draft.id) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: uuid)
    }
    static func rename(_ id: String, platform: String, to name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !clean.isEmpty else { return }
        if id == legacyID(platform) {
            UserDefaults.standard.set(clean,
                forKey: "native.account.legacy.name." + canonical(platform))
            return
        }
        var all = saved
        guard let index = all.firstIndex(where: { $0.id == id && $0.platform == canonical(platform) })
        else { return }
        all[index].nickname = clean
        write(all)
    }
    static func displayName(_ accountID: String, platform: String) -> String {
        accounts(for: platform).first(where: { $0.id == accountID })?.nickname ?? "账号"
    }
    static func websiteDataStore(for accountID: String) -> WKWebsiteDataStore {
        guard !accountID.hasPrefix("legacy:"),
              let uuid = UUID(uuidString: accountID) else { return .default() }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }
    static func webStore(for platform: String, accountID: String? = nil) -> WKWebsiteDataStore {
        websiteDataStore(for: accountID ?? activeID(for: platform))
    }
    static func hasSession(_ platform: String, accountID: String) async -> Bool {
        let kind = canonical(platform)
        if kind == "fengchao" { return NativeFengchao.hasSession(for: accountID) }
        if kind == "pdd" && !PddSessionVault.token(for: accountID).isEmpty { return true }
        let domain = kind == "taobao" ? "taobao.com" :
                     kind == "jd" ? "jd.com" : "yangkeduo.com"
        // Gateway cookies alone are not proof of a completed Taobao login.
        let names: Set<String> = kind == "taobao" ?
            ["unb", "tracknick"] :
            kind == "jd" ? ["pt_key"] : ["PDDAccessToken"]
        let cookies = await websiteDataStore(for: accountID).httpCookieStore.allCookies()
        return cookies.contains {
            names.contains($0.name) && !$0.value.isEmpty &&
            ($0.domain == domain || $0.domain.hasSuffix("." + domain) ||
             (kind == "pdd" && ($0.domain == "pinduoduo.net" ||
                                  $0.domain.hasSuffix(".pinduoduo.net")))) &&
            ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
    }
    static func authorizedAccounts(for platform: String) async -> [ParcelAccountProfile] {
        var result: [ParcelAccountProfile] = []
        for account in accounts(for: platform) {
            if canSync(platform, accountID: account.id),
               await hasSession(platform, accountID: account.id),
               canSync(platform, accountID: account.id) { result.append(account) }
        }
        return result
    }
    static func unlink(_ account: ParcelAccountProfile) async throws {
        guard unlinking.insert(account.id).inserted else { return }
        defer { unlinking.remove(account.id) }
        invalidateSync(account.id)
        if account.platform == "taobao" { CainiaoIdentityPhase.clear(account.id) }
        // Capture selection BEFORE removing a UUID profile: after removal,
        // activeID() already falls back to legacy and loses this information.
        let wasDefault = activeID(for: account.platform) == account.id
        if account.platform == "fengchao" { NativeFengchao.logout(for: account.id) }
        if account.platform == "pdd" { PddSessionVault.clear(for: account.id) }
        if account.isLegacy {
            // Leave other platforms' default WebKit data intact.
            let domains = account.platform == "taobao"
                ? ["taobao.com", "cainiao.com"]
                : account.platform == "jd" ? ["jd.com"]
                : ["yangkeduo.com", "pinduoduo.net"]
            let store = WKWebsiteDataStore.default().httpCookieStore
            let cookies = await store.allCookies()
            for cookie in cookies where domains.contains(where: {
                cookie.domain == $0 || cookie.domain.hasSuffix("." + $0)
            }) {
                await store.deleteCookie(cookie)
            }
        } else if let uuid = UUID(uuidString: account.id) {
            // The login/sync WKWebViews must have been dismissed already.
            try await WKWebsiteDataStore.remove(forIdentifier: uuid)
            write(saved.filter { $0.id != account.id })
        }
        ParcelStore.shared.removeImportedParcels(linkedTo: account.id, platform: account.platform)
        if wasDefault {
            // Prefer another genuinely authorized profile. Do not silently
            // switch to an empty legacy placeholder when accounts remain.
            let remaining = accounts(for: account.platform).filter { $0.id != account.id }
            var replacement = legacyID(account.platform)
            for candidate in remaining {
                if await hasSession(account.platform, accountID: candidate.id) {
                    replacement = candidate.id
                    break
                }
            }
            select(replacement, for: account.platform)
        }
    }
}

/// Only the first-party Pinduoduo page can bind, rename, or unbind phones.
/// This WebView uses the SMALL account's isolated WebKit data store. It never
/// intercepts OTPs or sends a recipient's phone number through native APIs.
private struct PddOfficialPhoneManager: UIViewRepresentable {
    let accountID: String
    var useIdentityEntry: Bool = false
    private static let page = URL(string: "https://m.pinduoduo.net/mdkd/cellPhoneList")!
    private static let identityEntry = URL(string: "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE")!

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ParcelAccounts.websiteDataStore(for: accountID)
        // The official /mdkd/ H5 uses api.pinduoduo.com for business calls,
        // while its login scripts also support Pinduoduo's own same-origin
        // /proxy/api/ route. Keep this scoped to the official phone manager.
        // No cookies, OTPs, or tokens are read by the compatibility script.
        let sameOriginCompatibility = #"""
        (() => {
          if (window.top !== window ||
              location.origin !== 'https://m.pinduoduo.net' ||
              !location.pathname.startsWith('/mdkd/') ||
              window.__parcelPddProxyReady) return;
          window.__parcelPddProxyReady = true;
          function route(url) {
            try {
              const u = new URL(String(url), location.href);
              if (u.origin !== 'https://api.pinduoduo.com' ||
                  !u.pathname.startsWith('/api/') || u.username || u.password) {
                return url;
              }
              return location.origin + '/proxy/api' + u.pathname + u.search + u.hash;
            } catch (_) { return url; }
          }
          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function() {
            const args = Array.from(arguments);
            if (args.length > 1) args[1] = route(args[1]);
            return open.apply(this, args);
          };
          if (typeof window.fetch === 'function') {
            const fetch = window.fetch;
            window.fetch = function(input, init) {
              if (typeof Request !== 'undefined' && input instanceof Request) {
                const mapped = route(input.url);
                if (mapped !== input.url) input = new Request(mapped, input);
              } else {
                input = route(input);
              }
              return fetch.call(this, input, init);
            };
          }
        })();
        """#
        configuration.userContentController.addUserScript(
            WKUserScript(source: sameOriginCompatibility,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: useIdentityEntry ? Self.identityEntry : Self.page))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var visitedLogin = false
        private var resumedAfterLogin = false

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            // Keep official verification in this WebView, not in another app.
            decisionHandler(
                scheme == "https" || scheme == "http" || scheme == "about"
                ? .allow : .cancel
            )
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard action.targetFrame == nil,
                  let scheme = action.request.url?.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            webView.load(action.request)
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url,
                  let host = url.host?.lowercased(),
                  host == "pinduoduo.net" || host.hasSuffix(".pinduoduo.net") ||
                  host == "yangkeduo.com" || host.hasSuffix(".yangkeduo.com")
            else { return }
            if url.path.lowercased().contains("login") {
                visitedLogin = true
            } else if visitedLogin && !resumedAfterLogin &&
                      (url.path == "/" || url.path == "/index.html") {
                // The official login can land at its home page. Return once
                // to phone management, never trap the user in a redirect loop.
                resumedAfterLogin = true
                webView.load(URLRequest(url: PddOfficialPhoneManager.page))
            }
        }
    }
}

/// Native iOS presentation inspired by the Xiaomi account settings layout.
/// The official Pinduoduo H5 handles consent, SMS verification and mutations.
@MainActor private struct PddPhoneLinkPage: View {
    let account: ParcelAccountProfile
    @State private var phones: [NativeParcelSync.PddMobile] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var authorized = false
    @State private var resultError: String?
    @State private var officialPage = false
    @State private var officialRevision = 0
    @State private var useIdentityEntry = false
    @State private var askWebConsent = false
    @State private var syncing = false
    @State private var notice: String?
    @AppStorage("native.pdd.webAccessAllowed") private var webEnabled = false
    private let blue = Color(red: 0.19, green: 0.49, blue: 0.96)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("已授权的小号")
                groupCard {
                    HStack(spacing: 13) {
                        Image("brand_pdd")
                            .resizable().scaledToFill()
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.nickname)
                                .font(.system(size: 17, weight: .semibold))
                            Text(authorized ? "已授权" : "需要重新登录")
                                .font(.system(size: 13))
                                .foregroundStyle(authorized ? blue : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                sectionTitle("收件手机号")
                groupCard {
                    HStack {
                        Text("已关联手机号")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button {
                            Task { await refresh() }
                        } label: {
                            if loading { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .disabled(loading)
                        .accessibilityLabel("刷新手机号")
                        .tint(blue)
                    }
                    if loading && !loaded {
                        ProgressView("正在读取手机号…")
                            .frame(maxWidth: .infinity, minHeight: 56)
                    } else if !phones.isEmpty {
                        ForEach(phones) { phone in
                            Divider()
                            HStack(spacing: 11) {
                                Image(systemName: "iphone.gen3")
                                    .foregroundStyle(blue)
                                    .frame(width: 25)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phone.alias.isEmpty ? phone.masked : phone.alias)
                                        .font(.system(size: 15, weight: .medium))
                                    if !phone.alias.isEmpty {
                                        Text(phone.masked)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if phone.commonlyUsed {
                                    Label("常用", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Divider()
                        Text(loaded ? "暂无可显示的关联手机号" : "尚未查询关联手机号")
                            .foregroundStyle(.secondary).font(.subheadline)
                    }
                    if let resultError, !resultError.isEmpty {
                        Text(resultError)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    if webEnabled { officialPage = true }
                    else { askWebConsent = true }
                } label: {
                    Label("绑定 / 管理收件手机号", systemImage: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 57)
                        .background(blue, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .disabled(!authorized)
                .padding(.top, 16)

                Text("使用小号进入拼多多官方页面，绑定主号的收件手机号。验证码、修改备注及解绑操作均由拼多多完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)

                sectionTitle("同步")
                groupCard {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 20))
                            .foregroundStyle(blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("上次同步")
                            let value = UserDefaults.standard.double(
                                forKey: "native.sync.success.pdd." + account.id)
                            Text(value > 0
                                 ? Date(timeIntervalSince1970: value)
                                    .formatted(date: .numeric, time: .shortened)
                                 : "无成功记录")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(syncing ? "同步中…" : "立即同步") {
                            syncPackages()
                        }
                        .buttonStyle(.bordered).tint(blue)
                        .disabled(syncing || !authorized || !webEnabled)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("拼多多收件手机号")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .sheet(isPresented: $officialPage, onDismiss: {
            Task { await refresh() }
        }) {
            NavigationStack {
                VStack(spacing: 0) {
                    PddOfficialPhoneManager(accountID: account.id,
                                            useIdentityEntry: useIdentityEntry)
                        .id("\(officialRevision)-\(useIdentityEntry)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 9) {
                        Text("如果官方网页一直加载，可以切换入口或重新加载")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                officialRevision += 1
                            } label: {
                                Label("重新加载", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                useIdentityEntry.toggle()
                                officialRevision += 1
                            } label: {
                                Label(useIdentityEntry ? "手机号管理" : "身份码入口",
                                      systemImage: "arrow.left.arrow.right")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
                    .navigationTitle("拼多多官方手机号管理")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                officialRevision += 1
                            } label: {
                                Label("重新加载", systemImage: "arrow.clockwise")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { officialPage = false }
                        }
                    }
            }
        }
        .alert("开启拼多多网页访问？", isPresented: $askWebConsent) {
            Button("开启并继续") {
                webEnabled = true
                officialPage = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("网页登录可能影响拼多多官方 App 的登录状态。手机号仍需在官方页面验证。")
        }
        .alert("拼多多", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.top, 27)
            .padding(.bottom, 10)
    }

    private func groupCard<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        authorized = await ParcelAccounts.hasSession("pdd", accountID: account.id)
        guard authorized else {
            phones = []
            resultError = "小号登录已失效，请返回账号列表重新登录。"
            return
        }
        guard webEnabled else {
            phones = []
            resultError = "网页访问已关闭，可在下方点击绑定按钮开启。"
            return
        }
        do {
            phones = try await NativeParcelSync.pddBoundMobiles(accountID: account.id)
            resultError = nil
        } catch {
            phones = []
            resultError = "绑定列表暂不可读取，可打开拼多多官方页面查看或管理。"
        }
    }

    private func syncPackages() {
        guard !syncing, authorized, webEnabled else { return }
        syncing = true
        Task {
            defer { syncing = false }
            do {
                let response = try await NativeParcelSync.run(
                    "pdd", force: true, accountID: account.id)
                notice = response.description
            } catch {
                notice = "同步失败：" + error.localizedDescription
            }
        }
    }
}

struct MultiAccountPage: View {
    @Environment(\.scenePhase) private var scenePhase
    let platformID: String
    @State private var revision = 0
    @State private var validAccounts: Set<String> = []
    @State private var accountsLoaded = false
    @State private var loginAccount: ParcelAccountProfile?
    @State private var draftAccount: ParcelAccountProfile?
    @State private var confirmingLoginID: String?
    @State private var loginError: String?
    @State private var managePhoneAccount: ParcelAccountProfile?
    @State private var cainiaoIdentityAccount: ParcelAccountProfile?
    @State private var cainiaoIdentityPhase: CainiaoIdentityPhase = .loading
    @State private var cainiaoIdentityLogin = false
    @State private var cainiaoIdentityRevision = 0
    @State private var renameAccount: ParcelAccountProfile?
    @State private var renameValue = ""
    @State private var removeAccount: ParcelAccountProfile?
    @State private var busy: String?
    @State private var notice: String?
    @State private var pddConsent = false
    @AppStorage("native.pdd.webAccessAllowed") private var pddWebEnabled = false

    // Taobao and Cainiao intentionally share login storage and the selected
    // account, but their settings entry must retain its own identity.
    private var kind: String { ParcelAccounts.canonical(platformID) }
    private var brandID: String { platformID == "cainiao" ? "cainiao" : kind }
    private var title: String {
        ["taobao": "淘宝", "cainiao": "菜鸟", "jd": "京东",
         "pdd": "拼多多", "fengchao": "丰巢"][brandID] ?? kind
    }
    private var records: [ParcelAccountProfile] { ParcelAccounts.accounts(for: kind) }
    private var currentID: String { ParcelAccounts.activeID(for: kind) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("授权账号")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                let visibleAccounts = records.filter {
                    !$0.isLegacy || validAccounts.contains($0.id)
                }
                if !accountsLoaded {
                    ProgressView("正在核对账号授权…")
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if visibleAccounts.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(.secondary)
                        Text("暂无已授权账号")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 25))
                }
                ForEach(visibleAccounts) { account in
                    accountCard(account)
                }
                Button {
                    loginError = nil
                    let account = ParcelAccounts.prepare(kind)
                    draftAccount = account
                    if kind == "pdd" {
                        pendingPddAccount = account
                        pddConsent = true
                    } else {
                        loginAccount = account
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 21)).foregroundStyle(.blue)
                        Text("添加其他账号")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 19)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 25))
                }
                .buttonStyle(.plain)
                .disabled(!accountsLoaded || loginAccount != nil || pddConsent ||
                          busy != nil || confirmingLoginID != nil)
                if kind == "pdd" {
                    Toggle("允许拼多多网页授权及同步", isOn: $pddWebEnabled)
                        .tint(.blue)
                    Text("小号登录后可通过拼多多官方页面绑定收件手机号。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if kind == "taobao" {
                    Text(brandID == "cainiao"
                        ? "菜鸟使用淘宝账号授权体系；登录页面可能显示淘宝标识。两者共用同一账号与 Cookie，但这里仅管理菜鸟同步。"
                        : "淘宝与菜鸟共用登录账号和 Cookie；此处显示淘宝订单同步，菜鸟驿站同步可在菜鸟入口操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .padding(.bottom, 110)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title + "账号")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .sheet(item: $loginAccount, onDismiss: {
            let unfinished = draftAccount
            draftAccount = nil
            loginError = nil
            Task {
                if let unfinished { await ParcelAccounts.discard(unfinished) }
                await reload()
            }
        }) { account in
            NavigationStack {
                if kind == "fengchao" {
                    FengchaoSMSLoginPage(accountID: account.id) {
                        finishLogin(account)
                    }
                } else if let url = PlatformCatalog.rows.first(where: { $0.id == brandID })?.login {
                    PlatformWebLogin(url: kind == "pdd"
                                     ? URL(string: "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE")!
                                     : url, platformID: brandID,
                                     accountID: account.id) {
                        finishLogin(account)
                    }
                    .navigationTitle(title + "授权 · " + account.nickname)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { loginAccount = nil }
                                .disabled(confirmingLoginID != nil)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                finishLogin(account)
                            } label: {
                                if confirmingLoginID == account.id {
                                    ProgressView()
                                } else {
                                    Text("完成授权")
                                }
                            }
                            .disabled(confirmingLoginID != nil)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(confirmingLoginID != nil)
            .alert("账号授权", isPresented: Binding(
                get: { loginError != nil }, set: { if !$0 { loginError = nil } }
            )) {
                Button("确定") { loginError = nil }
            } message: { Text(loginError ?? "") }
        }
        .sheet(item: $cainiaoIdentityAccount, onDismiss: {
            cainiaoIdentityPhase = .loading
            cainiaoIdentityLogin = false
            Task { await reload() }
        }) { account in
            NavigationStack {
                VStack(spacing: 0) {
                    CainiaoOfficialIdentityWebView(accountID: account.id, authorizationMode: true,
                                                   startWithLogin: cainiaoIdentityLogin,
                                                   navigationRevision: cainiaoIdentityRevision) { phase in
                        guard cainiaoIdentityAccount?.id == account.id else { return }
                        cainiaoIdentityPhase = phase
                        CainiaoIdentityPhase.remember(phase, accountID: account.id)
                    }
                    .id(account.id)
                    Divider()
                    VStack(spacing: 8) {
                        Text(cainiaoIdentityPhase == .ready ? "身份码已验证" :
                             cainiaoIdentityPhase == .authorizationRequired ? "先完成官方登录或验证，再检查身份码" :
                             cainiaoIdentityPhase == .failed ? "暂未加载出库码" : "正在检查身份码")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("淘宝授权") {
                                cainiaoIdentityPhase = .loading
                                cainiaoIdentityLogin = true
                                cainiaoIdentityRevision += 1
                            }
                            .disabled(cainiaoIdentityPhase == .loading)
                            Spacer()
                            Button("检查身份码") {
                                cainiaoIdentityPhase = .loading
                                cainiaoIdentityLogin = false
                                cainiaoIdentityRevision += 1
                            }
                            .disabled(cainiaoIdentityPhase == .loading)
                        }
                        .font(.subheadline)
                    }
                    .padding(12)
                }
                .navigationTitle("菜鸟身份码授权 · " + account.nickname)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { cainiaoIdentityAccount = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成授权") { cainiaoIdentityAccount = nil }
                            .disabled(cainiaoIdentityPhase != .ready)
                    }
                }
            }
        }
        .sheet(item: $managePhoneAccount, onDismiss: {
            Task { await reload() }
        }) { account in
            NavigationStack {
                PddPhoneLinkPage(account: account)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { managePhoneAccount = nil }
                        }
                    }
            }
        }
        .alert("修改账号备注", isPresented: Binding(
            get: { renameAccount != nil }, set: { if !$0 { renameAccount = nil } }
        )) {
            TextField("账号备注", text: $renameValue)
            Button("保存") {
                if let account = renameAccount {
                    ParcelAccounts.rename(account.id, platform: kind, to: renameValue)
                }
                renameAccount = nil
                revision += 1
            }
            Button("取消", role: .cancel) { renameAccount = nil }
        }
        .alert("解除账号授权？", isPresented: Binding(
            get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } }
        )) {
            Button("解除该账号授权", role: .destructive) {
                guard let target = removeAccount else { return }
                removeAccount = nil
                Task {
                    do {
                        try await ParcelAccounts.unlink(target)
                        await reload()
                        notice = "已解除授权，并移除该账号独有的同步包裹；共享包裹与手动添加的内容已保留。"
                    } catch { notice = "删除账号数据失败：" + error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { removeAccount = nil }
        } message: {
            Text("将清除该账号的登录会话和独有同步包裹。其他账号共享的包裹与手动添加的内容会保留。")
        }
        .alert("拼多多网页登录提醒", isPresented: $pddConsent) {
            Button("仍要登录") {
                if let account = pendingPddAccount { loginAccount = account }
                pendingPddAccount = nil
                UserDefaults.standard.set(true, forKey: PddAccountProtection.key)
            }
            Button("取消", role: .cancel) {
                if pendingPddAccount?.id == draftAccount?.id { draftAccount = nil }
                pendingPddAccount = nil
            }
        } message: {
            Text("网页版登录可能使同一拼多多账号在官方 App 中退出。建议用小号登录。")
        }
        .alert("账号管理", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    @State private var pendingPddAccount: ParcelAccountProfile?

    private func finishLogin(_ account: ParcelAccountProfile) {
        guard loginAccount?.id == account.id, confirmingLoginID == nil else { return }
        // Auto-login callbacks and the user's Done button can fire together.
        // A single in-flight verification must own the draft and its store.
        confirmingLoginID = account.id
        Task { @MainActor in
            defer { confirmingLoginID = nil }
            let valid = await ParcelAccounts.hasSession(kind, accountID: account.id)
            guard loginAccount?.id == account.id else { return }
            guard valid else {
                loginError = "尚未验证登录成功。请在当前平台页面完成验证；未授权的账号不会保存。"
                return
            }
            if let draft = draftAccount, draft.id == account.id {
                guard await ParcelAccounts.commitIfAuthorized(draft) else {
                    loginError = "尚未取得有效登录会话，账号不会被保存。"
                    return
                }
                guard loginAccount?.id == account.id else { return }
                ParcelAccounts.select(draft.id, for: kind)
                draftAccount = nil
                notice = "账号已授权并添加，已设为默认账号。"
            }
            loginAccount = nil
            await reload()
            // A verified login should fetch this account's orders immediately;
            // the normal foreground refresh interval may not be due yet.
            // Reuse the existing account-specific synchronization path so
            // Cainiao and Taobao remain distinct and PDD protection is respected.
            await syncAccount(account)
        }
    }

    private func accountCard(_ account: ParcelAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image("brand_" + brandID)
                    .resizable().scaledToFill()
                    .frame(width: 45, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.nickname).font(.headline)
                    Text(validAccounts.contains(account.id) ?
                         "网页登录已授权" : "网页登录状态待验证")
                        .font(.caption)
                        .foregroundStyle(validAccounts.contains(account.id) ?
                                         Color.green : Color.secondary)
                    // Read the timestamp of the platform currently shown.
                    let key = "native.sync.success." + brandID + "." + account.id
                    let cainiaoResult = UserDefaults.standard.string(
                        forKey: "native.sync.result.cainiao." + account.id) ?? ""
                    if brandID == "cainiao" &&
                       (cainiaoResult.contains("会话自动恢复失败") ||
                        cainiaoResult.contains("SESSION_EXPIRED")) {
                        Text("菜鸟接口会话未恢复（网页登录信息仍保留）")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if brandID == "cainiao", let phase = CainiaoIdentityPhase.lastCheck(account.id) {
                        Text(phase.statusText)
                            .font(.caption2)
                            .foregroundStyle(phase == .ready ? Color.green : Color.orange)
                    }
                    let updated = UserDefaults.standard.double(forKey: key)
                    if updated > 0 {
                        Text("上次同步 " + Date(timeIntervalSince1970: updated)
                            .formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if account.id == currentID {
                    Text("默认").font(.caption).foregroundStyle(.blue)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button {
                    if kind == "pdd" {
                        pendingPddAccount = account
                        pddConsent = true
                    } else {
                        if kind == "taobao" {
                            CainiaoIdentityPhase.clear(account.id)
                            ParcelAccounts.invalidateSync(account.id)
                        }
                        loginAccount = account
                    }
                } label: {
                    Label(validAccounts.contains(account.id) ? "重新登录" : "登录",
                          systemImage: "person.crop.circle")
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await syncAccount(account) }
                } label: {
                    Label(busy == account.id ? "同步中" : "同步",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy != nil || !validAccounts.contains(account.id))
                Spacer(minLength: 0)
                Menu {
                    if account.id != currentID && validAccounts.contains(account.id) {
                        Button {
                            ParcelAccounts.select(account.id, for: kind)
                            revision += 1
                        } label: {
                            Label("设为默认", systemImage: "checkmark.circle")
                        }
                    }
                    Button {
                        renameAccount = account
                        renameValue = account.nickname
                    } label: {
                        Label("修改备注", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        removeAccount = account
                    } label: {
                        Label("解除授权", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                        .frame(width: 35, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("账号更多操作")
            }
            .font(.subheadline)
            .controlSize(.regular)
            if brandID == "cainiao" {
                Button {
                    ParcelAccounts.invalidateSync(account.id)
                    cainiaoIdentityPhase = .loading
                    cainiaoIdentityLogin = false
                    cainiaoIdentityRevision += 1
                    cainiaoIdentityAccount = account
                } label: {
                    Label("身份码授权", systemImage: "qrcode")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(busy != nil)
            }
            if kind == "pdd" && validAccounts.contains(account.id) {
                Button {
                    managePhoneAccount = account
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 16))
                        Text("收件手机号管理")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.blue)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 25))
    }

    private func reload() async {
        var found: Set<String> = []
        for account in records {
            if await ParcelAccounts.hasSession(kind, accountID: account.id) {
                found.insert(account.id)
            }
        }
        // Only migrate the old auto-generated 2-based names when the
        // compatibility slot really has no active login.
        ParcelAccounts.repairDefaultNames(
            for: kind, legacyAuthorized: found.contains(ParcelAccounts.legacyID(kind)))
        // Do not probe each account's private phone-binding endpoint merely
        // because the account list appeared. Query only on the detail page.
        validAccounts = found
        accountsLoaded = true
        revision += 1
    }

    private func syncAccount(_ account: ParcelAccountProfile) async {
        guard busy == nil else { return }
        busy = account.id
        defer { busy = nil }
        var messages: [String] = []
        if brandID == "cainiao" {
            // The Cainiao entry is for Cainiao parcel/identity status only.
            // Do not report a Taobao shopping-order cooldown as its failure.
            do {
                let result = try await NativeParcelSync.run(
                    "cainiao", force: true, accountID: account.id)
                messages.append(result.description)
            } catch {
                messages.append("菜鸟同步：" + error.localizedDescription)
            }
        } else if kind == "taobao" {
            let queued = await NativeWebAutoSync.shared.request(
                "taobao", force: true, accountID: account.id)
            if queued {
                messages.append("已安排淘宝购物订单同步（后台队列依次执行）")
            } else if (UserDefaults.standard.object(
                forKey: "native.platform.enabled.taobao") as? Bool) == false {
                messages.append("淘宝购物订单来源已关闭，未发起网页同步")
            } else {
                let reason = await NativeWebAutoSync.shared.lastQueueDecision("taobao", accountID: account.id)
                messages.append("淘宝：" + reason)
            }
            do {
                let result = try await NativeParcelSync.run(
                    "cainiao", force: true, accountID: account.id)
                messages.append("菜鸟驿站：" + result.description)
            } catch {
                messages.append("菜鸟驿站：" + error.localizedDescription)
            }
        } else if kind == "jd" {
            let queued = await NativeWebAutoSync.shared.request(
                "jd", force: true, accountID: account.id)
            let reason = await NativeWebAutoSync.shared.lastQueueDecision("jd", accountID: account.id)
            messages.append(queued ? "已安排京东购物订单同步，可在运行日志查看进度" :
                "京东：" + reason)
        } else {
            do {
                let result = try await NativeParcelSync.run(
                    kind, force: true, accountID: account.id)
                messages.append(result.description)
                if kind == "pdd" && PddAccountProtection.webAccessAllowed {
                    _ = await NativeWebAutoSync.shared.request(
                        "pdd", force: true, accountID: account.id)
                }
            } catch {
                messages.append(error.localizedDescription)
            }
        }
        notice = messages.joined(separator: "\n")
        await reload()
    }
}
