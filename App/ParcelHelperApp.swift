import SwiftUI
import UIKit
import CryptoKit
import AppIntents
import UserNotifications
import BackgroundTasks

/// A newly copied pickup SMS is recognized on foreground entry. iOS may show
/// its own Paste permission prompt; we never silently persist clipboard text.
private struct ClipboardParcelCandidate {
    let text: String
    let parsed: ParsedSMS
    let fingerprint: String

    var summary: String {
        var pieces: [String] = []
        if !parsed.code.isEmpty { pieces.append("取件码：" + parsed.code) }
        if !parsed.trackingNumber.isEmpty { pieces.append("运单号：" + parsed.trackingNumber) }
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
        let parsed = SMSParser.parse(raw)
        guard !parsed.code.isEmpty || !parsed.trackingNumber.isEmpty else { return }
        let keywords = ["取件", "取货", "提货", "开柜", "快递", "包裹",
                        "驿站", "兔喜", "运单", "物流", "单号",
                        "顺丰", "中通", "极兔", "圆通", "申通"]
        // Standalone prefixed waybills are valid candidates without SMS
        // keywords; keep numeric-only clipboard text excluded.
        guard keywords.contains(where: raw.contains) ||
              SMSParser.isCarrierTrackingNumber(parsed.trackingNumber) else { return }
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
        parcel.userTitle = parsed.code.isEmpty ? "剪贴板运单导入" : "短信智能识别"
        if !parsed.code.isEmpty { parcel.arrivedAt = Date().timeIntervalSince1970 * 1000 }
        let wasUpdated = ParcelStore.shared.upsertRecognizedText(parcel)
        UserDefaults.standard.set(candidate.fingerprint, forKey: processedKey)
        self.candidate = nil
        outcome = wasUpdated ? "已更新已有包裹，没有创建重复记录。" :
            (parsed.code.isEmpty ? "运单号已添加，可在包裹详情查询物流。" : "取件信息已添加到包裹助手。")
    }
}

/// Show the same local logistics alert while the app is in the foreground.
final class ParcelNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ParcelBackgroundRefresh.register()
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
    @State private var didCheckInitialNotificationPermission = false

    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(store)
                .tint(AppTheme.color(themeColor))
                .preferredColorScheme(store.snapshot.preferences.appearanceMode == "dark" ? .dark : store.snapshot.preferences.appearanceMode == "light" ? .light : nil)
                .task {
                    // Reconcile any widget "marked picked" actions on launch.
                    store.persist()
                    ParcelBackgroundRefresh.scheduleNext()
                    if !didCheckInitialNotificationPermission {
                        didCheckInitialNotificationPermission = true
                        Task {
                            // Only iOS can show the system alert, and only when
                            // permission has not been decided. Never re-prompt
                            // someone who already allowed or denied it.
                            let status = await UNUserNotificationCenter.current()
                                .notificationSettings().authorizationStatus
                            guard status == .notDetermined else { return }
                            _ = await ParcelNotifications.requestPermission()
                        }
                    }
                    clipboardMonitor.checkOnForeground()
                    // Foreground-only update checks never sign or install an IPA.
                    Task { await ParcelUpdateCenter.shared.checkOnLaunch() }
                    _ = await NativeHomeRefresh.refresh()
                    await NativeWebAutoSync.shared.refreshAvailable()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.persist()
                        ParcelBackgroundRefresh.scheduleNext()
                        clipboardMonitor.checkOnForeground()
                        Task {
                            _ = await NativeHomeRefresh.refresh()
                            guard UIApplication.shared.applicationState == .active else { return }
                            await NativeWebAutoSync.shared.refreshAvailable()
                        }
                    }
                }
                // A foreground-only timer is needed when the user leaves the
                // app open for hours: onAppear/onChange alone do not respect
                // the configured refresh interval until the next app switch.
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                    guard scenePhase == .active else { return }
                    Task { @MainActor in
                        _ = await NativeHomeRefresh.refresh()
                        guard UIApplication.shared.applicationState == .active else { return }
                        await NativeWebAutoSync.shared.refreshAvailable()
                    }
                }
                .alert(clipboardMonitor.candidate == nil ? "剪贴板识别" :
                       (clipboardMonitor.candidate?.parsed.code.isEmpty == true ?
                        "添加快递订阅？" : "识别到取件信息"),
                       isPresented: Binding(
                    get: { clipboardMonitor.candidate != nil || clipboardMonitor.outcome != nil },
                    set: { if !$0 {
                        clipboardMonitor.dismiss()
                        clipboardMonitor.outcome = nil
                    } }
                )) {
                    if clipboardMonitor.candidate != nil {
                        Button("忽略", role: .cancel) { clipboardMonitor.dismiss() }
                        Button(clipboardMonitor.candidate?.parsed.code.isEmpty == true ?
                               "添加订阅" : "导入包裹") { clipboardMonitor.save() }
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

// BGAppRefresh is an opportunistic, API-only task. It must never construct a
// hidden WKWebView or promise 15-minute background polling.
private final class ParcelBGTaskCompletion {
    private let lock = NSLock()
    private var finished = false

    func finish(_ task: BGTask, success: Bool) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { task.setTaskCompleted(success: success) }
    }
}

@MainActor enum ParcelBackgroundRefresh {
    private static let identifier = "com.muxui.ParcelHelper.refresh"

    nonisolated static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.muxui.ParcelHelper.refresh",
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in handle(refresh) }
        }
    }

    static func scheduleNext() {
        let parcels = ParcelStore.shared.snapshot.parcels.filter {
            $0.type == "delivery" && !$0.isDone && !$0.isSigned && $0.closed == nil
        }
        let interval = RefreshPolicy.backgroundDelay(
            hasPending: parcels.contains(where: { $0.isPending }),
            hasActive: !parcels.isEmpty
        )
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("ParcelHelper BGAppRefresh schedule failed: %@", String(describing: error))
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Schedule the successor before network work, because iOS can
        // terminate the current execution at any time.
        scheduleNext()
        let completion = ParcelBGTaskCompletion()
        let work = Task { @MainActor in
            let succeeded = await refreshEligibleAccounts()
            completion.finish(task, success: succeeded && !Task.isCancelled)
        }
        // A soft execution budget independent of the system's hard expiry.
        // URLSession cancellation is cooperative; NativeParcelSync checks
        // cancellation before it touches the authoritative parcel store.
        let watchdog = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 19_000_000_000)
                guard !Task.isCancelled else { return }
                work.cancel()
                completion.finish(task, success: false)
            } catch { }
        }
        task.expirationHandler = {
            work.cancel()
            watchdog.cancel()
            completion.finish(task, success: false)
        }
    }

    private static func refreshEligibleAccounts() async -> Bool {
        // Preserve battery and avoid work when the user has no active parcels.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return true }
        guard ParcelStore.shared.snapshot.parcels.contains(where: {
            $0.type == "delivery" && !$0.isDone && !$0.isSigned && $0.closed == nil
        }) else { return true }

        // These providers use standalone native API/Keychain paths. Cainiao's
        // MTOP fallback can create a WKWebView, while Taobao/JD/PDD order
        // reading uses WebKit; none of those are invoked in this background task.
        let deadline = Date().addingTimeInterval(16)
        var attempted = 0
        if NativeMiExpress.hasSession && Date() < deadline {
            let last = UserDefaults.standard.double(forKey: "native.sync.success.mi")
            if Date().timeIntervalSince1970 - last >= 3600 {
                attempted += 1
                _ = try? await NativeParcelSync.run("mi")
            }
        }
        if Task.isCancelled { return false }

        let accounts = await ParcelAccounts.authorizedAccounts(for: "fengchao")
        for account in accounts {
            guard !Task.isCancelled, Date() < deadline, attempted < 2 else { break }
            let last = UserDefaults.standard.double(
                forKey: "native.sync.success.fengchao." + account.id
            )
            guard Date().timeIntervalSince1970 - last >= 1800 else { continue }
            attempted += 1
            _ = try? await NativeParcelSync.run("fengchao", accountID: account.id)
        }
        return !Task.isCancelled
    }
}
