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
        let interval: TimeInterval
        if entry.model.pendingTotal > 0 {
            interval = 30 * 60
        } else if entry.model.transitTotal > 0 {
            interval = 3 * 60 * 60
        } else {
            interval = 12 * 60 * 60
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

private enum ParcelWidgetTheme {
    static let blue = Color(red: 0.23, green: 0.48, blue: 0.95)
    static let deepBlue = Color(red: 0.12, green: 0.29, blue: 0.58)
    static let lightBlue = Color(red: 0.89, green: 0.93, blue: 1.0)
    static let orange = Color(red: 0.94, green: 0.57, blue: 0.18)
}

// The hero deliberately replaces the Scripting avatar/count design with
// ParcelHelper's native gradient dashboard card.
private struct ParcelWidgetHero: View {
    let model: HomeWidgetSnapshot
    let compact: Bool
    let vertical: Bool

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 5) {
                    Label("我的取件", systemImage: "shippingbox.fill")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.90))
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(model.pendingTotal)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("件待取")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    if model.showTransit {
                        Text("在途 \(model.transitTotal) 件")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(12)
            } else {
                HStack(spacing: compact ? 5 : 10) {
                    VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                        Text(compact ? "我的取件" : "我的取件清单")
                            .font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.87))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(model.pendingTotal)")
                                .font(.system(size: compact ? 22 : 29,
                                              weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("件待领取")
                                .font(.system(size: compact ? 9 : 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        if !compact && model.showTransit {
                            Text("在途 \(model.transitTotal) 件")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: compact ? 16 : 23))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(width: compact ? 28 : 41, height: compact ? 28 : 41)
                        .background(.white.opacity(0.17),
                                    in: RoundedRectangle(cornerRadius: compact ? 9 : 12))
                }
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 9 : 12)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil,
               alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [ParcelWidgetTheme.blue,
                                              ParcelWidgetTheme.deepBlue],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

private struct ParcelWidgetRow: View {
    let item: HomeWidgetParcel
    let transit: Bool
    let compact: Bool
    var dense = false

    private var code: String {
        let trimmed = item.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (transit ? "运输中" : "待取件") : trimmed
    }

    private var detail: String {
        if !item.title.isEmpty { return item.title }
        if !item.station.isEmpty { return item.station }
        return item.company.isEmpty ? "快递包裹" : item.company
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            PickupCarrierMark(company: item.company, accent: ParcelWidgetTheme.blue)
                .scaleEffect(dense ? 0.70 : (compact ? 0.76 : 0.92))
                .frame(width: dense ? 22 : (compact ? 24 : 29),
                       height: dense ? 22 : (compact ? 24 : 29))
            VStack(alignment: .leading, spacing: 1) {
                Text(code)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(transit ? ParcelWidgetTheme.blue : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: compact ? 8 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if transit {
                Image(systemName: "truck.box.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ParcelWidgetTheme.blue)
                    .frame(width: compact ? 17 : 26)
                    .accessibilityLabel("运输中")
            } else {
                Button(intent: MarkParcelPickedIntent(parcelID: item.id)) {
                    Image(systemName: "circle")
                        .font(.system(size: compact ? 16 : 19))
                        .foregroundStyle(.secondary)
                        .frame(width: compact ? 21 : 29, height: 29)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("标记 \(code) 为已取")
            }
        }
        .frame(height: dense ? 22 : (compact ? 29 : 33))
    }
}

private struct ParcelHomeContent: View {
    let entry: ParcelHomeEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }
    private var isMedium: Bool { family == .systemMedium }
    private var limit: Int { isSmall ? 2 : (isMedium ? 3 : 7) }

    private var rows: [(HomeWidgetParcel, Bool)] {
        let waiting = Array(entry.model.pending.prefix(limit)).map { ($0, false) }
        guard entry.model.showTransit else { return waiting }
        return waiting + Array(entry.model.transit.prefix(
            max(0, limit - waiting.count))).map { ($0, true) }
    }

    private var hidden: Int {
        max(0, entry.model.pendingTotal + (entry.model.showTransit ? entry.model.transitTotal : 0)
            - rows.count)
    }

    var body: some View {
        Group {
            if !entry.sharedGroupReady {
                issue("未配置小组件共享",
                      explanation: "请检查 App 与 Widget 的 App Groups 签名",
                      icon: "lock.shield")
            } else if !entry.snapshotReady {
                issue("还没有共享包裹数据",
                      explanation: "打开包裹助手，在小组件设置中重新写入",
                      icon: "arrow.triangle.2.circlepath")
            } else if isMedium {
                mediumContent
            } else {
                standardContent
            }
        }
        .padding(isSmall ? 10 : 12)
        .containerBackground(Color(uiColor: .secondarySystemGroupedBackground),
                             for: .widget)
        .widgetURL(URL(string: "parcelhelper://parcel"))
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: isSmall ? 5 : 9) {
            ParcelWidgetHero(model: entry.model, compact: isSmall, vertical: false)
            if rows.isEmpty {
                emptyContent
            } else {
                VStack(alignment: .leading, spacing: isSmall ? 0 : 1) {
                    ForEach(rows.indices, id: \.self) { index in
                        ParcelWidgetRow(item: rows[index].0, transit: rows[index].1,
                                        compact: isSmall)
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
    }

    // A full-width header avoids the large blank right column when the user
    // has only one parcel. More parcels automatically use a denser list.
    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            mediumHeader
            if rows.isEmpty {
                emptyContent
            } else if rows.count == 1 {
                featuredMediumRow(item: rows[0].0, transit: rows[0].1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows.indices, id: \.self) { index in
                        ParcelWidgetRow(item: rows[index].0,
                                        transit: rows[index].1,
                                        compact: true, dense: true)
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mediumHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.17),
                            in: RoundedRectangle(cornerRadius: 9))
            Text("我的取件")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(entry.model.pendingTotal)")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("件待取")
                    .font(.system(size: 11, weight: .semibold))
            }
            if entry.model.showTransit {
                Text("· 在途 \(entry.model.transitTotal)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: rows.count >= 3 ? 43 : 49)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [ParcelWidgetTheme.blue,
                                              ParcelWidgetTheme.deepBlue],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
    }

    private func featuredMediumRow(item: HomeWidgetParcel, transit: Bool) -> some View {
        HStack(spacing: 10) {
            PickupCarrierMark(company: item.company, accent: ParcelWidgetTheme.blue)
                .scaleEffect(1.08)
                .frame(width: 35, height: 35)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? (transit ? "运输中" : "待取件") : item.code)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(!item.title.isEmpty ? item.title :
                     (!item.station.isEmpty ? item.station : item.company))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.station.isEmpty && item.station != item.title {
                    Text(item.station)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if transit {
                Label("在途", systemImage: "truck.box.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(ParcelWidgetTheme.blue)
            } else {
                Button(intent: MarkParcelPickedIntent(parcelID: item.id)) {
                    Image(systemName: "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("标记 \(item.code) 为已取")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }

    private var emptyContent: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: isSmall ? 17 : 22))
                .foregroundStyle(ParcelWidgetTheme.blue)
            Text(entry.model.pendingTotal == 0 && entry.model.transitTotal == 0
                 ? "暂时没有包裹" : "暂无可显示的包裹")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
            Text(entry.model.lastSync == .distantPast
                 ? "打开 App 更新" :
                    entry.model.lastSync.formatted(date: .omitted,
                                                   time: .shortened) + " 同步")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 1)
            if hidden > 0 {
                Text("+\(hidden) 件")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: isSmall ? 8 : 9))
        .foregroundStyle(.secondary)
    }

    private func issue(_ title: String, explanation: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                Text("包裹助手")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(LinearGradient(colors: [ParcelWidgetTheme.blue,
                                                ParcelWidgetTheme.deepBlue],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(ParcelWidgetTheme.orange)
            Text(title)
                .font(.system(size: isSmall ? 12 : 14, weight: .semibold))
                .lineLimit(2)
            Text(explanation)
                .font(.system(size: isSmall ? 9 : 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isSmall ? 3 : 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct ParcelHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetSharedStore.kind,
                            provider: ParcelHomeProvider()) { entry in
            ParcelHomeContent(entry: entry)
        }
        .configurationDisplayName("包裹助手")
        .description("原生蓝色卡片展示待取和在途包裹，支持快速标记已取")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
