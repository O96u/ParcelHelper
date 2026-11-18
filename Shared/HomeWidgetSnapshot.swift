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

    // LCSign and other signers can replace the App Groups entitlement while
    // leaving the unsigned IPA's Info.plist untouched. Prefer the configured
    // group only when it is really accessible; otherwise select from the
    // groups granted by the running process's *actual* code signature.
    // Both app and widget independently use this rule. Never hard-code
    // another developer's certificate group ID into source.
    static var configuredGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "ParcelHelperWidgetGroup") as? String ?? ""
    }

    static var signedGroups: [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String] else { return [] }
        return value.filter { $0.hasPrefix("group.") }.sorted()
    }

    private static func container(for group: String) -> URL? {
        guard group.hasPrefix("group."), !group.contains("$(") else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group)
    }

    // Prefer the exact configured group, then a shared-looking group, and
    // finally any actually accessible signed group. This is useful when
    // the signing tool rewrites entitlements, but does not grant permissions.
    static var activeGroup: String? {
        if container(for: configuredGroup) != nil { return configuredGroup }
        let groups = signedGroups.filter { container(for: $0) != nil }
        return groups.first(where: { $0.localizedCaseInsensitiveContains("parcelhelper") }) ??
            groups.first
    }

    private static var groupURL: URL? {
        guard let group = activeGroup else { return nil }
        return container(for: group)
    }

    static var isAvailable: Bool { groupURL != nil }

    // Distinguish an inaccessible container from a missing snapshot.
    static var hasSnapshot: Bool {
        guard let url = snapshotURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static var canReadSnapshot: Bool {
        guard let url = readableSnapshotURL, let data = try? Data(contentsOf: url)
        else { return false }
        return (try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)) != nil
    }

    // Extension signed with a different, overlapping profile? Search its
    // authorized containers for a snapshot before treating data as missing.
    // The host app still writes to a single selected group, not all groups.
    private static var readableSnapshotURL: URL? {
        let candidates = [configuredGroup] + signedGroups.filter { $0 != configuredGroup }
        for group in candidates {
            guard let url = container(for: group)?.appendingPathComponent(filename),
                  let data = try? Data(contentsOf: url),
                  (try? JSONDecoder().decode(HomeWidgetSnapshot.self, from: data)) != nil
            else { continue }
            return url
        }
        return nil
    }

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
