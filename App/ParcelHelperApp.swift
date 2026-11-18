import SwiftUI
import UIKit
import CryptoKit
import AppIntents
import UserNotifications

/// A newly copied pickup SMS is recognized on foreground entry. iOS may show
/// its own Paste permission prompt; we never silently persist clipboard text.
private struct ClipboardParcelCandidate {
    let text: String
    let parsed: ParsedSMS
    let fingerprint: String

    var summary: String {
        var pieces = ["取件码：" + parsed.code]
        if !parsed.station.isEmpty { pieces.append("取件点：" + parsed.station) }
        if !parsed.company.isEmpty { pieces.append("快递公司：" + parsed.company) }
        if !parsed.address.isEmpty { pieces.append("地址：" + parsed.address) }
        return pieces.joined(separator: "\n")
    }
}

@MainActor private final class ClipboardParcelMonitor: ObservableObject {
    @Published var candidate: ClipboardParcelCandidate?
    @Published var outcome: String?

    private let processedKey = "native.clipboard.lastHandledSHA256"
    private var previousChangeCount: Int = -1
    private var checking = false

    func checkOnForeground() {
        guard UserDefaults.standard.object(forKey: "native.clipboard.autoRecognize") as? Bool ?? true,
              !checking, candidate == nil else { return }
        let clipboard = UIPasteboard.general
        guard clipboard.hasStrings else { return }
        let changed = clipboard.changeCount
        guard changed != previousChangeCount else { return }
        previousChangeCount = changed
        checking = true
        defer { checking = false }

        // Reading another app's pasteboard is subject to the iOS paste consent
        // dialog. Restrict size and reject non-delivery text before proposing import.
        guard let raw = clipboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 2000 else { return }
        let hash = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard hash != UserDefaults.standard.string(forKey: processedKey) else { return }
        let keywords = ["取件", "取货", "提货", "开柜", "快递", "包裹", "驿站", "兔喜"]
        guard keywords.contains(where: raw.contains) else { return }
        let parsed = SMSParser.parse(raw)
        guard !parsed.code.isEmpty || !parsed.trackingNumber.isEmpty else { return }
        candidate = ClipboardParcelCandidate(text: raw, parsed: parsed, fingerprint: hash)
    }

    func dismiss() {
        if let candidate {
            UserDefaults.standard.set(candidate.fingerprint, forKey: processedKey)
        }
        candidate = nil
    }

    func save() {
        guard let candidate else { return }
        let parsed = candidate.parsed
        var parcel = Parcel()
        parcel.code = parsed.code
        parcel.mailNo = parsed.trackingNumber.isEmpty ? nil : parsed.trackingNumber
        parcel.courierStationName = parsed.station
        parcel.address = parsed.address
        parcel.trackCompany = parsed.company.isEmpty ? nil : parsed.company
        parcel.smsContent = candidate.text
        parcel.source = "clipboard"
        parcel.userTitle = "短信智能识别"
        if !parsed.code.isEmpty { parcel.arrivedAt = Date().timeIntervalSince1970 * 1000 }
        let wasUpdated = ParcelStore.shared.upsertRecognizedText(parcel)
        UserDefaults.standard.set(candidate.fingerprint, forKey: processedKey)
        self.candidate = nil
        outcome = wasUpdated ? "已更新已有包裹，没有创建重复记录。" : "取件信息已添加到包裹助手。"
    }
}

/// Show the same local logistics alert while the app is in the foreground.
final class ParcelNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main struct ParcelHelperApp: App {
    @UIApplicationDelegateAdaptor(ParcelNotificationDelegate.self) private var notificationDelegate

    init() {
        // Update the parameters that iOS indexes for App Shortcuts after
        // installation/upgrade. Registration is still controlled by iOS.
        ParcelHelperShortcuts.updateAppShortcutParameters()
    }

    @StateObject private var store = ParcelStore.shared
    @StateObject private var clipboardMonitor = ClipboardParcelMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("native.appearance.color") private var themeColor = "blue"

    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(store)
                .tint(AppTheme.color(themeColor))
                .preferredColorScheme(store.snapshot.preferences.appearanceMode == "dark" ? .dark : store.snapshot.preferences.appearanceMode == "light" ? .light : nil)
                .task {
                    clipboardMonitor.checkOnForeground()
                    _ = await NativeHomeRefresh.refresh()
                    await NativeWebAutoSync.shared.refreshAvailable()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.persist()
                        clipboardMonitor.checkOnForeground()
                        Task {
                            _ = await NativeHomeRefresh.refresh()
                            await NativeWebAutoSync.shared.refreshAvailable()
                        }
                    }
                }
                .alert(clipboardMonitor.candidate == nil ? "剪贴板识别" : "识别到快递取件信息",
                       isPresented: Binding(
                    get: { clipboardMonitor.candidate != nil || clipboardMonitor.outcome != nil },
                    set: { if !$0 {
                        clipboardMonitor.dismiss()
                        clipboardMonitor.outcome = nil
                    } }
                )) {
                    if clipboardMonitor.candidate != nil {
                        Button("忽略", role: .cancel) { clipboardMonitor.dismiss() }
                        Button("导入包裹") { clipboardMonitor.save() }
                    } else {
                        Button("确定") { clipboardMonitor.outcome = nil }
                    }
                } message: {
                    Text(clipboardMonitor.candidate?.summary ?? clipboardMonitor.outcome ?? "")
                }
                .onOpenURL { url in
                    guard url.scheme == "parcelhelper", url.host == "parcel" else { return }
                    if url.query?.contains("act=pick") == true,
                       let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uuid" })?.value {
                        store.markDone(id, done: true)
                    }
                }
        }
    }
}
