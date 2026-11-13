import SwiftUI
import WidgetKit

/// The Home Screen widget: the selected workspace, its unread messages and its calls this
/// week, as the app last knew them.
///
/// ⛔ IT READS ONE KEYCHAIN ITEM AND NOTHING ELSE. No network, no session, no DistrictCore:
/// the app writes ``WidgetSnapshot`` after reads it already does and asks WidgetKit to
/// redraw (``WidgetSnapshotPublisher`` in the app). This extension is entitled to the
/// `.widget` Keychain group alone, so it cannot read the session or the notify token.
///
/// ⚠️ PROVED ONLY ON A SIGNED DEVICE. An unsigned build resolves no team prefix, so the
/// group is nil, nothing is read, and the widget shows its signed-out face.
struct DistrictSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotKind.summary, provider: SummaryProvider()) { entry in
            SummaryView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(WidgetCopy.summaryDisplayName)
        .description(WidgetCopy.summaryDescription)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// ⚠️ `.never`: the app asks for a redraw whenever it writes a new snapshot, so the widget
/// schedules only one thing on its own, the moment the seven-day call count goes stale
/// (``WidgetSnapshot/timeline(from:)``).
struct SummaryProvider: TimelineProvider {
    var store: any WidgetSnapshotStoring = WidgetSnapshotKeychain()

    func placeholder(in _: Context) -> SummaryEntry {
        SummaryEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                workspaceId: nil,
                workspaceName: "District AI",
                unreadMessages: 0,
                callsThisWeek: 0,
                callsReadAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in _: Context, completion: @escaping (SummaryEntry) -> Void) {
        let now = Date()
        completion(SummaryEntry(date: now, snapshot: store.read()?.shown(at: now)))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let now = Date()
        let entries = store.read()?.timeline(from: now).map { SummaryEntry(date: $0.date, snapshot: $0.snapshot) }
        completion(Timeline(entries: entries ?? [SummaryEntry(date: now, snapshot: nil)], policy: .never))
    }
}

struct SummaryView: View {
    let snapshot: WidgetSnapshot?

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot, let name = snapshot.workspaceName {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if family == .systemMedium {
                    HStack(alignment: .bottom, spacing: 16) {
                        figure(snapshot.unreadMessages, WidgetCopy.summaryUnread)
                        figure(snapshot.callsThisWeek, WidgetCopy.summaryCallsWeek)
                    }
                } else {
                    figure(snapshot.unreadMessages, WidgetCopy.summaryUnread)
                    figure(snapshot.callsThisWeek, WidgetCopy.summaryCallsWeek)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(WidgetCopy.summarySignedOut)
                .font(.subheadline)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A count and its label. ⚠️ A count the app has not read yet is a hyphen, never zero.
    private func figure(_ value: Int?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { $0.formatted(.number.locale(WidgetL10n.locale)) } ?? "-")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}
