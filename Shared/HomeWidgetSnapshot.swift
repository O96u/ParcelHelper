import Foundation

// A small, credential-free snapshot shared by the containing app and WidgetKit.
// The signing tool must grant BOTH binaries the same App Group entitlement.
struct HomeWidgetParcel: Codable, Identifiable, Hashable {
    var id: String
    var code: String
    var company: String
    var title: String
    var station: String
    var latest: String
    var source: String
}

struct HomeWidgetSnapshot: Codable {
    var pending: [HomeWidgetParcel]
    var transit: [HomeWidgetParcel]
    var pendingTotal: Int
    var transitTotal: Int
    var lastSync: Date
    var showTransit: Bool

    static let empty = HomeWidgetSnapshot(
        pending: [], transit: [], pendingTotal: 0, transitTotal: 0,
        lastSync: .distantPast, showTransit: true)
}

enum HomeWidgetSharedStore {
    static let kind = "ParcelHelperHome"
    private static let filename = "parcelhelper-widget.json"

    // This ID must be present in both signed targets' App Groups entitlements.
    // iOS does not provide the SecTask entitlement-inspection API to apps.
    // Fail clearly instead of guessing another app's authorized group.
    static var configuredGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "ParcelHelperWidgetGroup") as? String ?? ""
    }

    private static var groupURL: URL? {
        let group = configuredGroup
        guard group.hasPrefix("group."), !group.contains("$(") else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group)
    }

    static var activeGroup: String? {
        groupURL == nil ? nil : configuredGroup
    }

    static var isAvailable: Bool { groupURL != nil }

    static var hasSnapshot: Bool {
        guard let url = snapshotURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static var canReadSnapshot: Bool {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url)
        else { return false }
        return (try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)) != nil
    }

    private static var readableSnapshotURL: URL? { snapshotURL }

    private static var snapshotURL: URL? {
        groupURL?.appendingPathComponent(filename)
    }

    private static var operationsURL: URL? {
        (readableSnapshotURL?.deletingLastPathComponent() ?? groupURL)?
            .appendingPathComponent("parcelhelper-ops", isDirectory: true)
    }

    static func read() -> HomeWidgetSnapshot {
        guard let url = readableSnapshotURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)
        else { return .empty }
        let picked = Set(pendingPickedIDs())
        guard !picked.isEmpty else { return value }
        var copy = value
        let matched = copy.pending.filter { picked.contains($0.id) }.count
        copy.pending.removeAll { picked.contains($0.id) }
        // A pending operation may be older than the snapshot or refer to a
        // different parcel. Only subtract items actually present in it.
        copy.pendingTotal = max(0, copy.pendingTotal - matched)
        return copy
    }

    /// Persist the latest snapshot, but only notify WidgetKit if visible parcel
    /// information changed. A new lastSync timestamp alone is not a reason to
    /// spend the system's widget reload budget.
    static func writeWithChange(_ snapshot: HomeWidgetSnapshot) -> (saved: Bool, changed: Bool) {
        guard let url = snapshotURL else { return (false, false) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return (false, false) }
        let previous = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: $0) }
        var lhs = snapshot
        var rhs = previous ?? .empty
        lhs.lastSync = .distantPast
        rhs.lastSync = .distantPast
        let changed = previous == nil ||
            (try? encoder.encode(lhs)) != (try? encoder.encode(rhs))
        do {
            if (try? Data(contentsOf: url)) != data {
                try data.write(to: url, options: .atomic)
            }
            return (true, changed)
        } catch {
            return (false, false)
        }
    }

    @discardableResult
    static func write(_ snapshot: HomeWidgetSnapshot) -> Bool {
        writeWithChange(snapshot).saved
    }

    // AppIntent only writes a single operation. The main App remains the sole
    // writer of its authoritative ParcelStore database.
    static func requestPickup(_ id: String) -> Bool {
        guard let dir = operationsURL, UUID(uuidString: id) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(id.utf8).write(to: dir.appendingPathComponent(id + ".txt"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func pendingPickedIDs() -> [String] {
        guard let dir = operationsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
              ) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "txt" else { return nil }
            let id = file.deletingPathExtension().lastPathComponent
            return UUID(uuidString: id) == nil ? nil : id
        }
    }

    static func clearPicked(_ ids: [String]) {
        guard let dir = operationsURL else { return }
        for id in ids where UUID(uuidString: id) != nil {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".txt"))
        }
    }
}
