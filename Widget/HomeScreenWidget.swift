import SwiftUI
import WidgetKit
import AppIntents
import UIKit

// ParcelHelper's Home Screen widget uses the same visual language as the
// app's pickup dashboard: a blue summary card and readable parcel rows.
struct ParcelHomeEntry: TimelineEntry {
    let date: Date
    let model: HomeWidgetSnapshot
    let sharedGroupReady: Bool
    let snapshotReady: Bool
}

struct ParcelHomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ParcelHomeEntry {
        ParcelHomeEntry(date: Date(), model: .empty,
                        sharedGroupReady: true, snapshotReady: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ParcelHomeEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ParcelHomeEntry>) -> Void) {
        let entry = load()
        // This only re-reads the App Group snapshot. It does not fetch data
        // or launch the containing app; iOS can defer this date.
        // Use the app's configured preference exported in the snapshot.
        // WidgetKit may defer the resulting timeline date.
        let preferred = TimeInterval(max(5, min(120, entry.model.refreshMinutes ?? 15))) * 60
        let interval: TimeInterval
        if entry.model.pendingTotal > 0 {
            interval = max(30 * 60, preferred)
        } else if entry.model.transitTotal > 0 {
            interval = max(3 * 60 * 60, preferred)
        } else {
            interval = max(12 * 60 * 60, preferred)
        }
        completion(Timeline(entries: [entry],
                            policy: .after(Date().addingTimeInterval(interval))))
    }

    private func load() -> ParcelHomeEntry {
        ParcelHomeEntry(date: Date(), model: HomeWidgetSharedStore.read(),
                        sharedGroupReady: HomeWidgetSharedStore.isAvailable,
                        snapshotReady: HomeWidgetSharedStore.canReadSnapshot)
    }
}

struct MarkParcelPickedIntent: AppIntent {
    static var title: LocalizedStringResource = "标记包裹已取"
    static var description = IntentDescription("在桌面小组件中标记已取，打开包裹助手时同步到列表")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "包裹标识") var parcelID: String

    init() {}
    init(parcelID: String) { self.parcelID = parcelID }

    func perform() async throws -> some IntentResult {
        guard HomeWidgetSharedStore.requestPickup(parcelID) else {
            throw NSError(domain: "ParcelHelperWidget", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "小组件没有可用的共享 App Group"])
        }
        WidgetCenter.shared.reloadTimelines(ofKind: HomeWidgetSharedStore.kind)
        return .result()
    }
}

private struct ParcelHomeWidgetHost: View {
    let entry: ParcelHomeEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        ParcelHomeContent(model: entry.model, sharedGroupReady: entry.sharedGroupReady, snapshotReady: entry.snapshotReady, family: family) { item, compact in
            Button(intent: MarkParcelPickedIntent(parcelID: item.id)) {
                Image(systemName: "circle")
                    .font(.system(size: compact ? 16 : 19))
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 21 : 29, height: 29)
            }.buttonStyle(.plain).accessibilityLabel("标记 \(item.code) 为已取")
        }
        .containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
        .widgetURL(URL(string: "parcelhelper://parcel"))
    }
}

struct ParcelHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetSharedStore.kind,
                            provider: ParcelHomeProvider()) { entry in
            ParcelHomeWidgetHost(entry: entry)
        }
        .configurationDisplayName("包裹助手")
        .description("原生蓝色卡片展示待取和在途包裹，支持快速标记已取")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
