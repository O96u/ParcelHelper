import Foundation
import UserNotifications

enum ParcelNotifications {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    static func schedule(_ parcel: Parcel, afterHours: Int) async {
        guard parcel.isPending, afterHours > 0 else { return }
        let content = UNMutableNotificationContent()
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
        guard let old = previous,
              ParcelStore.shared.snapshot.preferences.reminderEnabled,
              !current.pickedByUser else { return }

        let wasSigned = old.isSigned
        let wasPending = old.isPending
        let isSigned = current.isSigned
        let isPending = current.isPending
        let before = (old.trackLatest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = (current.trackLatest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let changedText = !latest.isEmpty && latest != before
        let isNewPickup = isPending && !wasPending && !old.isDone
        let isNewSignature = isSigned && !wasSigned && !old.isDone
        let isNewCompletion = current.isDone && !old.isDone
        let isOutForDelivery = ["派送中", "正在派送", "开始派送", "派件中", "正在投递", "配送中", "派送员"]
            .contains(where: latest.contains)
        let isTransit = ["运输中", "运输至", "已发出", "已到达", "到达", "离开",
                         "已揽收", "转运", "分拨", "中转", "下一站", "在途"]
            .contains(where: latest.contains)

        let title: String
        let category: String
        if isNewCompletion {
            category = "collected"
            title = "包裹已取件"
        } else if isNewSignature {
            category = "signed"
            title = "包裹已签收"
        } else if isNewPickup {
            guard UserDefaults.standard.object(forKey: "native.reminder.arrival") as? Bool ?? true else { return }
            category = "arrived"
            title = "快递已到站，等待取件"
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
        guard UserDefaults.standard.string(forKey: key) != event else { return }

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

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["parcel-\(id)"])
    }
}
