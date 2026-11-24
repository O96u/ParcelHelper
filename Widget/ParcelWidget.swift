import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

// The compact island intentionally matches the reference:
// white package on the left, one white number on the right.
struct PickupActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PickupActivityAttributes.self) { context in
            PickupLockScreenView(state: context.state)
                .widgetURL(URL(string: "parcelhelper://parcel"))
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
                        .widgetURL(URL(string: "parcelhelper://parcel"))
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
