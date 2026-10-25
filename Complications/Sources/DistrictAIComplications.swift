import SwiftUI
import WidgetKit

/// One moment of a complication.
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let state: ComplicationState
}

/// Reads the state the watch app wrote into the App Group, for both complications.
///
/// ⛔ ONE ENTRY AND `.never`: THE STATE CHANGES WHEN THE PHONE SAYS SO, NOT ON A CLOCK. The
/// watch app calls `WidgetCenter.reloadTimelines(ofKind:)` for each complication a snapshot
/// moved, and a timeline that refreshed itself on a schedule would only spend the reload
/// budget re-reading the same value. The unread count's freshness comes from the watch app's
/// background refresh (`WatchStore.refreshInBackground()`), not from here.
struct ComplicationProvider: TimelineProvider {
    /// ⚠️ THE FACE EDITOR'S SAMPLE, SO IT IS MADE UP: never a real count or name.
    func placeholder(in _: Context) -> ComplicationEntry {
        ComplicationEntry(
            date: .now,
            state: ComplicationState(
                signedIn: true, workspaceName: "District", available: true, language: nil, unreadCount: 2
            )
        )
    }

    func getSnapshot(in _: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(Self.current())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    private static func current() -> ComplicationEntry {
        let state = ComplicationState.load(from: ComplicationState.defaults)
        // ⚠️ THE PHONE'S LANGUAGE, AS THE WATCH APP LAST HEARD IT. The widget has no
        // session of its own.
        WatchL10n.phoneLanguage = state.language
        return ComplicationEntry(date: .now, state: state)
    }
}

struct AvailabilityEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        ComplicationView(state: entry.state, family: family)
            .containerBackground(for: .widget) { Color.clear }
    }
}

struct UnreadEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        UnreadComplicationView(state: entry.state, family: family)
            .containerBackground(for: .widget) { Color.clear }
    }
}

/// The two complications.
///
/// ⚠️ A BUNDLE SINCE 3.2. The availability complication keeps its kind, so one already on a
/// face stays there; the unread one is new and is on no face until somebody adds it.
@main
struct DistrictAIComplications: WidgetBundle {
    var body: some Widget {
        AvailabilityComplication()
        UnreadComplication()
    }
}

struct AvailabilityComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationState.widgetKind, provider: ComplicationProvider()) { entry in
            AvailabilityEntryView(entry: entry)
        }
        .configurationDisplayName(WatchCopy.availability)
        .description(WatchCopy.availabilityDescription)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// ⛔ OPT-IN AND COUNT ONLY. See ``UnreadComplicationView`` and ``ComplicationState``.
struct UnreadComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationState.unreadWidgetKind, provider: ComplicationProvider()) { entry in
            UnreadEntryView(entry: entry)
        }
        .configurationDisplayName(WatchCopy.unreadComplication)
        .description(WatchCopy.unreadComplicationDescription)
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}
