import Foundation
import UserNotifications

enum ParcelNotifications {
    @MainActor private static var pendingEvents = Set<String>()
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    static func schedule(_ parcel: Parcel, afterHours: Int) async {
        guard parcel.isPending, afterHours > 0 else { return }
        let content = UNMutableNotificationContent()
        content.userInfo = ["parcelUUID": parcel.uuid]
        content.title = "包裹待取提醒"
        content.body = "\(parcel.stationText)：\(parcel.displayCode.isEmpty ? parcel.title : parcel.displayCode)"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(afterHours * 3600), repeats: false)
        let request = UNNotificationRequest(identifier: "parcel-\(parcel.uuid)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
    /// Send local notifications only for genuine changes on an already-known parcel.
    /// This is not APNs: if iOS suspends the app and no sync runs, no new event
    /// can be discovered or notified until the next allowed refresh.
    @MainActor
    static func notifyUpdate(previous: Parcel?, current: Parcel) async {
        guard ParcelStore.shared.snapshot.preferences.reminderEnabled,
              !current.pickedByUser else { return }

        let wasSigned = previous?.isSigned ?? false
        let wasPending = previous?.isPending ?? false
        let isSigned = current.isSigned
        let isPending = current.isPending
        let before = (previous?.currentTrackingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = current.currentTrackingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let changedText = !latest.isEmpty && latest != before
        let alreadyKnown = previous != nil
        let wasDone = previous?.isDone ?? false
        let isNewArrival = !alreadyKnown && isPending
        let isNewPickup = alreadyKnown && isPending && !wasPending && !wasDone
        let isNewSignature = alreadyKnown && isSigned && !wasSigned && !wasDone
        let isNewCompletion = alreadyKnown && current.isDone && !wasDone
        let isOutForDelivery = ["派送中", "正在派送", "开始派送", "派件中", "正在投递", "配送中", "派送员"]
            .contains(where: latest.contains)
        let isTransit = ["运输中", "运输至", "已发出", "已到达", "到达", "离开",
                         "已揽收", "转运", "分拨", "中转", "下一站", "在途"]
            .contains(where: latest.contains)

        let title: String
        let category: String
        if current.hasDeliveryException && previous?.hasDeliveryException != true {
            guard UserDefaults.standard.object(forKey: "native.reminder.exception") as? Bool ?? true else { return }
            category = "exception"
            title = "物流出现异常"
        } else if isNewCompletion {
            guard UserDefaults.standard.object(forKey: "native.reminder.collected") as? Bool ?? true else { return }
            category = "collected"
            title = "包裹已取件"
        } else if isNewSignature {
            guard UserDefaults.standard.object(forKey: "native.reminder.signed") as? Bool ?? true else { return }
            category = "signed"
            title = "包裹已签收"
        } else if isNewPickup || isNewArrival {
            guard UserDefaults.standard.object(forKey: "native.reminder.arrival") as? Bool ?? true else { return }
            category = "arrived"
            title = isNewArrival ? "新增待取包裹" : "快递已到站，等待取件"
        } else if changedText && isOutForDelivery && !current.isDone && !isSigned {
            guard UserDefaults.standard.object(forKey: "native.reminder.dispatch") as? Bool ?? true else { return }
            category = "delivery"
            title = "快递正在派送"
        } else if changedText && isTransit && current.isTransit {
            guard UserDefaults.standard.bool(forKey: "native.reminder.transit") else { return }
            category = "transit"
            title = "物流位置已更新"
        } else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let authorization = (await center.notificationSettings()).authorizationStatus
        guard authorization == .authorized || authorization == .provisional ||
              authorization == .ephemeral else { return }

        let detail = latest.isEmpty ? current.stationText : latest
        let event = category + ":" + detail
        let key = "native.reminder.lastEvent." + current.uuid
        let inFlight = key + ":" + event
        guard UserDefaults.standard.string(forKey: key) != event,
              pendingEvents.insert(inFlight).inserted else { return }
        defer { pendingEvents.remove(inFlight) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(detail.prefix(160))
        content.sound = .default
        content.threadIdentifier = "parcel-" + current.uuid
        content.userInfo = ["parcelUUID": current.uuid]
        let request = UNNotificationRequest(
            identifier: "parcel-event-" + current.uuid + "-" + UUID().uuidString,
            content: content, trigger: nil)
        do {
            try await center.add(request)
            UserDefaults.standard.set(event, forKey: key)
        } catch {
            print("Parcel status notification failed: \(error)")
        }
    }

    /// Failure notifications are opt-in and heavily throttled. Never put
    /// raw platform errors, cookies or tracking IDs in the notification text.
    /// An account failure is not evidence that its authorization was revoked.
    @MainActor
    static func notifySyncFailure(platform: String, accountID: String) async {
        guard ParcelStore.shared.snapshot.preferences.reminderEnabled,
              UserDefaults.standard.object(forKey: "native.reminder.failure") as? Bool ?? true
        else { return }
        let key = "native.reminder.failure.at." + platform + "." + accountID
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) >= 6 * 3600 else { return }
        let center = UNUserNotificationCenter.current()
        let status = (await center.notificationSettings()).authorizationStatus
        guard status == .authorized || status == .provisional ||
              status == .ephemeral else { return }
        let names = ["cainiao": "菜鸟", "taobao": "淘宝", "jd": "京东",
                     "pdd": "拼多多", "mi": "小米", "fengchao": "丰巢"]
        let content = UNMutableNotificationContent()
        content.title = (names[platform] ?? "包裹") + "同步未完成"
        content.body = "本次未能更新物流状态，请打开包裹助手检查网络或账号授权。已有包裹不会删除。"
        content.sound = .default
        content.threadIdentifier = "parcel-sync-" + platform
        let request = UNNotificationRequest(
            identifier: "parcel-sync-failure-" + platform + "-" + accountID,
            content: content, trigger: nil)
        do {
            try await center.add(request)
            UserDefaults.standard.set(now, forKey: key)
        } catch {
            NSLog("ParcelHelper sync-failure notification failed: %@", String(describing: error))
        }
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["parcel-\(id)"])
    }
}
