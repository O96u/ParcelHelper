import Foundation
import Combine
import WidgetKit

@MainActor final class ParcelStore: ObservableObject {
    static let shared = ParcelStore()
    @Published private(set) var snapshot: Snapshot
    private let url: URL
    // Keep JSON encoding and filesystem writes off the scrolling/UI thread.
    // A serial queue preserves save ordering (new snapshots always win).
    private let persistenceQueue = DispatchQueue(label: "ParcelHelper.snapshot.write", qos: .utility)
    private static let ignoredAutoStationsKey = "native.stations.ignoredAutoNames.v1"
    private var localURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("parcelhelper-snapshot.json") }

    // Tombstones prevent a removed delivery from being silently recreated by
    // the next automatic platform refresh.
    private static let ignoredKey = "native.deleted.shipments.v1"
    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }
    private static func key(mail: String, order: String, source: String,
                            code: String = "", station: String = "") -> String? {
        keys(mail: mail, order: order, source: source, code: code, station: station).first
    }

    // Track every stable identity available at deletion time. A later sync can
    // supply a tracking number missing in the first import; a one-key tombstone
    // would allow the same explicitly deleted package to reappear.
    private static func keys(mail: String, order: String, source: String,
                             code: String = "", station: String = "") -> [String] {
        var result: [String] = []
        let validMail = normalized(mail)
        if validMail.range(of: #"^[A-Z0-9-]{8,40}$"#, options: .regularExpression) != nil {
            result.append("mail:" + validMail)
        }
        let normalizedOrder = normalized(order)
        if !normalizedOrder.isEmpty { result.append("order:" + normalizedOrder) }
        let pick = normalized(code), loc = normalized(station)
        if pick.range(of: #"^[A-Z0-9_-]{2,20}$"#, options: .regularExpression) != nil,
           !loc.isEmpty {
            result.append("pickup:" + source + ":" + pick + ":" + loc)
        }
        return result
    }

    func isDeletedShipment(source: String, order: String, mail: String,
                           code: String = "", station: String = "") -> Bool {
        // Prefer the strongest identity supplied by the new shipment.
        // A pickup code can be reused at a station, so it must not suppress
        // a *different* tracking number merely because its code matches.
        let identities = Self.keys(mail: mail, order: order, source: source, code: code, station: station)
        let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
        let strong = identities.filter { !$0.hasPrefix("pickup:") }
        return (strong.isEmpty ? identities : strong).contains(where: ignored.contains)
    }

    private func recordDeletion(_ parcel: Parcel) {
        let source = parcel.source ?? parcel.srcApp?.id ?? ""
        let candidates = Array(Set(Self.keys(mail: parcel.mailNo ?? "", order: parcel.orderId ?? "",
                                   source: source, code: parcel.displayCode,
                                   station: parcel.stationText) + parcel.allOrderIDs.map { "order:" + Self.normalized($0) }))
        guard !candidates.isEmpty else { return }
        var ignored = UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? []
        let removed = Set(candidates)
        ignored.removeAll(where: removed.contains)
        ignored.insert(contentsOf: candidates, at: 0)
        UserDefaults.standard.set(Array(ignored.prefix(1500)), forKey: Self.ignoredKey)
    }

    /// Merge only exact carrier tracking numbers (or identical legacy order
    /// IDs without tracking numbers). Product titles are NOT unique identities.
    private static func collapseExactDuplicates(_ items: [Parcel]) -> [Parcel] {
        var merged: [Parcel] = []
        var indices: [String: Int] = [:]
        for parcel in items {
            let source = parcel.source ?? parcel.srcApp?.id ?? ""
            let key = Self.key(mail: parcel.mailNo ?? "", order: parcel.orderId ?? "",
                               source: source)
            guard let key else { merged.append(parcel); continue }
            if let i = indices[key] {
                var existing = merged[i]
                if existing.userTitle == nil { existing.userTitle = parcel.userTitle }
                if existing.itemTitle == nil || existing.itemTitle == "拼多多订单" {
                    if let title = parcel.itemTitle, !title.isEmpty { existing.itemTitle = title }
                }
                if existing.trackCompany == nil || existing.trackCompany?.isEmpty == true {
                    existing.trackCompany = parcel.trackCompany
                }
                if existing.mailNo == nil { existing.mailNo = parcel.mailNo }
                if existing.shipperCode == nil { existing.shipperCode = parcel.shipperCode }
                if existing.orderId == nil { existing.orderId = parcel.orderId }
                let orders = Array(Set(existing.allOrderIDs + parcel.allOrderIDs)).sorted()
                existing.linkedOrderIDs = orders.isEmpty ? nil : orders
                if parcel.retainedLocally == true { existing.retainedLocally = true }
                if existing.code.isEmpty { existing.code = parcel.code }
                if existing.courierStationName.isEmpty { existing.courierStationName = parcel.courierStationName }
                if existing.courierStationUuid.isEmpty { existing.courierStationUuid = parcel.courierStationUuid }
                if existing.address.isEmpty { existing.address = parcel.address }
                for code in ([parcel.code] + parcel.codes).filter({ !$0.isEmpty }) {
                    if !existing.codes.contains(code) { existing.codes.append(code) }
                }
                TrackMerge.apply(to: &existing, nodes: parcel.trackNodes,
                                 summary: parcel.trackLatest ?? "")
                existing.trackUpdatedAt = max(existing.trackUpdatedAt ?? 0, parcel.trackUpdatedAt ?? 0)
                if parcel.pickedByUser || parcel.isDone && !existing.isDone {
                    existing.status = 2
                    existing.pickedByUser = parcel.pickedByUser
                    existing.pickedAt = parcel.pickedAt ?? existing.pickedAt
                }
                if existing.arrivedAt == nil { existing.arrivedAt = parcel.arrivedAt }
                if existing.closed == nil { existing.closed = parcel.closed }
                if existing.srcApp == nil { existing.srcApp = parcel.srcApp }
                if existing.source == nil { existing.source = parcel.source }
                let allAccounts = Set((existing.linkedAccounts ?? []) + (parcel.linkedAccounts ?? []))
                existing.linkedAccounts = allAccounts.isEmpty ? nil : allAccounts.sorted()
                existing.createdAt = min(existing.createdAt, parcel.createdAt)
                merged[i] = existing
            } else {
                indices[key] = merged.count
                merged.append(parcel)
            }
        }
        return merged
    }

    private init() {
        // A third-party signing profile need not provide an App Group.
        // Keep the only authoritative copy in this app's own Documents.
        let localFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("parcelhelper-snapshot.json")
        url = localFile
        let data = try? Data(contentsOf: localFile)
        let backup = localFile.appendingPathExtension("backup")
        let recovered = (try? Data(contentsOf: backup)).flatMap {
            try? JSONDecoder().decode(Snapshot.self, from: $0)
        }
        let primary = data.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        snapshot = primary ?? recovered ?? Snapshot()
        if primary == nil, let data {
            // Preserve corrupt bytes for recovery, never replace a good backup.
            try? data.write(to: localFile.appendingPathExtension("damaged"), options: .atomic)
        }
        snapshot.parcels = Self.collapseExactDuplicates(snapshot.parcels)
        // Migrate station names already present in the existing parcel database.
        if discoverStations() { persist() }
    }
    func homeWidgetSnapshot() -> HomeWidgetSnapshot {
        let pending = snapshot.parcels.filter { $0.type == "delivery" && $0.isPending }
            .sorted { ($0.trackUpdatedAt ?? $0.createdAt) > ($1.trackUpdatedAt ?? $1.createdAt) }
        let transit = snapshot.parcels.filter { $0.type == "delivery" && $0.isTransit }
            .sorted { ($0.trackUpdatedAt ?? $0.createdAt) > ($1.trackUpdatedAt ?? $1.createdAt) }
        func row(_ parcel: Parcel) -> HomeWidgetParcel {
            HomeWidgetParcel(
                id: parcel.uuid, code: parcel.displayCode,
                company: parcel.carrierDisplayName,
                title: parcel.itemTitle ?? parcel.userTitle ?? "",
                station: parcel.stationText, latest: parcel.currentTrackingText,
                source: parcel.source ?? parcel.srcApp?.id ?? "")
        }
        let lastSync = UserDefaults.standard.double(forKey: "native.home.lastRefresh")
        return HomeWidgetSnapshot(
            pending: Array(pending.prefix(10)).map(row),
            transit: Array(transit.prefix(6)).map(row),
            pendingTotal: pending.count, transitTotal: transit.count,
            lastSync: lastSync > 0 ? Date(timeIntervalSince1970: lastSync) : .distantPast,
            showTransit: snapshot.preferences.widgetShowTransit,
            refreshMinutes: RefreshPolicy.minutes)
    }

    func persist() {
        // The widget records only picked-ID operations. Apply them in the
        // main app, and remove operation files only after the disk save succeeds.
        let widgetOps = HomeWidgetSharedStore.pendingPickedIDs()
        if !widgetOps.isEmpty {
            let selected = Set(widgetOps)
            for i in snapshot.parcels.indices where selected.contains(snapshot.parcels[i].uuid) && snapshot.parcels[i].isPending {
                snapshot.parcels[i].status = 2
                snapshot.parcels[i].pickedByUser = true
                snapshot.parcels[i].pickedAt = snapshot.parcels[i].pickedAt ??
                    Date().timeIntervalSince1970 * 1000
            }
        }
        snapshot.parcels = Self.collapseExactDuplicates(snapshot.parcels)
        _ = discoverStations()
        snapshot.updatedAt = Date()
        let current = snapshot
        let widgetSnapshot = homeWidgetSnapshot()
        let destination = url
        persistenceQueue.async {
            do {
                let data = try JSONEncoder().encode(current)
                if let old = try? Data(contentsOf: destination),
                   (try? JSONDecoder().decode(Snapshot.self, from: old)) != nil {
                    try old.write(to: destination.appendingPathExtension("backup"), options: .atomic)
                }
                try data.write(to: destination, options: .atomic)
                let published = HomeWidgetSharedStore.writeWithChange(widgetSnapshot)
                if published.saved {
                    HomeWidgetSharedStore.clearPicked(widgetOps)
                    if published.changed {
                        WidgetCenter.shared.reloadTimelines(ofKind: HomeWidgetSharedStore.kind)
                    }
                }
            } catch {
                print("ParcelStore save failed: \(error)")
            }
        }
        let rows = snapshot.parcels
        let enabled = snapshot.preferences.liveActivityEnabled
        Task { await LiveActivityCoordinator.update(with: enabled ? rows : []) }
    }
    func applySyncBatch(_ parcels: [Parcel]) {
        guard !parcels.isEmpty else { return }
        var next = snapshot
        var indices = Dictionary(next.parcels.enumerated().map { ($0.element.uuid, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var inserted: [Parcel] = []
        for parcel in parcels {
            if let index = indices[parcel.uuid] {
                if index < next.parcels.count { next.parcels[index] = parcel }
                else { inserted[index - next.parcels.count] = parcel }
            } else {
                indices[parcel.uuid] = next.parcels.count + inserted.count
                inserted.append(parcel)
            }
        }
        next.parcels = Array(inserted.reversed()) + next.parcels
        snapshot = next
        persist()
    }
    func upsert(_ parcel: Parcel, persistNow: Bool = true) {
        if let i = snapshot.parcels.firstIndex(where: { $0.uuid == parcel.uuid }) {
            snapshot.parcels[i] = parcel
        } else {
            snapshot.parcels.insert(parcel, at: 0)
        }
        // Platform sync merges can import dozens of records. Defer one disk,
        // WidgetKit and Live Activity update until the whole batch is merged.
        // Interactive edits still use the default immediate persistence.
        if persistNow { persist() }
    }
    /// Avoid duplicates when an SMS automation runs more than once. A pickup
    /// code is not globally unique: only match it together with its station
    /// and only for recent, still-open parcels.
    @discardableResult
    func upsertRecognizedText(_ incoming: Parcel) -> Bool {
        let body = incoming.smsContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Self.normalized(incoming.displayCode)
        let location = Self.normalized(incoming.courierStationName)
        let mail = Self.normalized(incoming.mailNo ?? "")
        let cutoff = Date().timeIntervalSince1970 * 1000 - 14 * 24 * 3600 * 1000
        let index = snapshot.parcels.firstIndex { old in
            if !body.isEmpty && old.smsContent.trimmingCharacters(in: .whitespacesAndNewlines) == body {
                return true
            }
            if !mail.isEmpty && Self.normalized(old.mailNo ?? "") == mail { return true }
            return old.type == "delivery" && !old.isDone &&
                !code.isEmpty && !location.isEmpty &&
                Self.normalized(old.displayCode) == code &&
                Self.normalized(old.courierStationName) == location &&
                old.createdAt >= cutoff
        }
        guard let i = index else {
            upsert(incoming)
            return false
        }
        var existing = snapshot.parcels[i]
        if existing.code.isEmpty { existing.code = incoming.code }
        if existing.mailNo == nil { existing.mailNo = incoming.mailNo }
        if existing.courierStationName.isEmpty { existing.courierStationName = incoming.courierStationName }
        if existing.address.isEmpty { existing.address = incoming.address }
        if existing.trackCompany == nil || existing.trackCompany?.isEmpty == true {
            existing.trackCompany = incoming.trackCompany
        }
        if existing.smsContent.isEmpty { existing.smsContent = incoming.smsContent }
        if existing.arrivedAt == nil && !existing.isDone { existing.arrivedAt = incoming.arrivedAt }
        snapshot.parcels[i] = existing
        persist()
        return true
    }

    /// Only called after the user reviews the imported details and confirms save.
    /// For duplicates, update selected fields without resetting pickup state or history.
    func importDouyin(_ incoming: Parcel) -> Bool {
        guard let mail = incoming.mailNo?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty else {
            upsert(incoming)
            return false
        }
        if let index = snapshot.parcels.firstIndex(where: {
            ($0.mailNo ?? "").caseInsensitiveCompare(mail) == .orderedSame
        }) {
            var existing = snapshot.parcels[index]
            if existing.userTitle == nil || existing.userTitle?.isEmpty == true {
                existing.userTitle = incoming.userTitle
            }
            if existing.trackCompany == nil || existing.trackCompany?.isEmpty == true {
                existing.trackCompany = incoming.trackCompany
            }
            if existing.orderId == nil || existing.orderId?.isEmpty == true {
                existing.orderId = incoming.orderId
            }
            if existing.code.isEmpty { existing.code = incoming.code }
            if existing.courierStationName.isEmpty { existing.courierStationName = incoming.courierStationName }
            if existing.trackLatest == nil || existing.trackLatest?.isEmpty == true {
                existing.trackLatest = incoming.trackLatest
            }
            if existing.smsContent.isEmpty { existing.smsContent = incoming.smsContent }
            if existing.arrivedAt == nil && !existing.isDone { existing.arrivedAt = incoming.arrivedAt }
            if existing.source == nil || existing.source?.isEmpty == true {
                existing.source = "douyin"
            }
            // A confirmed Douyin import retains its small source logo even
            // if a carrier/platform had previously created this shipment.
            existing.srcApp = incoming.srcApp
            snapshot.parcels[index] = existing
            persist()
            return true
        }
        upsert(incoming)
        return false
    }

    /// Delete account-owned synced parcels, not manual/SMS parcels.
    /// Retain records linked to other authorized accounts.
    @discardableResult
    func removeImportedParcels(linkedTo accountID: String, platform: String) -> Int {
        let sources: Set<String> = platform == "taobao" ? ["taobao", "cainiao"] : [platform]
        let legacy = accountID.hasPrefix("legacy:")
        var survivors: [Parcel] = []
        var removed = 0
        var changed = false
        for var parcel in snapshot.parcels {
            let source = parcel.source ?? parcel.srcApp?.id ?? ""
            let linked = parcel.linkedAccounts ?? []
            let matched = linked.contains(accountID)
            let olderImported = legacy && linked.isEmpty &&
                sources.contains(source) &&
                parcel.orderId?.hasPrefix(source + ":") == true &&
                parcel.smsContent.isEmpty
            guard matched || olderImported else {
                survivors.append(parcel)
                continue
            }
            changed = true
            let others = linked.filter { $0 != accountID }
            if others.isEmpty && parcel.retainedLocally != true && parcel.smsContent.isEmpty {
                removed += 1
            } else {
                parcel.linkedAccounts = others
                let remainingOrders = parcel.allOrderIDs.filter { order in
                    !sources.contains { source in
                        let prefix = legacy ? source + ":" : source + ":" + accountID + ":"
                        if !order.hasPrefix(prefix) { return false }
                        return !legacy || !order.dropFirst(prefix.count).contains(":")
                    }
                }
                parcel.linkedOrderIDs = remainingOrders.isEmpty ? nil : remainingOrders
                if let order = parcel.orderId, !remainingOrders.contains(order) {
                    parcel.orderId = remainingOrders.first
                }
                survivors.append(parcel)
            }
        }
        if changed {
            snapshot.parcels = survivors
            persist()
        }
        return removed
    }

    func markDone(_ id: String, done: Bool) {
        guard let i = snapshot.parcels.firstIndex(where: { $0.uuid == id }) else { return }
        snapshot.parcels[i].status = done ? 2 : 1
        snapshot.parcels[i].pickedByUser = done
        snapshot.parcels[i].pickedAt = done ? Date().timeIntervalSince1970 * 1000 : nil
        persist()
    }
    func markPickedBatch(_ ids: Set<String>) {
        let now = Date().timeIntervalSince1970 * 1000
        var changed = false
        for i in snapshot.parcels.indices where ids.contains(snapshot.parcels[i].uuid) && snapshot.parcels[i].isPending {
            snapshot.parcels[i].status = 2
            snapshot.parcels[i].pickedByUser = true
            snapshot.parcels[i].pickedAt = now
            changed = true
        }
        if changed { persist() }
    }

    func importWaybills(_ values: [String]) -> Int {
        let existing = Set(snapshot.parcels.compactMap { $0.mailNo }.map(Self.normalized))
        var seen = existing
        var count = 0
        for raw in values {
            let mail = Self.normalized(raw)
            guard mail.range(of: #"^[A-Z0-9-]{8,40}$"#, options: .regularExpression) != nil,
                  mail.contains(where: \.isNumber), seen.insert(mail).inserted else { continue }
            var parcel = Parcel()
            parcel.mailNo = mail
            snapshot.parcels.insert(parcel, at: 0)
            count += 1
        }
        if count > 0 { persist() }
        return count
    }

    func delete(_ id: String) {
        guard let parcel = snapshot.parcels.first(where: { $0.uuid == id }) else { return }
        recordDeletion(parcel)
        snapshot.parcels.removeAll { $0.uuid == id }
        persist()
    }

    /// Create an editable station only from a clearly labelled pickup location,
    /// never from generic "arrived in city" or carrier/status text.
    private static func normalizedStationName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func verifiedStationName(for parcel: Parcel) -> String? {
        let knownTypes = ["驿站", "代收点", "快递超市", "快递柜", "自提点", "取件点", "服务站"]
        let invalid = ["其他驿站", "快递驿站", "菜鸟驿站", "代收点", "快递柜", "自提点"]
        let preferred = normalizedStationName(parcel.courierStationName)
        // Some logistics services identify a pickup shop by its branch name
        // ("上东一号一期10栋1单元店") without the word "驿站".
        // Only trust the dedicated pickup-station field when a parcel has
        // actual pickup evidence; never create stations from the recipient
        // address, a generic courier status or a sorting hub.
        let excluded = ["分拨中心", "转运中心", "集散中心", "运转中心", "揽收",
                        "运输中", "派送中", "已签收", "已送达", "其他驿站",
                        "快递驿站", "菜鸟驿站", "其他站点", "未知驿站"]
        let explicitPickup = parcel.isPending || parcel.isDone
        let hasUsefulName = preferred.count >= 4 && preferred.count <= 65 &&
            !invalid.contains(preferred) &&
            !excluded.contains(where: preferred.contains) &&
            !["暂无", "未知", "其他", "快递包裹"].contains(preferred)
        if hasUsefulName &&
            (knownTypes.contains(where: preferred.contains) || explicitPickup) {
            return preferred
        }

        // For imported route records, require explicit store/locker language
        // with a location name. Avoid city sorting hubs and random addresses.
        let text = ([parcel.trackLatest ?? ""] + parcel.trackNodes.prefix(12).map(\.text))
            .joined(separator: "\n")
        let pattern = #"(?:放入|存放在|已入库至|已存入|已送至|已送达|已到达|寄存于)[：:\s]*([一-龥A-Za-z0-9·（）()\-]{2,36}?(?:快递超市|驿站|代收点|快递柜|自提点|取件点))"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let result = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text)
        else { return nil }
        let name = normalizedStationName(String(text[range]))
        guard name.count >= 4, !invalid.contains(name),
              !["分拨中心", "转运中心", "揽收"].contains(where: name.contains)
        else { return nil }
        return name
    }

    @discardableResult private func discoverStations() -> Bool {
        var modified = false
        let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredAutoStationsKey) ?? [])
        for i in snapshot.parcels.indices {
            guard snapshot.parcels[i].type == "delivery" else { continue }
            let currentID = snapshot.parcels[i].courierStationUuid
            if !currentID.isEmpty,
               snapshot.stations.contains(where: { $0.id == currentID }) {
                continue // Preserve any manually edited station association.
            }
            guard let name = Self.verifiedStationName(for: snapshot.parcels[i]),
                  !ignored.contains(name) else { continue }
            if let existing = snapshot.stations.first(where: {
                Self.normalizedStationName($0.courierStationName)
                    .localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                if snapshot.parcels[i].courierStationUuid != existing.id {
                    snapshot.parcels[i].courierStationUuid = existing.id
                    modified = true
                }
                continue
            }
            var station = Station()
            station.courierStationName = name
            let address = Self.normalizedStationName(snapshot.parcels[i].address)
            // A generic recipient address is NOT a station address.
            if address.count >= 5 && address.count <= 100 &&
               (address.contains(name) || ["驿站", "代收点", "快递柜", "快递超市"]
                .contains(where: address.contains)) {
                station.address = address
            }
            station.keywords = [name]
            station.notes = "从物流信息自动识别，可自行核对名称和补全地址"
            snapshot.stations.append(station)
            snapshot.parcels[i].courierStationUuid = station.id
            modified = true
        }
        return modified
    }

    func upsertStation(_ s: Station) {
        if let i = snapshot.stations.firstIndex(where: { $0.id == s.id }) { snapshot.stations[i] = s }
        else { snapshot.stations.append(s) }
        // A new manual record explicitly overrides a previous ignored auto match.
        let name = Self.normalizedStationName(s.courierStationName)
        var ignored = UserDefaults.standard.stringArray(forKey: Self.ignoredAutoStationsKey) ?? []
        ignored.removeAll { $0 == name }
        UserDefaults.standard.set(ignored, forKey: Self.ignoredAutoStationsKey)
        persist()
    }
    func removeStation(_ id: String) {
        guard let station = snapshot.stations.first(where: { $0.id == id }) else { return }
        let name = Self.normalizedStationName(station.courierStationName)
        var ignored = UserDefaults.standard.stringArray(forKey: Self.ignoredAutoStationsKey) ?? []
        if !ignored.contains(name) { ignored.append(name) }
        UserDefaults.standard.set(ignored, forKey: Self.ignoredAutoStationsKey)
        snapshot.stations.removeAll { $0.id == id }
        persist()
    }
    func changePreferences(_ f: (inout Preferences) -> Void) { f(&snapshot.preferences); persist() }

}

