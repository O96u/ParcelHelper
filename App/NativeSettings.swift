import SwiftUI
import AppIntents
import Combine
import UIKit
import CoreImage.CIFilterBuiltins
import UserNotifications
import WebKit

// Native Settings implementation. The original Scripting-only auth and live-code
// retrieval APIs are not reproduced; this code never fabricates login success.
private enum NativeSettingsUI {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let brand = Color(red: 0.42, green: 0.36, blue: 0.82)
}

struct ProfileSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var nickname = ""
    @AppStorage("native.profile.avatar") private var avatar = "person.crop.circle.fill"
    @State private var saved = false
    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: avatar)
                            .font(.system(size: 48, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 94, height: 94)
                            .background(AppTheme.accent, in: Circle())
                    }
                    Spacer()
                }.padding(.vertical, 12)
                Picker("头像样式", selection: $avatar) {
                    Label("默认", systemImage: "person.crop.circle.fill").tag("person.crop.circle.fill")
                    Label("包裹", systemImage: "shippingbox.circle.fill").tag("shippingbox.circle.fill")
                    Label("笑脸", systemImage: "face.smiling.fill").tag("face.smiling.fill")
                }
                TextField("昵称", text: $nickname)
                    .textInputAutocapitalization(.never)
                    .onSubmit(save)
                Button("保存资料", action: save).disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved { Label("已保存到本机", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            } header: { Text("资料") }
            Section("数据") {
                LabeledContent("包裹总数", value: String(store.snapshot.parcels.count))
                LabeledContent("驿站数量", value: String(store.snapshot.stations.count))
            }
        }
        .navigationTitle("个人资料")
        .onAppear { nickname = store.snapshot.preferences.nickName }
    }
    private func save() {
        let v = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        store.changePreferences { $0.nickName = v }
        saved = true
    }
}

struct PlatformImportHubPage: View {
    var body: some View { PlatformsHome().navigationTitle("平台物流导入") }
}

struct ShortcutsSettingsPage: View {
    @AppStorage("native.clipboard.autoRecognize") private var autoRecognizeClipboard = true

    var body: some View {
        Form {
            Section("系统快捷指令") {
                ShortcutsLink().shortcutsLinkStyle(.automatic)
                Toggle("打开 App 时识别剪贴板", isOn: $autoRecognizeClipboard)
                Text("复制取件短信或 SF、ZT、JT 等快递运单号，打开 App 后可确认导入；不会自动添加。")
                    .font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: "包裹助手支持复制物流短信或订单文字，然后在包裹页面中选择平台物流导入。") {
                    Label("分享导入说明", systemImage: "square.and.arrow.up")
                }
            }
            Section("短信自动化") {
                Text("在「快捷指令 → 自动化 → 信息」设置触发条件，添加「包裹助手·导入快递文字」动作。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("快捷指令与自动化")
    }
}

// Faithful native port of ui/identity.tsx: separate Taobao, Cainiao and PDD
// dynamic identity codes. No manually fabricated identity codes.
private enum IdentityRoute: Hashable, Identifiable {
    case accounts
    case code(String)
    var id: String {
        switch self {
        case .accounts: return "accounts"
        case .code(let value): return "code-" + value
        }
    }
}

struct IdentitySettingsPage: View {
    @AppStorage("native.id.taobao.enabled") private var taobao = true
    @AppStorage("native.id.cainiao.enabled") private var cainiao = true
    @AppStorage("native.id.pdd.enabled") private var pdd = true
    @AppStorage("native.id.jd.enabled") private var jd = true
    @State private var hasSession: [String: Bool] = [:]
    @State private var alert: String?
    @State private var destination: IdentityRoute?

    var body: some View {
        Form {
            Section {
                row("淘宝", "taobao", enabled: $taobao)
                row("菜鸟", "cainiao", enabled: $cainiao)
                row("拼多多", "pdd", enabled: $pdd)
                row("京东", "jd", enabled: $jd)
            } header: { Text("快捷入口设置") } footer: {
                Text("这里只管理首页身份码快捷入口，不影响取件列表。登录统一在「设置 → 账号授权」操作；关闭入口不会解除授权。")
            }
            Section {
                Button {
                    destination = .accounts
                } label: {
                    Label("账号授权", systemImage: "person.badge.key")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("身份码设置")
        .navigationDestination(item: $destination) { selected in
            switch selected {
            case .accounts:
                PlatformAccountsPage()
            case .code(let id):
                if id == "jd" {
                    JDIdentityPage()
                } else {
                    IdentityDetailPage(
                        title: id == "pdd" ? "拼多多" : id == "cainiao" ? "菜鸟" : "淘宝",
                        platform: id
                    )
                }
            }
        }
        .task { await checkLogin() }
        .onAppear { Task { await checkLogin() } }
        .alert("身份码", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("确定") { alert = nil }
        } message: { Text(alert ?? "") }
    }

    private func row(_ name: String, _ id: String, enabled: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image("brand_" + id)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(Circle())
            Button {
                destination = .code(id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.body).foregroundStyle(.primary)
                    Text(hasSession[id] == true
                         ? "已授权 · 动态取件码"
                         : "未授权 · 请前往账号授权")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("显示", isOn: Binding(
                get: { enabled.wrappedValue },
                set: { value in
                    if value && hasSession[id] != true {
                        alert = "请先在「账号授权」中登录" +
                            (id == "pdd" ? "拼多多" : id == "cainiao" ? "菜鸟" :
                              id == "jd" ? "京东" : "淘宝")
                    } else {
                        enabled.wrappedValue = value
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    private func checkLogin() async {
        for platform in ["taobao", "cainiao", "pdd"] {
            hasSession[platform] = await NativeParcelSync.hasIdentitySession(platform)
        }
        hasSession["jd"] = await ParcelAccounts.hasSession(
            "jd", accountID: ParcelAccounts.activeID(for: "jd"))
    }
}

private enum IdentityPresentation: String, Identifiable {
    case qr, barcode
    var id: String { rawValue }
}

struct IdentityDetailPage: View {
    let title: String
    let platform: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var identity: NativeParcelSync.IdentityResult?
    @State private var identityAccountID = ""
    @State private var now = Date()
    @State private var fetching = false
    @State private var authorized = false
    @State private var failure: String?
    @State private var fullScreen: IdentityPresentation?
    @State private var nextAttempt = Date.distantPast
    @State private var notice: String?
    private let blue = Color(red: 0.19, green: 0.49, blue: 0.96)
    private var validCode: String? {
        guard let identity, identity.expiresAt > now, authorized,
              identityAccountID == ParcelAccounts.activeID(for: platform) else {
            return nil
        }
        return identity.code
    }
    private var remaining: Int {
        guard let identity else { return 0 }
        return max(0, Int(identity.expiresAt.timeIntervalSince(now).rounded(.down)))
    }
    private var remainingText: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
    private var qr: UIImage? {
        guard let code = validCode else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(code.utf8)
        generator.correctionLevel = "M"
        guard let ci = generator.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
    private var barcode: UIImage? {
        guard let code = validCode else { return nil }
        let generator = CIFilter.code128BarcodeGenerator()
        generator.message = Data(code.utf8)
        guard let ci = generator.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 3, y: 3))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("默认账号：" + ParcelAccounts.displayName(
                        ParcelAccounts.activeID(for: platform), platform: platform),
                          systemImage: "person.crop.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    NavigationLink {
                        MultiAccountPage(platformID: platform)
                    } label: {
                        Text("管理默认账号").font(.subheadline)
                    }
                }
                if !authorized {
                    VStack(spacing: 15) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 44)).foregroundStyle(blue)
                        Text("当前账号暂时无法获取身份码")
                            .font(.headline)
                        NavigationLink {
                            PlatformAccountsPage()
                        } label: {
                            Text("管理账号授权").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 23))
                } else {
                    VStack(spacing: 14) {
                        if let img = barcode {
                            Button {
                                fullScreen = .barcode
                            } label: {
                                Image(uiImage: img)
                                    .resizable().interpolation(.none)
                                    .scaledToFit().frame(maxWidth: 320, maxHeight: 95)
                                    .padding(12)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                        if let img = qr {
                            Button {
                                fullScreen = .qr
                            } label: {
                                Image(uiImage: img)
                                    .resizable().interpolation(.none)
                                    .scaledToFit()
                                    .frame(width: 185, height: 185)
                                    .padding(10)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                            }.buttonStyle(.plain)
                        } else {
                            Image(systemName: "qrcode")
                                .font(.system(size: 110, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                                .frame(width: 210, height: 210)
                        }
                        if fetching {
                            ProgressView(platform == "cainiao" ? "正在读取菜鸟官方身份码…" : "正在从平台获取身份码…")
                        } else if let _ = validCode {
                            Text("点条码或二维码可全屏出示")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(remainingText + " 后自动换码")
                                .font(.caption).foregroundStyle(remaining < 60 ? Color.red : Color.secondary)
                                .monospacedDigit()
                        } else {
                            Text(identity == nil ? "尚未取得有效身份码" : "身份码已过期，请刷新")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        if platform != "cainiao" && identity?.certified != nil {
                            Label(identity?.certified == true ? "已实名认证" : "未完成实名认证",
                                  systemImage: identity?.certified == true ? "checkmark.shield" : "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(identity?.certified == true ? Color.green : Color.red)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 24))
                    if let mobile = identity?.mobile, platform == "pdd" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("取件人").font(.headline)
                            LabeledContent("绑定手机号", value: mobile)
                        }
                        .padding(18)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 22))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("身份码编号").font(.headline)
                        HStack(spacing: 12) {
                            Image("brand_" + platform)
                                .resizable().scaledToFill().frame(width: 34, height: 34)
                                .clipShape(Circle())
                            Text(validCode ?? "未获取")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .minimumScaleFactor(0.6).lineLimit(1)
                                .textSelection(.enabled)
                            Spacer(minLength: 2)
                            Button("复制") {
                                if let code = validCode {
                                    UIPasteboard.general.string = code
                                    notice = "身份码已复制。请注意它可能很快过期。"
                                }
                            }.disabled(validCode == nil)
                        }
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22))
                }
                if let failure {
                    Text(failure)
                        .font(.subheadline).foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 90)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title + "身份码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }.disabled(fetching)
            }
        }
        .task { await refresh() }
        .onAppear { Task { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refresh() }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
            if let item = identity, date >= item.expiresAt,
               date >= nextAttempt, !fetching {
                nextAttempt = date.addingTimeInterval(15)
                Task { await refresh() }
            }
        }
        .fullScreenCover(item: $fullScreen) { mode in
            IdentityFullScreenCode(
                mode: mode, code: validCode ?? "",
                expiresAt: identity?.expiresAt ?? Date.distantPast,
                image: mode == .qr ? qr : barcode)
        }
        .alert("身份码", isPresented: Binding(get: { notice != nil },
                                             set: { if !$0 { notice = nil } })) {
            Button("确定") { notice = nil }
        } message: { Text(notice ?? "") }
    }
    @MainActor private func refresh() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        let requestedAccountID = ParcelAccounts.activeID(for: platform)
        if requestedAccountID != identityAccountID {
            identity = nil
            authorized = false
        }
        authorized = await NativeParcelSync.hasIdentitySession(platform)
        guard requestedAccountID == ParcelAccounts.activeID(for: platform) else {
            identity = nil
            return
        }
        guard authorized else {
            identity = nil
            failure = nil
            return
        }
        do {
            let response = try await NativeParcelSync.identityCode(platform)
            guard requestedAccountID == ParcelAccounts.activeID(for: platform),
                  !response.code.isEmpty, response.expiresAt > Date() else {
                throw NativeSyncError.badResponse("接口未返回有效身份码")
            }
            identityAccountID = requestedAccountID
            identity = response
            now = Date()
            failure = nil
            nextAttempt = response.expiresAt
        } catch {
            // An expired/revoked code must never remain scannable.
            identity = nil
            failure = error.localizedDescription
        }
    }
}


private struct IdentityFullScreenCode: View {
    @Environment(\.dismiss) private var dismiss
    let mode: IdentityPresentation
    let code: String
    let expiresAt: Date
    let image: UIImage?
    @State private var now = Date()
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 30) {
                Spacer()
                if let image, !code.isEmpty, now < expiresAt {
                    Image(uiImage: image)
                        .resizable().interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: mode == .qr ? 330 : 500,
                               maxHeight: mode == .qr ? 330 : 260)
                        .rotationEffect(mode == .barcode ? .degrees(90) : .degrees(0))
                        .padding(.vertical, mode == .barcode ? 75 : 0)
                } else {
                    Text("身份码已失效，请关闭后刷新")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(code)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                Text(mode == .barcode ? "条形码已放大，请对准扫码口" :
                                         "二维码已放大，请对准扫描区")
                    .font(.caption).foregroundStyle(.gray)
            }
            .padding(.bottom, 35)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline).foregroundStyle(.black)
                            .frame(width: 43, height: 43)
                            .background(Color.black.opacity(0.06), in: Circle())
                    }
                }
                Spacer()
            }.padding(.top, 22).padding(.trailing, 23)
        }
        .preferredColorScheme(.light)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) {
            now = $0
            if now >= expiresAt { dismiss() }
        }
    }
}

struct ReminderSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @AppStorage("native.reminder.arrival") private var onArrival = true
    @AppStorage("native.reminder.dispatch") private var onDispatch = true
    @AppStorage("native.reminder.transit") private var onTransit = false
    @AppStorage("native.reminder.failure") private var onFailure = true
    @State private var permission = "未检查"
    var body: some View {
        Form {
            Section("通知权限") {
                LabeledContent("系统通知", value: permission)
                Button("请求通知权限") { Task {
                    _ = await ParcelNotifications.requestPermission()
                    await checkPermission()
                } }
            }
            Section("取件提醒") {
                Toggle("启用通知提醒", isOn: Binding(get: { store.snapshot.preferences.reminderEnabled }, set: { v in
                    store.changePreferences { $0.reminderEnabled = v }
                    if v { Task { _ = await ParcelNotifications.requestPermission() } }
                }))
                Toggle("运输节点更新提醒", isOn: $onTransit)
                Toggle("正在派送提醒", isOn: $onDispatch)
                Toggle("包裹到站提醒", isOn: $onArrival)
                Toggle("同步失败提醒", isOn: $onFailure)
                Stepper("超时提醒：\(store.snapshot.preferences.reminderAfterHours) 小时", value: Binding(
                    get: { store.snapshot.preferences.reminderAfterHours },
                    set: { value in store.changePreferences { $0.reminderAfterHours = value } }), in: 1...168)
            }
            Section {
                Text("仅在成功同步到新状态时提醒；后台通知时机由 iOS 决定。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("取件提醒")
         .task { await checkPermission() }
    }
    private func checkPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "已拒绝"
        default: "未允许"
        }
    }
}

struct AppearanceSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @AppStorage("native.appearance.color") private var themeColor = "blue"
    var body: some View {
        Form {
            Section("外观") {
                Picker("外观模式", selection: Binding(
                    get: { store.snapshot.preferences.appearanceMode },
                    set: { v in store.changePreferences { $0.appearanceMode = v } })) {
                    Text("跟随系统").tag("system")
                    Text("浅色模式").tag("light")
                    Text("深色模式").tag("dark")
                }
                Picker("主题颜色", selection: $themeColor) {
                    Text("天空蓝（默认）").tag("blue")
                    Text("星辉紫").tag("purple")
                    Text("青柠绿").tag("green")
                    Text("品牌橙").tag("orange")
                }

            }
            Section { Text("主题色会影响 App 导航、按钮和强调色，默认天空蓝。")
                .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("外观与显示")
    }
}

struct LiveSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @AppStorage("native.live.style") private var liveStyle = "glass"
    @AppStorage("native.live.expiry") private var expiry = "30分钟"
    @State private var previewMode = "expanded"

    private var previewPending: [Parcel] {
        store.snapshot.parcels.filter { $0.type == "delivery" && $0.isPending }
            .sorted { ($0.arrivedAt ?? $0.createdAt) > ($1.arrivedAt ?? $1.createdAt) }
    }
    private var previewTint: Color {
        switch liveStyle {
        case "white": return Color(red: 0.18, green: 0.43, blue: 0.81)
        case "black": return Color(red: 1, green: 0.72, blue: 0.35)
        default: return Color(red: 0.46, green: 0.82, blue: 1)
        }
    }

    var body: some View {
        Form {
            Section("预览") {
                VStack(spacing: 14) {
                    Picker("预览模式", selection: $previewMode) {
                        Text("展开").tag("expanded")
                        Text("未展开").tag("compact")
                        Text("锁屏").tag("lock")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    livePreview
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .listRowSeparator(.hidden)
            }
            Section("实时活动") {
                Toggle("开启实时活动", isOn: Binding(
                    get: { store.snapshot.preferences.liveActivityEnabled },
                    set: { enabled in
                        LiveActivityCoordinator.resetSession()
                        store.changePreferences { $0.liveActivityEnabled = enabled }
                    }
                ))
                Picker("灵动岛样式", selection: $liveStyle) {
                    Text("流光玻璃").tag("glass")
                    Text("清爽白").tag("white")
                    Text("极夜黑").tag("black")
                }
                .onChange(of: liveStyle) { _, _ in
                    Task { await LiveActivityCoordinator.updateAppearance() }
                }
                Picker("显示时长", selection: $expiry) {
                    Text("5分钟").tag("5分钟")
                    Text("10分钟").tag("10分钟")
                    Text("30分钟").tag("30分钟")
                    Text("2小时").tag("2小时")
                }
                .onChange(of: expiry) { _, _ in
                    LiveActivityCoordinator.resetSession()
                    Task { await LiveActivityCoordinator.updateAppearance() }
                }
            }
        }
        .navigationTitle("实时活动（灵动岛）")
        .onAppear {
            if !["5分钟", "10分钟", "30分钟", "2小时"].contains(expiry) {
                expiry = "30分钟"
                LiveActivityCoordinator.resetSession()
            }
            if store.snapshot.preferences.liveActivityEnabled {
                Task { await LiveActivityCoordinator.update(with: store.snapshot.parcels) }
            }
        }
    }
    private var livePreview: some View {
        Group {
            if previewMode == "compact" {
                HStack(spacing: 34) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(previewPending.count > 99 ? "99+" : "\(previewPending.count)")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(height: 37)
                .background(Color.black, in: Capsule())
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(previewTint)
                            .frame(width: 29, height: 29)
                            .background(previewTint.opacity(0.13),
                                        in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(previewMode == "lock" ? "包裹助手" : "待取包裹")
                                .font(.system(size: 14, weight: .semibold))
                            if previewMode == "lock" {
                                Text("待领取的包裹")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(previewPending.count) 件")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    ForEach(Array(previewPending.prefix(2)), id: \.uuid) { parcel in
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(previewTint)
                                .frame(width: 29, height: 29)
                                .background(previewTint.opacity(0.13),
                                            in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parcel.stationText)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(parcel.trackCompany ?? "待取包裹")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 3)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("取件码")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(parcel.displayCode.isEmpty ? "待出码" : parcel.displayCode)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(previewMode == "lock" ?
                                    Color.primary.opacity(0.05) : Color.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    if previewPending.isEmpty {
                        Text("暂无待取包裹")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    } else if previewPending.count > 2 {
                        Text("另有 \(previewPending.count - 2) 件待取")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .foregroundStyle(previewMode == "lock" && liveStyle == "white" ?
                                 Color.black : Color.white)
                .padding(14)
                .frame(maxWidth: 340)
                .background(previewMode == "lock" && liveStyle == "white" ?
                            Color.white : Color(red: 0.055, green: 0.105, blue: 0.17),
                            in: RoundedRectangle(cornerRadius: 25))
                .overlay {
                    RoundedRectangle(cornerRadius: 25)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
            }
        }
        .accessibilityLabel("实时活动预览，\(previewPending.count) 件待取包裹")
    }
}

// Actual package data preview; WidgetKit renders the same snapshot as the
// main App, never a fabricated or internet-fetched sample.
// Preview uses the same ParcelHelper blue-card vocabulary as the actual
// WidgetKit extension. Unlike a mockup, rows are populated from ParcelStore.
struct HomeWidgetSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var selectedSize = "medium"
    @State private var writeStatus: String?

    private var showTransit: Binding<Bool> {
        Binding(get: { store.snapshot.preferences.widgetShowTransit },
                set: { value in store.changePreferences { $0.widgetShowTransit = value } })
    }

    private var pending: [Parcel] {
        store.snapshot.parcels.filter { $0.type == "delivery" && $0.isPending }
            .sorted { ($0.trackUpdatedAt ?? $0.createdAt) > ($1.trackUpdatedAt ?? $1.createdAt) }
    }
    private var transit: [Parcel] {
        store.snapshot.parcels.filter { $0.type == "delivery" && $0.isTransit }
            .sorted { ($0.trackUpdatedAt ?? $0.createdAt) > ($1.trackUpdatedAt ?? $1.createdAt) }
    }
    private var slots: Int {
        selectedSize == "small" ? 2 : (selectedSize == "medium" ? 3 : 7)
    }
    private var visible: [Parcel] {
        let first = Array(pending.prefix(slots))
        guard showTransit.wrappedValue else { return first }
        return first + Array(transit.prefix(max(0, slots - first.count)))
    }
    private var blueGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.23, green: 0.48, blue: 0.95),
                                Color(red: 0.12, green: 0.29, blue: 0.58)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Form {
            Section("预览") {
                // Keep picker, preview, and explanation in a single Form row.
                // Form's automatic inset separators were leaving a short line
                // on the right; explicit dividers span the complete row.
                VStack(spacing: 12) {
                    Picker("尺寸", selection: $selectedSize) {
                        Text("小号").tag("small")
                        Text("中号").tag("medium")
                        Text("大号").tag("large")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Divider()
                        .frame(maxWidth: .infinity)

                    HStack {
                        Spacer(minLength: 0)
                        widgetPreview
                            .frame(width: selectedSize == "small" ? 158 : 310,
                                   height: selectedSize == "large" ? 337 : 161)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                    Divider()
                        .frame(maxWidth: .infinity)
                    Text("预览使用当前本地包裹。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section("显示") {
                Toggle("包含在途包裹", isOn: showTransit)

            }
            Section("共享数据与签名") {
                LabeledContent("App Groups",
                               value: HomeWidgetSharedStore.isAvailable
                                    ? "当前签名可访问" : "当前签名未配置")
                LabeledContent("构建共享组") {
                    Text(HomeWidgetSharedStore.configuredGroup.isEmpty
                         ? "未写入" : HomeWidgetSharedStore.configuredGroup)
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Text("自签小组件须使用证书允许的 App Group，并为主 App 和 Widget 配置相同的共享组。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/O96u/ParcelHelper/actions/workflows/build-ipa.yml")!) {
                    Label("前往 GitHub 自定义小组件构建", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
                if !HomeWidgetSharedStore.isAvailable {
                    Label("共享组不可访问，请检查主 App 与 Widget 签名。",
                          systemImage: "exclamationmark.shield")
                        .font(.footnote).foregroundStyle(.orange)
                } else if HomeWidgetSharedStore.canReadSnapshot {
                    Label("已读取共享快照", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                } else {
                    Label("共享组可访问，但没有可读取的包裹快照。", systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button("重新写入小组件数据") {
                    store.persist()
                    writeStatus = "已请求写入共享快照；正在检查…"
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(800))
                        writeStatus = HomeWidgetSharedStore.canReadSnapshot
                            ? "共享快照写入成功，请回到桌面等待 WidgetKit 刷新"
                            : (HomeWidgetSharedStore.isAvailable
                               ? "未读到共享快照，请检查存储写入情况"
                               : "当前签名无共享组权限，请先修复签名")
                    }
                }
                if let writeStatus {
                    Text(writeStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("安装提示") {
                Text("桌面长按空白处 → 编辑 → 添加小组件 → 包裹助手。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("小组件")
    }

    private var widgetPreview: some View {
        Group {
            if selectedSize == "medium" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.17),
                                        in: RoundedRectangle(cornerRadius: 9))
                        Text("我的取件").font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 2)
                        Text("\(pending.count) 件待取")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        if showTransit.wrappedValue {
                            Text("在途 \(transit.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: visible.count >= 3 ? 43 : 49)
                    .frame(maxWidth: .infinity)
                    .background(blueGradient,
                                in: RoundedRectangle(cornerRadius: 14))
                    if visible.count == 1, let parcel = visible.first {
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.blue)
                                .frame(width: 35, height: 35)
                                .background(Color.blue.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(parcel.displayCode.isEmpty
                                     ? parcel.displayStatus : parcel.displayCode)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                Text(parcel.itemTitle ?? parcel.trackCompany ?? parcel.stationText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !parcel.stationText.isEmpty {
                                    Text(parcel.stationText).font(.system(size: 9))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: parcel.isPending ? "circle" : "truck.box.fill")
                                .font(.system(size: 23))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 54)
                    } else {
                        previewRows
                    }
                    Spacer(minLength: 0)
                    syncFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: selectedSize == "small" ? 5 : 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("我的取件清单").font(.system(size: 10))
                            Text("\(pending.count) 件待领取")
                                .font(.system(size: selectedSize == "small" ? 15 : 23,
                                              weight: .bold))
                        }
                        Spacer()
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 18))
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(blueGradient, in: RoundedRectangle(cornerRadius: 14))
                    previewRows
                    Spacer(minLength: 0)
                    syncFooter
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 19))
    }

    private var previewRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            if visible.isEmpty {
                Label("暂时没有包裹", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(visible, id: \.uuid) { parcel in
                    HStack(spacing: 5) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                            .frame(width: 21, height: 21)
                            .background(Color.blue.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parcel.displayCode.isEmpty
                                 ? parcel.displayStatus : parcel.displayCode)
                                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Text(parcel.itemTitle ?? parcel.trackCompany ?? parcel.stationText)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: parcel.isPending ? "circle" : "truck.box.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: selectedSize == "small" ? 31 :
                                   (selectedSize == "medium" ? 25 : 35))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var syncFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
            Text("打开 App 后更新")
            Spacer(minLength: 0)
            let remaining = pending.count + (showTransit.wrappedValue ? transit.count : 0)
                - visible.count
            if remaining > 0 { Text("+\(remaining) 件") }
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct RefreshSettingsPage: View {
    @AppStorage("native.refresh.app") private var appMin = 15

    var body: some View {
        Form {
            Section("前台自动同步") {
                Stepper("刷新间隔：\(appMin) 分钟", value: $appMin, in: 5...120, step: 5)
                Text("达到间隔时尝试同步；手动刷新不受此间隔限制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("后台智能刷新") {
                Text("后台由 iOS 调度，仅小米、丰巢等轻量接口可以尝试运行；强制关闭 App 后不保证更新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("刷新频率")
        .onChange(of: appMin) { _, _ in
            ParcelBackgroundRefresh.scheduleNext()
            ParcelStore.shared.persist()
        }
    }
}

struct FAQSettingsPage: View {
    private let answers: [(String,String)] = [
        ("怎样添加包裹？", "在包裹页点击右上角加号查询运单，或通过「导入包裹」读取已授权平台的订单。也可以复制取件短信再打开包裹助手进行识别，确认后保存。"),
        ("包裹搜索在哪里？", "包裹页面右上角的放大镜用于展开搜索框；再次点击可以收起。可搜索取件码、运单号、商品、快递公司和驿站。"),
        ("物流显示已签收，为什么还不是已取件？", "物流「已签收」可能由驿站或代收点代签，不一定是本人已取。只有明确的取件完成记录或手动标记，才显示为「已取件」。"),
        ("怎样手动标记已取件？", "进入包裹详情点击「标记已取」，或在包裹列表中左滑操作。已取记录会计入取件统计。"),
        ("刷新频率怎样生效？", "设置的分钟数控制前台自动检查，也作为后台和 Widget 智能调度的偏好值。后台有省电下限，且 iOS 不保证按时唤醒；主动下拉刷新可另行触发查询。"),
        ("为什么有些订单或物流轨迹没有同步？", "已授权不代表一定读取成功。淘宝、京东通过独立网页登录会话读取订单和物流，网页未加载完成、安全验证、页面结构变化、运单号暂未生成或每轮数量限制都可能导致漏读。请在「设置 → 运行日志」查看实际读取到的订单数、有效运单数与跳过原因。"),
        ("京东有物流信息，却显示 0 件或无法重新同步？", "先在「账号授权 → 京东账号」确认网页登录有效，再同步并查看「运行日志」。京东优先读取官方订单 JSON 和真实物流进度链接；若暂未生成运单号，但官方订单已有明确的传统快递进度或取件码，也可导入订单关联的物流记录。秒送、虚拟商品、取消订单不会伪装成快递。单笔异常可跳过，整轮部分成功会保留结果；平台安全验证仍需本人完成。"),
        ("清空日志或 API 配置需要确认吗？", "需要。清空运行日志、清理缓存/查询历史、删除历史包裹、解除账号授权以及清除快递鸟或快递100 的 API 配置，均须在警告弹窗中明确确认；直接返回或点击取消不会执行删除。"),
        ("如何查看或分享运行日志？", "打开「设置 → 运行日志」，可以按来源筛选，点击「刷新」查看最新记录，或「复制全部」分享诊断信息。最近 240 条记录仅保存在本机，显示中文平台名称，不会上传登录凭据或订单详情；分享前仍建议检查内容。清空操作需要二次确认。"),
        ("快递鸟和快递100怎样配置？", "两者是独立的备用物流查询服务。先尝试包裹来源平台的数据，再使用已配置的快递鸟、快递100 API；免费查询是单独开关。快递100需自行申请 Customer 和 Key，并遵守服务次数与费用限制。"),
        ("包裹助手能在后台实时推送物流吗？", "有活跃包裹时，App 会请求系统安排低频轻量 API 刷新，目前仅覆盖小米与丰巢。系统不保证执行时刻，网页平台仍须前台同步，也没有云端 APNs 实时推送。获取到新物流状态后才会安排本地通知。"),
        ("为什么找不到主屏幕小组件？", "新版提供小、中、大号 WidgetKit 小组件。如果安装后未出现，需检查主 App 与小组件扩展是否分别正确签名，且拥有共同的 App Group；证书列出 App Groups 不代表扩展一定签名成功。"),
        ("灵动岛为什么不显示？", "需要支持实时活动的 iPhone 和 iOS 系统，并在系统中允许该功能。使用第三方证书重新签名时，若缺少相关授权，也可能无法启动实时活动。"),
        ("剪贴板能识别快递运单号吗？", "可以。复制 SF、ZT、JT、JD 等字母前缀的运单号，或者包含「运单号」「快递单号」的文字，打开 App 后会弹窗确认是否导入。单独的纯数字不自动识别，以免把手机号、验证码和订单编号误当成运单。取件短信原有识别方式保持不变。"),
        ("快捷指令可以导入快递短信吗？", "支持「导入快递文字」和「识别剪贴板」两个 App 快捷指令动作。也可以直接复制短信或带快递前缀的运单号，然后打开包裹助手确认导入。是否能在快捷指令中看到这些动作，仍取决于重签名后的 iOS 系统注册情况。"),
        ("能自动读取手机收到的短信吗？", "iOS 不允许普通 App 直接读取短信数据库。可以复制短信后打开 App，或在系统快捷指令自动化中自行设置短信触发器。"),
        ("数据保存在哪里？", "包裹数据默认保存在本机 App 的 Documents 目录。卸载 App 可能删除本机包裹数据，重装前请注意备份。")
    ]
    var body: some View {
        List { ForEach(answers, id: \.0) { item in
            VStack(alignment: .leading, spacing: 8) {
                Text(item.0).font(.headline)
                Text(item.1).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 7)
        } }
        .navigationTitle("常见问题")
    }
}

struct CacheSettingsPage: View {
    @EnvironmentObject private var store: ParcelStore
    @State private var confirmOldParcels = false
    @State private var confirmingHistory = false
    @State private var confirmingCache = false
    @State private var clearing = false
    @State private var cacheBytes: Int64 = 0
    @State private var notice: String?

    private var expired: [Parcel] {
        let deadline = Date().addingTimeInterval(-30 * 24 * 3600)
            .timeIntervalSince1970 * 1000
        return store.snapshot.parcels.filter {
            $0.isDone && ($0.pickedAt ?? $0.createdAt) < deadline
        }
    }
    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
    private var cacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("App 本地缓存", value: cacheSizeText)
                Text("包含网络响应和 App 缓存目录。网页缓存也会清理，但 WebKit 不提供精确字节统计。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    confirmingCache = true
                } label: {
                    HStack {
                        Label("清除实际缓存", systemImage: "trash")
                        Spacer()
                        if clearing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(clearing)
            } header: {
                Text("缓存")
            } footer: {
                Text("不会清除登录 Cookie、账号授权、Keychain、物流记录或驿站信息。")
            }

            Section("搜索历史") {
                LabeledContent("最近查快递记录", value: "\(NativeTracking.history().count) 条")
                Button("清空查询历史", role: .destructive) {
                    confirmingHistory = true
                }
                .disabled(NativeTracking.history().isEmpty)
            }

            Section("历史包裹（非缓存）") {
                LabeledContent("已取超过 30 天", value: "\(expired.count) 件")
                Button("清理历史已取包裹", role: .destructive) {
                    confirmOldParcels = true
                }
                .disabled(expired.isEmpty)
                Text("与缓存分开处理。不会删除在途、待取包裹。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("清除缓存")
        .task { updateCacheSize() }
        .alert("确认清除缓存？", isPresented: $confirmingCache) {
            Button("取消", role: .cancel) {}
            Button("清除缓存", role: .destructive) {
                Task { await clearCaches() }
            }
        } message: {
            Text("将删除本机的缓存文件并清理可清除的网页缓存；不会删除包裹、账号授权或登录凭据。")
        }
        .alert("确认清除查询历史？", isPresented: $confirmingHistory) {
            Button("清空", role: .destructive) {
                NativeTracking.clearHistory()
                notice = "查询历史已清空。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除查快递的最近搜索记录。")
        }
        .alert("确认删除历史包裹？", isPresented: $confirmOldParcels) {
            Button("删除 \(expired.count) 件", role: .destructive) {
                let ids = expired.map(\.uuid)
                for id in ids { store.delete(id) }
                notice = "已删除 \(ids.count) 条历史包裹记录。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法撤销，后续同步不会自动恢复这些已删除的记录。")
        }
        .alert("清理结果", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private func directoryBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  attrs.isRegularFile == true else { continue }
            total += Int64(attrs.fileSize ?? 0)
        }
        return total
    }

    private func updateCacheSize() {
        cacheBytes = cacheDirectory.map(directoryBytes(at:)) ?? 0
    }

    private func clearCaches() async {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }

        let before = cacheBytes
        URLCache.shared.removeAllCachedResponses()
        // Only caches: preserve WebKit cookies, LocalStorage and login tokens.
        let webStore = WKWebsiteDataStore.default()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webStore.removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }

        var failures = 0
        if let dir = cacheDirectory,
           let files = try? FileManager.default.contentsOfDirectory(
               at: dir, includingPropertiesForKeys: nil
           ) {
            for file in files {
                do { try FileManager.default.removeItem(at: file) }
                catch { failures += 1 }
            }
        }
        updateCacheSize()
        let released = max(0, before - cacheBytes)
        notice = "缓存清理完成，释放约 \(ByteCountFormatter.string(fromByteCount: released, countStyle: .file))。" +
            (failures > 0 ? "有 \(failures) 项被系统占用，未能删除。" : "") +
            " 登录状态和包裹信息已保留。"
    }
}
