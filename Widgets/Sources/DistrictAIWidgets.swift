import ActivityKit
import SwiftUI
import WidgetKit

/// The iPhone widget extension. Today it holds one thing, the call's Live Activity.
///
/// ⛔ ITS DEPLOYMENT TARGET IS iOS 18, ABOVE THE APP'S 17, AND THAT IS THE AVAILABILITY GUARD.
/// The Apple Watch Smart Stack needs `.supplementalActivityFamilies([.small])` (iOS 18), and
/// neither `Widget.body` nor `WidgetBundleBuilder` can choose between two configurations by
/// OS version (the builder takes `if #available` with no `else`, measured on the iOS 26.2
/// SDK), while two configurations for one attributes type would leave the choice to the
/// system. So iOS 17 loads no extension, and the app starts no activity there
/// (``ActivityKitCallActivityHost/enabled``).
@main
struct DistrictAIWidgets: WidgetBundle {
    var body: some Widget {
        DistrictCallLiveActivity()
    }
}

/// The Lock Screen, the Dynamic Island, and the small family the Apple Watch Smart Stack draws
/// (watchOS 11). ⚠️ Without the small family the watch shows the compact leading and trailing
/// views.
struct DistrictCallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        CallActivityConfiguration.make()
            .supplementalActivityFamilies([.small])
    }
}

/// ⚠️ MAIN-ACTOR, like `Widget.body`: the view modifiers are, and Swift 6 refuses them from a
/// nonisolated builder.
@MainActor
enum CallActivityConfiguration {
    static func make() -> ActivityConfiguration<DistrictCallActivityAttributes> {
        ActivityConfiguration(for: DistrictCallActivityAttributes.self) { @MainActor context in
            CallActivityLockScreen(context: context)
        } dynamicIsland: { @MainActor context in
            let call = CallActivityContent(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CallActivityGlyph(phase: call.phase)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallActivityClock(call: call)
                        .font(.callout.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(call.caller)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallActivityDetail(call: call, lineLimit: 2)
                }
            } compactLeading: {
                CallActivityGlyph(phase: call.phase)
            } compactTrailing: {
                CallActivityClock(call: call, compact: true)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                CallActivityGlyph(phase: call.phase)
            }
            .keylineTint(.accentColor)
        }
    }
}
