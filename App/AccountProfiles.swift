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
    @discardableResult static func add(_ platform: String) -> ParcelAccountProfile {
        let kind = canonical(platform)
        let all = accounts(for: kind)
        let profile = ParcelAccountProfile(id: UUID().uuidString, platform: kind,
                                           nickname: "账号 \(all.count + 1)",
                                           createdAt: Date().timeIntervalSince1970,
                                           isLegacy: false)
        write(saved + [profile])
        return profile
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
        let names: Set<String> = kind == "taobao" ?
            ["unb", "tracknick", "cookie2", "_m_h5_tk"] :
            kind == "jd" ? ["pt_key"] : ["PDDAccessToken"]
        let cookies = await websiteDataStore(for: accountID).httpCookieStore.allCookies()
        return cookies.contains {
            names.contains($0.name) && !$0.value.isEmpty &&
            ($0.domain == domain || $0.domain.hasSuffix("." + domain)) &&
            ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
    }
    static func authorizedAccounts(for platform: String) async -> [ParcelAccountProfile] {
        var result: [ParcelAccountProfile] = []
        for account in accounts(for: platform) {
            if await hasSession(platform, accountID: account.id) { result.append(account) }
        }
        return result
    }
    static func unlink(_ account: ParcelAccountProfile) async throws {
        if account.platform == "fengchao" { NativeFengchao.logout(for: account.id) }
        if account.platform == "pdd" { PddSessionVault.clear(for: account.id) }
        if account.isLegacy {
            // Leave other platforms' default WebKit data intact.
            let domains = account.platform == "taobao" ? ["taobao.com"] :
                          account.platform == "jd" ? ["jd.com"] : ["yangkeduo.com", "pinduoduo.net"]
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
        if activeID(for: account.platform) == account.id {
            select(legacyID(account.platform), for: account.platform)
        }
    }
}

/// The official Pinduoduo phone-binding screen. Linking another recipient's
/// phone is performed only by the platform's own verification UI.
private struct PddOfficialPhoneManager: UIViewRepresentable {
    let accountID: String
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ParcelAccounts.websiteDataStore(for: accountID)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://m.pinduoduo.net/mdkd/cellPhoneList")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MultiAccountPage: View {
    let platformID: String
    @State private var revision = 0
    @State private var validAccounts: Set<String> = []
    @State private var linkedPddPhones: [String: [NativeParcelSync.PddMobile]] = [:]
    @State private var loginAccount: ParcelAccountProfile?
    @State private var managePhoneAccount: ParcelAccountProfile?
    @State private var renameAccount: ParcelAccountProfile?
    @State private var renameValue = ""
    @State private var removeAccount: ParcelAccountProfile?
    @State private var busy: String?
    @State private var notice: String?
    @State private var pddConsent = false

    private var kind: String { ParcelAccounts.canonical(platformID) }
    private var title: String {
        ["taobao": "淘宝 / 菜鸟", "jd": "京东", "pdd": "拼多多", "fengchao": "丰巢"][kind] ?? kind
    }
    private var records: [ParcelAccountProfile] { ParcelAccounts.accounts(for: kind) }
    private var currentID: String { ParcelAccounts.activeID(for: kind) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(records) { account in
                    accountCard(account)
                }
                Button {
                    let account = ParcelAccounts.add(kind)
                    revision += 1
                    loginAccount = account
                } label: {
                    Label("添加其他账号", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                if kind == "pdd" {
                    Text("建议使用拼多多小号网页登录，再通过官方「关联大号收件手机号」验证大号号码，读取该号码可查询的待取包裹。网页授权可能使同一账号的官方 App 退出。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if kind == "taobao" {
                    Text("淘宝和菜鸟共用每个账号的登录环境；菜鸟身份码跟随当前默认账号。")
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
        .sheet(item: $loginAccount, onDismiss: {
            Task { await reload() }
        }) { account in
            NavigationStack {
                if kind == "fengchao" {
                    FengchaoSMSLoginPage(accountID: account.id) {
                        loginAccount = nil
                        Task { await reload() }
                    }
                } else if let url = PlatformCatalog.rows.first(where: { $0.id == kind })?.login {
                    PlatformWebLogin(url: url, platformID: kind,
                                     accountID: account.id) {
                        loginAccount = nil
                        Task { await reload() }
                    }
                    .navigationTitle("登录 " + account.nickname)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { loginAccount = nil }
                        }
                    }
                }
            }
        }
        .sheet(item: $managePhoneAccount, onDismiss: {
            Task { await reload() }
        }) { account in
            NavigationStack {
                VStack(spacing: 8) {
                    Text("请在拼多多官方页面添加并验证大号的收件手机号。ParcelHelper 不读取短信验证码。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.top, 10)
                    PddOfficialPhoneManager(accountID: account.id)
                }
                .navigationTitle("关联大号收件手机号")
                .navigationBarTitleDisplayMode(.inline)
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
        .confirmationDialog("解除账号授权？", isPresented: Binding(
            get: { removeAccount != nil }, set: { if !$0 { removeAccount = nil } }
        ), titleVisibility: .visible) {
            Button("解除该账号授权", role: .destructive) {
                guard let target = removeAccount else { return }
                removeAccount = nil
                Task {
                    do {
                        try await ParcelAccounts.unlink(target)
                        await reload()
                        notice = "已解除该账号授权，已导入的包裹不会被删除。"
                    } catch { notice = "删除账号数据失败：" + error.localizedDescription }
                }
            }
        } message: {
            Text("只解除选中的账号，不删除已导入的包裹或其他账号。")
        }
        .alert("拼多多网页登录提醒", isPresented: $pddConsent) {
            Button("仍要登录") {
                if let account = pendingPddAccount { loginAccount = account }
                pendingPddAccount = nil
                UserDefaults.standard.set(true, forKey: PddAccountProtection.key)
            }
            Button("取消", role: .cancel) { pendingPddAccount = nil }
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

    private func accountCard(_ account: ParcelAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.blue).font(.system(size: 30))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.nickname).font(.headline)
                    Text(validAccounts.contains(account.id) ? "已授权" : "未授权 / 需要验证")
                        .font(.caption)
                        .foregroundStyle(validAccounts.contains(account.id) ?
                                         Color.green : Color.secondary)
                }
                Spacer()
                if account.id == currentID {
                    Text("默认").font(.caption).foregroundStyle(.blue)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("登录") {
                    if kind == "pdd" {
                        pendingPddAccount = account
                        pddConsent = true
                    } else {
                        loginAccount = account
                    }
                }
                Button("设为默认") {
                    ParcelAccounts.select(account.id, for: kind)
                    revision += 1
                }
                .disabled(account.id == currentID)
                Button(busy == account.id ? "同步中" : "同步") {
                    Task { await syncAccount(account) }
                }
                .disabled(busy != nil || !validAccounts.contains(account.id))
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            if kind == "pdd" && validAccounts.contains(account.id) {
                if let mobiles = linkedPddPhones[account.id], !mobiles.isEmpty {
                    Text("已关联：" + mobiles.map { $0.masked }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("关联大号收件手机号（官方验证）") {
                    managePhoneAccount = account
                }
                .font(.subheadline)
                .foregroundStyle(.blue)
            }
            HStack {
                Button("重命名") {
                    renameAccount = account
                    renameValue = account.nickname
                }
                Spacer()
                Button("解除授权", role: .destructive) { removeAccount = account }
            }
            .font(.caption)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private func reload() async {
        var found: Set<String> = []
        var phones: [String: [NativeParcelSync.PddMobile]] = [:]
        for account in records {
            if await ParcelAccounts.hasSession(kind, accountID: account.id) {
                found.insert(account.id)
                if kind == "pdd" && PddAccountProtection.webAccessAllowed,
                   let mobiles = try? await NativeParcelSync.pddBoundMobiles(accountID: account.id) {
                    phones[account.id] = mobiles
                }
            }
        }
        validAccounts = found
        linkedPddPhones = phones
        revision += 1
    }

    private func syncAccount(_ account: ParcelAccountProfile) async {
        busy = account.id
        defer { busy = nil }
        do {
            if kind == "taobao" || kind == "jd" {
                let queued = await NativeWebAutoSync.shared.request(kind, force: true,
                                                                     accountID: account.id)
                if kind == "taobao" {
                    let result = try? await NativeParcelSync.run("cainiao", force: true,
                                                                   accountID: account.id)
                    notice = (queued ? "已安排淘宝订单同步" : "未能启动订单同步") +
                             (result.map { "；" + $0.description } ?? "")
                } else {
                    notice = queued ? "已安排京东订单同步" : "未检测到有效登录会话"
                }
            } else {
                let result = try await NativeParcelSync.run(kind, force: true,
                                                            accountID: account.id)
                notice = result.description
                if kind == "pdd" && PddAccountProtection.webAccessAllowed {
                    _ = await NativeWebAutoSync.shared.request("pdd", force: true,
                                                                accountID: account.id)
                }
            }
        } catch {
            notice = error.localizedDescription
        }
        await reload()
    }
}
