import SwiftUI
import WidgetKit
import AppIntents

struct ParcelHomeEntry: TimelineEntry {
    var date: Date
    var model: HomeWidgetSnapshot
    var sharedGroupReady: Bool
}

struct ParcelHomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ParcelHomeEntry {
        ParcelHomeEntry(date: Date(), model: .empty, sharedGroupReady: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (ParcelHomeEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ParcelHomeEntry>) -> Void) {
        let entry = load()
        // This is a scheduling suggestion, not guaranteed 30-minute polling.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
    private func load() -> ParcelHomeEntry {
        ParcelHomeEntry(date: Date(), model: HomeWidgetSharedStore.read(),
                        sharedGroupReady: HomeWidgetSharedStore.isAvailable)
    }
}

struct MarkParcelPickedIntent: AppIntent {
    static var title: LocalizedStringResource = "标记包裹已取"
    static var description = IntentDescription("从小组件记录已取件，打开包裹助手时同步到包裹列表")
    static var openAppWhenRun: Bool = false
    @Parameter(title: "包裹标识") var parcelID: String

    init() {}
    init(parcelID: String) { self.parcelID = parcelID }

    func perform() async throws -> some IntentResult {
        guard HomeWidgetSharedStore.requestPickup(parcelID) else {
            throw NSError(domain: "ParcelHelperWidget", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "尚未配置可用的共享 App Group"])
        }
        WidgetCenter.shared.reloadTimelines(ofKind: HomeWidgetSharedStore.kind)
        return .result()
    }
}

private struct HomeWidgetRow: View {
    var item: HomeWidgetParcel
    var transit: Bool
    var compact: Bool = false

    private var displayCode: String {
        let value = item.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty ? value : (transit ? "运输中" : "待取件")
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 7) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: compact ? 24 : 29, height: compact ? 24 : 29)
                .background(.blue, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayCode)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(transit ? Color.blue : Color.primary)
                    .lineLimit(1)
                Text(item.title.isEmpty ? (item.latest.isEmpty ? item.company : item.latest) : item.title)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if transit {
                Image(systemName: "truck.box.fill")
                    .font(.system(size: compact ? 13 : 16))
                    .foregroundStyle(.blue)
                    .frame(width: compact ? 19 : 25)
            } else {
                Button(intent: MarkParcelPickedIntent(parcelID: item.id)) {
                    Image(systemName: "circle")
                        .font(.system(size: compact ? 15 : 19))
                        .foregroundStyle(.secondary)
                        .frame(width: compact ? 19 : 25, height: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("将 \(displayCode) 标记为已取")
            }
        }
        .frame(height: compact ? 27 : 30)
    }
}

private struct HomeWidgetHeader: View {
    let model: HomeWidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        HStack(spacing: 4) {
            Text("待取")
                .font(.system(size: family == .systemSmall ? 12 : 15, weight: .semibold))
            Text("\(model.pendingTotal)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text("件").font(.system(size: 9)).foregroundStyle(.secondary)
            if model.showTransit && model.transitTotal > 0 {
                Text("· 在途 \(model.transitTotal)")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 2)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: family == .systemSmall ? 23 : 28))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ParcelHomeContent: View {
    let entry: ParcelHomeEntry
    @Environment(\.widgetFamily) private var family

    private var maximumRows: Int { family == .systemLarge ? 10 : 4 }
    private var rows: [(HomeWidgetParcel, Bool)] {
        let waiting = Array(entry.model.pending.prefix(maximumRows)).map { ($0, false) }
        guard entry.model.showTransit else { return waiting }
        let moving = Array(entry.model.transit.prefix(maximumRows - waiting.count)).map { ($0, true) }
        return waiting + moving
    }
    private var moreCount: Int {
        max(0, entry.model.pendingTotal - rows.filter { !$0.1 }.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.sharedGroupReady {
                unavailable
            } else if family == .systemMedium {
                mediumLayout
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HomeWidgetHeader(model: entry.model, family: family)
                    if family == .systemLarge {
                        Divider().padding(.vertical, 3)
                    }
                    list(compact: family == .systemSmall)
                    Spacer(minLength: 0)
                    footer
                }
            }
        }
        .padding(family == .systemSmall ? 10 : 13)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "parcelhelper://parcel"))
    }

    private var mediumLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("待取件").font(.system(size: 11, weight: .medium))
                    Text("\(entry.model.pendingTotal)")
                        .font(.system(size: 33, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if entry.model.showTransit && entry.model.transitTotal > 0 {
                        Text("在途 \(entry.model.transitTotal)")
                            .font(.system(size: 9)).foregroundStyle(.blue)
                    }
                }
                .frame(width: 57)
                list(compact: false)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private func list(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            if rows.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("暂无包裹")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.0.id) { _, row in
                    HomeWidgetRow(item: row.0, transit: row.1, compact: compact)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(entry.model.lastSync == .distantPast
                 ? "尚未同步"
                 : entry.model.lastSync.formatted(date: .omitted, time: .shortened) + " 同步")
                .lineLimit(1)
            Spacer(minLength: 0)
            if moreCount > 0 {
                Text("还有 \(moreCount) 件")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text("等待小组件共享数据")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("请为 App 和小组件使用相同的 App Groups 签名，并打开 App 刷新")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ParcelHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetSharedStore.kind,
                            provider: ParcelHomeProvider()) { entry in
            ParcelHomeContent(entry: entry)
        }
        .configurationDisplayName("包裹助手")
        .description("查看待取件、在途包裹与取件码；点击圆圈标记已取")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
