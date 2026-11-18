import Foundation
import Security

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

    // sign.lc / other third-party signers may supply a different approved
    // group name. Do not hard-code a group that the profile cannot authorize.
    // To force a particular group, set ParcelHelperWidgetGroup in BOTH Info.plists.
    private static var groupURL: URL? {
        let fm = FileManager.default
        if let preferred = Bundle.main.object(forInfoDictionaryKey: "ParcelHelperWidgetGroup") as? String,
           preferred.hasPrefix("group."),
           let url = fm.containerURL(forSecurityApplicationGroupIdentifier: preferred) {
            return url
        }
        guard let task = SecTaskCreateFromSelf(nil),
              let granted = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String] else { return nil }
        for group in granted.filter({ $0.hasPrefix("group.") }).sorted() {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        return nil
    }

    static var isAvailable: Bool { groupURL != nil }

    private static var snapshotURL: URL? {
        groupURL?.appendingPathComponent(filename)
    }
    private static var operationsURL: URL? {
        groupURL?.appendingPathComponent("parcelhelper-ops", isDirectory: true)
    }

    static func read() -> HomeWidgetSnapshot {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)
        else { return .empty }
        let picked = Set(pendingPickedIDs())
        guard !picked.isEmpty else { return value }
        var copy = value
        copy.pending.removeAll { picked.contains($0.id) }
        copy.pendingTotal = max(0, copy.pendingTotal - picked.count)
        return copy
    }

    @discardableResult
    static func write(_ snapshot: HomeWidgetSnapshot) -> Bool {
        guard let url = snapshotURL,
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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
