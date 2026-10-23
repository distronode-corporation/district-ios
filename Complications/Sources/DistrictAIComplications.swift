import SwiftUI
import WidgetKit

/// One moment of the complication.
struct AvailabilityEntry: TimelineEntry {
    let date: Date
    let state: ComplicationState
}

/// Reads the state the watch app wrote into the App Group.
///
/// ⛔ ONE ENTRY AND `.never`: THE STATE CHANGES WHEN THE PHONE SAYS SO, NOT ON A CLOCK. The
/// watch app calls `WidgetCenter.reloadAllTimelines()` after every snapshot that moved it,
/// and a timeline that refreshed itself on a schedule would only spend the reload budget
/// re-reading the same value.
struct AvailabilityProvider: TimelineProvider {
    func placeholder(in _: Context) -> AvailabilityEntry {
        AvailabilityEntry(
            date: .now,
            state: ComplicationState(signedIn: true, workspaceName: "District", available: true, language: nil)
        )
    }

    func getSnapshot(in _: Context, completion: @escaping (AvailabilityEntry) -> Void) {
        completion(Self.current())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<AvailabilityEntry>) -> Void) {
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    private static func current() -> AvailabilityEntry {
        let state = ComplicationState.load(from: ComplicationState.defaults)
        // ⚠️ THE PHONE'S LANGUAGE, AS THE WATCH APP LAST HEARD IT. The widget has no
        // session of its own.
        WatchL10n.phoneLanguage = state.language
        return AvailabilityEntry(date: .now, state: state)
    }
}

struct AvailabilityEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AvailabilityEntry

    var body: some View {
        ComplicationView(state: entry.state, family: family)
            .containerBackground(for: .widget) { Color.clear }
    }
}

@main
struct DistrictAIComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationState.widgetKind, provider: AvailabilityProvider()) { entry in
            AvailabilityEntryView(entry: entry)
        }
        .configurationDisplayName(WatchCopy.availability)
        .description(WatchCopy.availabilityDescription)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
