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

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["parcelUUID"] as? String {
            UserDefaults.standard.set(id, forKey: "native.notification.openParcel")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("ParcelNotificationOpen"), object: nil)
            }
        }
        completionHandler()
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
    private static let nextScheduledKey = "native.bg.refresh.nextScheduledAt"
    private static let parcelCursorKey = "native.bg.refresh.trackingCursor"

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
        // The app may reopen repeatedly while a background request is queued.
        // Cancelling and rescheduling on every activation pushes its earliest
        // start farther into the future and can starve background refreshes.
        let earliest = Date().addingTimeInterval(interval)
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            Task { @MainActor in
                if let existing = requests.first(where: { $0.identifier == identifier }),
                   (existing.earliestBeginDate ?? .distantPast) <= earliest { return }
                let request = BGAppRefreshTaskRequest(identifier: identifier)
                request.earliestBeginDate = earliest
                do {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    try BGTaskScheduler.shared.submit(request)
                    ParcelRunLog.record("后台刷新", "已向系统申请后台刷新")
                } catch {
                    ParcelRunLog.record("后台刷新", "系统未接受后台刷新申请")
                }
            }
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // The previous request is now executing; schedule its successor.
        UserDefaults.standard.removeObject(forKey: nextScheduledKey)
        scheduleNext()
        let completion = ParcelBGTaskCompletion()
        ParcelRunLog.record("后台刷新", "系统已启动后台任务")
        let work = Task { @MainActor in
            let succeeded = await refreshEligibleAccounts()
            ParcelRunLog.record("后台刷新", succeeded && !Task.isCancelled ? "后台任务结束" : "后台任务中断")
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

    private static func refreshOneExistingWaybill() async {
        guard NativeTracking.isConfigured || NativeTracking.isKuaidi100Configured ||
              NativeTracking.publicFallbackEnabled else { return }
        let candidates = ParcelStore.shared.snapshot.parcels.filter {
            $0.type == "delivery" && !$0.isDone && !$0.isSigned &&
            $0.closed == nil && ($0.mailNo ?? "").range(
                of: #"^[A-Za-z0-9-]{8,40}$"#,
                options: .regularExpression) != nil
        }
        guard !candidates.isEmpty else { return }
        // Round-robin a single shipment per short background invocation to
        // respect provider rate limits and iOS's limited execution budget.
        let cursor = UserDefaults.standard.integer(forKey: parcelCursorKey)
        let candidate = candidates[cursor % candidates.count]
        UserDefaults.standard.set((cursor + 1) % candidates.count, forKey: parcelCursorKey)
        guard let mail = candidate.mailNo else { return }
        do {
            let found = try await NativeTracking.lookup(
                mail, source: candidate.source, shipperCode: candidate.shipperCode ?? "",
                phone: NativeTracking.phone(for: mail),
                accountIDs: candidate.linkedAccounts ?? [], backgroundOnly: true)
            guard !Task.isCancelled, !found.nodes.isEmpty else { return }
            var update = NativeSyncParcel(source: candidate.source ?? "clipboard")
            update.mailNo = mail
            update.company = found.company
            update.latest = found.latest.isEmpty ? (found.nodes.first?.text ?? "") : found.latest
            update.tracks = found.nodes
            guard var current = ParcelStore.shared.snapshot.parcels.first(where: {
                $0.uuid == candidate.uuid && $0.mailNo == mail
            }) else { return }
            let previous = current
            TrackMerge.apply(to: &current, nodes: update.tracks, summary: update.latest)
            let updated = current.hasSyncedContentChange(comparedTo: previous) ? 1 : 0
            if updated > 0 {
                current.trackUpdatedAt = Date().timeIntervalSince1970 * 1000
                ParcelStore.shared.upsert(current)
                await ParcelNotifications.notifyUpdate(previous: previous, current: current)
            }
            ParcelRunLog.record("后台刷新", "已查询 1 件物流，更新 \(updated) 件")
        } catch {
            ParcelRunLog.record("后台刷新", "物流补查未获得有效结果")
        }
    }

    private static func refreshEligibleAccounts() async -> Bool {
        // Preserve battery and avoid work when the user has no active parcels.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            ParcelRunLog.record("后台刷新", "低电量模式，跳过查询")
            return true
        }
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
        // JD/Taobao signed-in order pages use WKWebView and cannot be
        // launched reliably inside a short iOS BGAppRefresh task. Existing
        // waybills can instead be checked using explicitly configured
        // HTTPS tracking services, without any WebKit or session scraping.
        if !Task.isCancelled, Date() < deadline, attempted < 2 {
            await refreshOneExistingWaybill()
        }
        return !Task.isCancelled
    }
}
