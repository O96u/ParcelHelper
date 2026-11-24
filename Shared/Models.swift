import Foundation

struct TrackNode: Codable, Hashable, Identifiable {
    var time: String
    var text: String
    var id: String { "\(time)-\(text)" }
}

// One conservative merge policy for platform sync, details and storage.
enum TrackMerge {
    static func date(_ value: String) -> Date? {
        if let epoch = Double(value), epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch > 1_000_000_000_000 ? epoch / 1000 : epoch)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    static func ordered(_ nodes: [TrackNode]) -> [TrackNode] {
        var seen = Set<TrackNode>()
        let unique = nodes.filter { seen.insert($0).inserted }
        let dated = unique.enumerated().map { (offset: $0.offset, element: $0.element, parsed: date($0.element.time)) }
        return dated.sorted { lhs, rhs in
            switch (lhs.parsed, rhs.parsed) {
            case let (a?, b?): return a == b ? lhs.offset < rhs.offset : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
    static func apply(to parcel: inout Parcel, nodes: [TrackNode], summary: String) {
        let old = ordered(parcel.trackNodes)
        let incoming = ordered(nodes)
        let oldDate = old.first.flatMap { date($0.time) }
        let newDate = incoming.first.flatMap { date($0.time) }
        let accept: Bool
        if let oldDate {
            accept = newDate.map { $0 > oldDate } ?? false
        } else {
            accept = old.isEmpty || newDate != nil
        }
        // Preserve the existing event when sources disagree at equal time.
        parcel.trackNodes = Array(ordered(accept ? incoming + old : old + incoming).prefix(60))
        if accept {
            let latest = incoming.first?.text ?? summary
            if !latest.isEmpty { parcel.trackLatest = latest }
        } else if parcel.trackLatest?.isEmpty != false {
            parcel.trackLatest = old.first?.text ?? incoming.first?.text
        }
    }
}

struct Parcel: Codable, Identifiable, Hashable {
    var uuid: String = UUID().uuidString
    var code: String = ""
    var codes: [String] = []
    var companyName: Int = 0
    var address: String = ""
    var phone: String = ""
    var notes: String = ""
    var status: Int = 1
    var type: String = "delivery"
    var codeTime: String = ""
    var smsContent: String = ""
    var courierStationName: String = ""
    var courierStationUuid: String = ""
    var createdAt: Double = Date().timeIntervalSince1970 * 1000
    var mailNo: String? = nil
    var shipperCode: String? = nil
    var trackCompany: String? = nil
    var trackLatest: String? = nil
    var trackNodes: [TrackNode] = []
    var trackUpdatedAt: Double? = nil
    var source: String? = nil
    // A shipment may be visible to more than one authorized platform account.
    // Optional for compatibility with snapshots saved by older versions.
    var linkedAccounts: [String]? = nil
    var receiverCity: String? = nil
    var receiverAddress: String? = nil
    var receiverName: String? = nil
    var receiverPhone: String? = nil
    var orderId: String? = nil
    var pickedByUser: Bool = false
    var eta: String? = nil
    var etaAt: Double? = nil
    var pickedAt: Double? = nil
    var userTitle: String? = nil
    var itemTitle: String? = nil
    var srcApp: SourceApp? = nil
    var arrivedAt: Double? = nil
    var closed: String? = nil
    var id: String { uuid }
    /// Compare all persisted parcel content, not a manually maintained subset
    /// of fields. The last-fetch timestamp alone is not a user-visible update.
    func hasSyncedContentChange(comparedTo previous: Parcel?) -> Bool {
        guard var previous else { return true }
        var updated = self
        updated.trackUpdatedAt = nil
        previous.trackUpdatedAt = nil
        return updated != previous
    }
    var title: String { [userTitle, itemTitle, trackCompany].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "快递包裹" }
    /// Confirm a recipient's completed collection, not a station's signature
    /// or a courier's pickup. The word order matters: delivery services use
    /// both "取件完成" and "完成取件" (e.g. 菜鸟驿站完成取件).
    static func confirmsRecipientPickup(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let exclusions = ["快递员已取件", "快递员完成取件", "揽收取件",
                          "商家已取件", "商家完成取件", "驿站代签收",
                          "代为签收", "待取件", "请取件", "未取件",
                          "未完成取件", "尚未完成取件", "取件未完成",
                          "取件失败", "未成功取件", "取件取消"]
        guard !exclusions.contains(where: text.contains) else { return false }
        let terms = ["您已取件", "您已取走", "用户已取", "用户取件成功",
                     "取件成功", "取件完成", "完成取件", "已取走",
                     "包裹已取走", "已被取走", "已领取", "已被领取",
                     "本人签收", "收件人已取", "收件人取件", "已从驿站取出",
                     "已从代收点取出", "已从快递柜取出", "已从自提点取出",
                     "快件已取出签收", "包裹已取出签收", "取出并签收"]
        return terms.contains(where: text.contains)
    }

    /// Prefer the most recent real tracking event to the platform's summary.
    /// This also corrects the status of parcels stored before an app update.
    var latestPickupConfirmed: Bool {
        // Providers use both newest-first and oldest-first timelines. A
        // confirmed recipient collection may therefore be the last node.
        Self.confirmsRecipientPickup(currentTrackingText)
    }
    var currentTrackingText: String {
        // Saved summaries are authoritative when a provider supplies no timeline.
        TrackMerge.ordered(trackNodes).first?.text ?? trackLatest ?? ""
    }
    var isDone: Bool { status == 2 || pickedByUser || latestPickupConfirmed }
    /// Some JD doorstep deliveries say "您的订单已送达" without "已签收".
    /// Arrival at a pickup location is not confirmation of recipient delivery.
    static func confirmsFinalDelivery(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let station = ["驿站", "代收点", "快递柜", "自提柜", "自提点", "分拨中心",
                       "转运中心", "集散中心", "网点", "派送中", "正在派送",
                       "待取件", "请取件", "暂存", "代签收", "未送达", "未签收"]
        guard !station.contains(where: text.contains) else { return false }
        return ["您的订单已送达", "订单已送达", "已送达收件人",
                "已送达客户", "已送达本人"].contains(where: text.contains)
    }
    // The courier marked this package delivered, not necessarily picked up
    // personally. Do not conflate signature and user's pickup.
    var isSigned: Bool {
        guard !isDone else { return false }
        let excluded = ["待签收", "等待签收", "签收中", "未签收", "代签收",
                        "代为签收", "驿站签收", "网点签收", "快递柜签收", "暂存签收"]
        let signed = ["已签收", "签收成功", "已妥投", "本人签收",
                      "收件人签收", "已完成签收", "已送达收件人"]
        // Also inspect route history when the summary has not caught up.
        let text = currentTrackingText
        return !excluded.contains(where: text.contains) &&
            (text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "SIGN" ||
             signed.contains(where: text.contains) ||
             Self.confirmsFinalDelivery(text))
    }
    var displayStatus: String {
        if isDone { return "已取件" }
        if isSigned {
            return Self.confirmsFinalDelivery(currentTrackingText) ? "已送达" : "已签收"
        }
        if isPending { return "待取件" }
        return "运输中"
    }
    var isPending: Bool {
        guard !isDone, !isSigned, closed == nil else { return false }
        if arrivedAt != nil { return true }
        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && code != mailNo { return true }
        // The original model requires a real pickup code or arrival timestamp.
        return !codes.isEmpty
    }
    var isTransit: Bool { !isDone && !isSigned && !isPending && closed == nil }
    var stationText: String { !courierStationName.isEmpty ? courierStationName : (!address.isEmpty ? address : "其他驿站") }
    var displayCode: String { code == mailNo ? "" : code }
}
struct SourceApp: Codable, Hashable { var id: String?; var name: String? }
struct Station: Codable, Identifiable, Hashable {
    var courierStationUuid: String = UUID().uuidString
    var courierStationName: String = ""
    var phone: String = ""
    var address: String = ""
    var businessHours: String = ""
    var notes: String = ""
    var keywords: [String] = []
    var phones: [String] = []
    var id: String { courierStationUuid }
}
struct Preferences: Codable {
    var reminderEnabled = true
    var reminderAfterHours = 24
    var appearanceMode = "system"
    var simpleMode = false
    var liveActivityEnabled = true
    var widgetShowTransit = true
    var nickName = "包裹助手"
    var kdBusinessID = ""
    var kdAPIKey = ""
}
struct Snapshot: Codable {
    var parcels: [Parcel] = []
    var stations: [Station] = []
    var preferences = Preferences()
    var updatedAt = Date()
}

enum StationMatcher {
    static func match(_ stations: [Station], text: String) -> Station? {
        var best: (Station, Int)?
        for s in stations {
            var score = 0
            for raw in s.keywords where raw.count >= 2 && text.contains(raw) { score = max(score, 100 + raw.count) }
            if s.courierStationName.count >= 2 && text.contains(s.courierStationName) { score = max(score, 50 + s.courierStationName.count) }
            if s.address.count >= 4 && text.contains(s.address) { score = max(score, 20 + s.address.count) }
            if score > (best?.1 ?? 0) { best = (s, score) }
        }
        return best?.0
    }
}
