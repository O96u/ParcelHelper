import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

// The compact island intentionally matches the reference:
// white package on the left, one white number on the right.
private enum PickupPalette {
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
        .background(foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PickupExpandedView: View {
    let state: PickupActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(state.items.prefix(2).enumerated()), id: \.offset) { _, item in
                PickupParcelRow(item: item, foreground: .white,
                                accent: PickupPalette.accent(state.style))
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
        .widgetURL(URL(string: "parcelhelper://parcel"))
    }
}

private struct PickupLockScreenView: View {
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
                PickupParcelRow(item: item, foreground: foreground, accent: accent)
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
        .widgetURL(URL(string: "parcelhelper://parcel"))
    }
}

struct PickupActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PickupActivityAttributes.self) { context in
            PickupLockScreenView(state: context.state)
                .activityBackgroundTint(PickupPalette.lockBackground(context.state.style))
                .activitySystemActionForegroundColor(PickupPalette.lockForeground(context.state.style))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(PickupPalette.accent(context.state.style))
                            .frame(width: 27, height: 27)
                            .background(PickupPalette.accent(context.state.style).opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 9))
                        Text("待取包裹")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.pending) 件")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom, priority: 1) {
                    PickupExpandedView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("待取包裹")
            } compactTrailing: {
                Text(context.state.pending > 99 ? "99+" : "\(context.state.pending)")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(context.state.pending) 件待取")
            } minimal: {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(context.state.pending) 件待取")
            }
            .keylineTint(PickupPalette.accent(context.state.style))
        }
    }
}

@main struct ParcelWidgetBundle: WidgetBundle {
    var body: some Widget {
        PickupActivityWidget()
        ParcelHomeWidget()
    }
}
