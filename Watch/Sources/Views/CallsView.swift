import SwiftUI

/// The last calls, newest first.
struct CallsView: View {
    let store: WatchStore
    /// nil when the phone could not read the call log, which is not an empty one.
    let calls: [WatchSnapshot.Call]?
    /// The snapshot's workspace: a row opens the call's card in it. nil opens the snapshot's
    /// own fields only.
    var workspaceId: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                if let calls {
                    if calls.isEmpty {
                        Text(WatchCopy.noCalls)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(calls) { call in
                        if let workspaceId {
                            NavigationLink(value: WatchDestination.callCard(
                                workspaceId: workspaceId,
                                callId: call.id
                            )) {
                                row(call, at: context.date)
                            }
                        } else {
                            NavigationLink {
                                CallDetailView(store: store, call: call)
                            } label: {
                                row(call, at: context.date)
                            }
                        }
                    }
                } else {
                    Text(WatchCopy.couldNotLoad)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(WatchCopy.calls)
    }

    private func row(_ call: WatchSnapshot.Call, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(call.caller)
                .lineLimit(1)
            Text("\(call.outcome) · \(store.relativeTime(of: call, at: date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// One call: who, when, and how it went, from the snapshot alone.
struct CallDetailView: View {
    let store: WatchStore
    let call: WatchSnapshot.Call

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(call.caller)
                    .font(.headline)
                Text(call.direction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                field(WatchCopy.when, call.time)
                field(WatchCopy.outcome, call.outcome)
                if let duration = call.duration {
                    field(WatchCopy.duration, duration)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️ A BARE ScrollView HAS NO SIDE MARGIN ON THE WATCH: the fields started at the
            // screen's edge, under the rounded corners, where the title and every list inset.
            .scenePadding(.horizontal)
        }
        .navigationTitle(WatchCopy.calls)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}
