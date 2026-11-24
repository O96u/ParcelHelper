import SwiftUI
import UIKit
import WidgetKit

enum PickupPalette {
    static func accent(_ style: String) -> Color {
        switch style {
        case "white": return Color(red: 0.18, green: 0.43, blue: 0.81)
        case "black": return Color(red: 1.00, green: 0.72, blue: 0.35)
        default: return Color(red: 0.46, green: 0.82, blue: 1.00)
        }
    }

    static func lockBackground(_ style: String) -> Color {
        switch style {
        case "white": return .white
        case "black": return Color(red: 0.055, green: 0.055, blue: 0.065)
        default: return Color(red: 0.055, green: 0.105, blue: 0.17)
        }
    }

    static func rowForeground(_ style: String) -> Color {
        style == "white" ? Color(red: 0.08, green: 0.12, blue: 0.18) : .white
    }

    static func rowBackground(_ style: String) -> LinearGradient {
        let colors: [Color]
        switch style {
        case "white": colors = [.white, Color(red: 0.89, green: 0.93, blue: 0.98)]
        case "black": colors = [Color(white: 0.13), Color(white: 0.06)]
        default: colors = [Color(red: 0.16, green: 0.30, blue: 0.44), Color(red: 0.08, green: 0.14, blue: 0.24)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func rowBorder(_ style: String) -> Color {
        switch style {
        case "white": return Color.black.opacity(0.08)
        case "black": return Color.white.opacity(0.18)
        default: return accent(style).opacity(0.35)
        }
    }

    static func lockForeground(_ style: String) -> Color {
        style == "white" ? Color(red: 0.08, green: 0.12, blue: 0.18) : .white
    }
}

// Official publisher App icon assets are packaged into the Widget extension.
// Unknown/unverified couriers intentionally use Apple's SF Symbol instead.
enum PickupCarrierArtwork {
    static func name(for company: String) -> String? {
        let v = company.lowercased()
        if v.contains("中通") || v.contains("zto") { return "carrier_zto" }
        if v.contains("邮政") || v.contains("ems") { return "carrier_ems" }
        if v.contains("圆通") || v.contains("yto") { return "carrier_yto" }
        if v.contains("极兔") || v.contains("j&t") { return "carrier_jtexpress" }
        if v.contains("申通") || v.contains("sto") { return "carrier_sto" }
        if v.contains("百世") || v.contains("best express") { return "carrier_best" }
        if v.contains("德邦") || v.contains("deppon") { return "carrier_debon" }
        if v.contains("京东") || v.contains("jd logistics") { return "brand_jd" }
        if v.contains("韵达") || v.contains("yunda") { return "carrier_yunda" }
        if v.contains("丰巢") { return "carrier_fengchao" }
        if v.contains("菜鸟") { return "carrier_cainiao" }
        if v.contains("顺丰") || v.contains("sf express") { return "carrier_sf" }
        if v.contains("dhl") { return "carrier_dhl" }
        if v.contains("fedex") { return "carrier_fedex" }
        if v.contains("ups") { return "carrier_ups" }
        if v.contains("闪送") { return "carrier_shansong" }
        return nil
    }
}

struct PickupCarrierMark: View {
    let company: String
    let accent: Color

    private var initials: String? {
        let value = company.lowercased()
        if value.contains("极兔") || value.contains("j&t") { return "J&T" }
        if value.contains("韵达") || value.contains("yunda") { return "韵达" }
        if value.contains("百世") || value.contains("best") { return "BEST" }
        if value.contains("闪送") { return "闪送" }
        return nil
    }

    var body: some View {
        Group {
            if let asset = PickupCarrierArtwork.name(for: company), UIImage(named: asset) != nil {
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 29, height: 29)
            } else if let initials {
                Text(initials)
                    .font(.system(size: initials.count > 2 ? 8 : 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(accent)
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 29, height: 29)
                    .background(accent.opacity(0.13))
            }
        }
        .frame(width: 29, height: 29)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PickupParcelRow: View {
    let item: PickupActivityItem
    let foreground: Color
    let accent: Color
    let style: String

    private var station: String {
        let name = item.station.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (item.company.isEmpty ? "待取包裹" : item.company) : name
    }
    private var code: String {
        let value = item.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "暂无取件码" : value
    }

    var body: some View {
        HStack(spacing: 9) {
            PickupCarrierMark(company: item.company, accent: accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(station)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !item.company.isEmpty && item.company != station {
                    Text(item.company)
                        .font(.system(size: 10))
                        .foregroundStyle(foreground.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.code.isEmpty ? "待出码" : "取件码")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.65))
                Text(code)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.60)
            }
            .frame(maxWidth: 123, alignment: .trailing)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(PickupPalette.rowBackground(style), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(PickupPalette.rowBorder(style), lineWidth: 1) }
    }
}

struct PickupExpandedView: View {
    let state: PickupActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(state.items.prefix(2).enumerated()), id: \.offset) { _, item in
                PickupParcelRow(item: item, foreground: PickupPalette.rowForeground(state.style),
                                accent: PickupPalette.accent(state.style), style: state.style)
            }
            if state.items.isEmpty {
                Text("暂无待取包裹")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            if state.pending > 2 {
                Text("另有 \(state.pending - 2) 件待取 · 打开包裹助手查看")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 1)
        // Compact/minimal island unchanged. The expanded bottom area is
        // bounded to two rows so system cropping doesn't hide pickup codes.
    }
}

struct PickupLockScreenView: View {
    let state: PickupActivityAttributes.ContentState
    private var foreground: Color { PickupPalette.lockForeground(state.style) }
    private var accent: Color { PickupPalette.accent(state.style) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 31, height: 31)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text("包裹助手")
                        .font(.system(size: 13, weight: .bold))
                    Text("待领取的包裹")
                        .font(.system(size: 10))
                        .foregroundStyle(foreground.opacity(0.58))
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(state.pending)")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("件")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(foreground.opacity(0.66))
                }
            }
            .frame(height: 34)
            ForEach(Array(state.items.prefix(2).enumerated()), id: \.offset) { _, item in
                PickupParcelRow(item: item, foreground: foreground, accent: accent, style: state.style)
            }
            if state.pending > 2 {
                Text("另有 \(state.pending - 2) 件待取")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if state.items.isEmpty {
                Text("暂无待取包裹")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.65))
                    .frame(height: 39)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
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

private struct ParcelWidgetRow<PickupAction: View>: View {
    let item: HomeWidgetParcel
    let transit: Bool
    let compact: Bool
    var dense = false
    @ViewBuilder var pickupAction: (HomeWidgetParcel, Bool) -> PickupAction

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
                    .font(.system(size: compact ? 11 : 13,
                                  weight: .bold, design: .rounded))
                    .foregroundStyle(transit ? ParcelWidgetTheme.blue : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.system(size: compact ? 9 : 10))
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
                pickupAction(item, compact)
            }
        }
        .frame(height: dense ? 25 : (compact ? 31 : 35))
    }
}

struct ParcelHomeContent<PickupAction: View>: View {
    let model: HomeWidgetSnapshot
    let sharedGroupReady: Bool
    let snapshotReady: Bool
    let family: WidgetFamily
    @ViewBuilder var pickupAction: (HomeWidgetParcel, Bool) -> PickupAction

    private var isSmall: Bool { family == .systemSmall }
    private var isMedium: Bool { family == .systemMedium }
    private var limit: Int { isSmall ? 2 : (isMedium ? 3 : 7) }

    private var rows: [(HomeWidgetParcel, Bool)] {
        let waiting = Array(model.pending.prefix(limit)).map { ($0, false) }
        guard model.showTransit else { return waiting }
        return waiting + Array(model.transit.prefix(
            max(0, limit - waiting.count))).map { ($0, true) }
    }

    private var hidden: Int {
        max(0, model.pendingTotal + (model.showTransit ? model.transitTotal : 0)
            - rows.count)
    }

    var body: some View {
        Group {
            if !sharedGroupReady {
                issue("未配置小组件共享",
                      explanation: "请检查 App 与 Widget 的 App Groups 签名",
                      icon: "lock.shield")
            } else if !snapshotReady {
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
        
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: isSmall ? 5 : 9) {
            ParcelWidgetHero(model: model, compact: isSmall, vertical: false)
            if rows.isEmpty {
                emptyContent
            } else {
                VStack(alignment: .leading, spacing: isSmall ? 0 : 1) {
                    ForEach(rows.indices, id: \.self) { index in
                        ParcelWidgetRow(item: rows[index].0, transit: rows[index].1,
                                        compact: isSmall, pickupAction: pickupAction)
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
                                        compact: true, dense: true, pickupAction: pickupAction)
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
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(model.pendingTotal)")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("件待取")
                    .font(.system(size: 11, weight: .semibold))
            }
            if model.showTransit {
                Text("在途 \(model.transitTotal)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.14), in: Capsule())
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(!item.title.isEmpty ? item.title :
                     (!item.station.isEmpty ? item.station : item.company))
                    .font(.system(size: 11))
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
                pickupAction(item, false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }

    private var emptyContent: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: isSmall ? 17 : 22))
                .foregroundStyle(ParcelWidgetTheme.blue)
            Text(model.pendingTotal == 0 && model.transitTotal == 0
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
            Text(model.lastSync == .distantPast
                 ? "打开 App 更新" :
                    model.lastSync.formatted(date: .omitted,
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

