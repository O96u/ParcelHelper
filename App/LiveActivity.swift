import Foundation
import ActivityKit

struct PickupActivityItem: Codable, Hashable {
    var code: String
    var station: String
    var company: String
}

struct PickupActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pending: Int
        var code: String
        var station: String
        var style: String
        var items: [PickupActivityItem]
    }
    var title: String
}

@MainActor enum LiveActivityCoordinator {
    private static let sessionStartKey = "native.live.session.startedAt"
    private static let seenIDsKey = "native.live.session.seenIDs"
    private static var expiryTask: Task<Void, Never>?

    private static var style: String {
        UserDefaults.standard.string(forKey: "native.live.style") ?? "glass"
    }

    private static var duration: TimeInterval {
        switch UserDefaults.standard.string(forKey: "native.live.expiry") ?? "30分钟" {
        case "5分钟": return 5 * 60
        case "10分钟": return 10 * 60
        case "30分钟": return 30 * 60
        case "2小时": return 2 * 3600
        default: return 30 * 60
        }
    }

    // Reset on a deliberate off/on cycle, or when there are no pending parcels.
    static func resetSession() {
        expiryTask?.cancel()
        expiryTask = nil
        UserDefaults.standard.removeObject(forKey: sessionStartKey)
        UserDefaults.standard.removeObject(forKey: seenIDsKey)
    }

    private static func expiry(for pending: [Parcel]) -> Date {
        let currentIDs = Set(pending.map(\.uuid))
        let knownIDs = Set(UserDefaults.standard.stringArray(forKey: seenIDsKey) ?? [])
        var started = UserDefaults.standard.double(forKey: sessionStartKey)

        // A newly arriving parcel is a new delivery event, so it starts a fresh
        // display window. Ordinary refreshes do not endlessly extend the timer.
        if started <= 0 || !currentIDs.isSubset(of: knownIDs) {
            started = Date().timeIntervalSince1970
            UserDefaults.standard.set(started, forKey: sessionStartKey)
        }
        UserDefaults.standard.set(Array(knownIDs.union(currentIDs)), forKey: seenIDsKey)
        return Date(timeIntervalSince1970: started + duration)
    }

    private static func scheduleEnd(at deadline: Date) {
        expiryTask?.cancel()
        let remaining = max(0, deadline.timeIntervalSinceNow)
        expiryTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // Best effort while the app is awake. iOS may suspend it;
            // the persisted deadline is checked again on foreground refresh.
            await update(with: ParcelStore.shared.snapshot.parcels)
        }
    }

    static func updateAppearance() async {
        await update(with: ParcelStore.shared.snapshot.parcels)
    }

    static func stopAll() async {
        expiryTask?.cancel()
        expiryTask = nil
        for activity in Activity<PickupActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func pickupCode(_ parcel: Parcel) -> String {
        let candidates = [parcel.displayCode] + parcel.codes
        return candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != parcel.mailNo } ?? ""
    }

    private static func courierName(_ parcel: Parcel) -> String {
        if let company = parcel.trackCompany, !company.isEmpty { return company }
        switch parcel.companyName {
        case 1: return "中通快递"
        case 2: return "顺丰速运"
        case 3: return "圆通速递"
        case 4: return "韵达快递"
        case 5: return "申通快递"
        case 6: return "极兔速递"
        case 7: return "中国邮政"
        case 8: return "京东物流"
        case 9: return "德邦快递"
        case 10: return "丰巢"
        case 11: return "菜鸟驿站"
        case 12: return "百世快递"
        case 16: return "DHL"
        case 17: return "联邦快递"
        case 18: return "UPS"
        case 20: return "闪送"
        default: return "其他快递"
        }
    }

    private static func stationName(_ parcel: Parcel, stations: [Station]) -> String {
        if let linked = stations.first(where: { $0.id == parcel.courierStationUuid }) {
            return linked.courierStationName
        }
        let text = [parcel.courierStationName, parcel.address, parcel.smsContent,
                    parcel.trackLatest ?? ""].joined(separator: " ")
        if let match = StationMatcher.match(stations, text: text) {
            return match.courierStationName
        }
        if !parcel.courierStationName.isEmpty { return parcel.courierStationName }
        if !parcel.address.isEmpty { return parcel.address }
        return courierName(parcel)
    }

    static func update(with parcels: [Parcel]) async {
        guard ParcelStore.shared.snapshot.preferences.liveActivityEnabled,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            await stopAll()
            return
        }

        let stations = ParcelStore.shared.snapshot.stations
        let pending = parcels.filter { $0.type == "delivery" && $0.isPending }
            .sorted { ($0.arrivedAt ?? $0.createdAt) > ($1.arrivedAt ?? $1.createdAt) }

        guard !pending.isEmpty else {
            resetSession()
            await stopAll()
            return
        }

        let deadline = expiry(for: pending)
        guard Date() < deadline else {
            await stopAll()
            return
        }

        let items = pending.prefix(8).map {
            PickupActivityItem(code: pickupCode($0),
                               station: stationName($0, stations: stations),
                               company: courierName($0))
        }
        let state = PickupActivityAttributes.ContentState(
            pending: pending.count,
            code: pending.first.map(pickupCode) ?? "",
            station: pending.first?.stationText ?? "",
            style: style,
            items: items
        )

        let existing = Activity<PickupActivityAttributes>.activities
        if let first = existing.first {
            await first.update(ActivityContent(state: state, staleDate: deadline))
            for extra in existing.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        } else {
            do {
                _ = try Activity<PickupActivityAttributes>.request(
                    attributes: PickupActivityAttributes(title: "包裹助手"),
                    content: ActivityContent(state: state, staleDate: deadline),
                    pushType: nil
                )
            } catch {
                print("Live Activity request failed: \(error.localizedDescription)")
            }
        }
        scheduleEnd(at: deadline)
    }
}
