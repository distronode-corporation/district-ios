import SwiftUI

/// The root: chooses between waiting, update, signed out and the signed-in home.
struct WatchRootView: View {
    let store: WatchStore

    var body: some View {
        switch store.phase {
        case .waiting:
            MessageScreen(symbol: "iphone", title: nil, message: WatchCopy.waitingForIphone)
        case .versionMismatch:
            MessageScreen(
                symbol: "arrow.down.app",
                title: WatchCopy.updateIphone,
                message: WatchCopy.updateIphoneBody
            )
        case .signedOut:
            MessageScreen(symbol: "person.crop.circle", title: WatchCopy.signInOnIphone, message: WatchCopy.signInBody)
        case let .ready(snapshot):
            // ⚠️ THE PATH IS THE STORE'S, so a tapped notification can open a thread.
            NavigationStack(path: Binding(get: { store.path }, set: { store.path = $0 })) {
                HomeView(store: store, snapshot: snapshot)
                    .watchDestinations(store: store, snapshot: snapshot)
            }
        }
    }
}

/// Workspace, availability, unread, and the way into Calls and Inbox.
struct HomeView: View {
    let store: WatchStore
    let snapshot: WatchSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                if let banner = store.staleBanner(at: context.date) {
                    StaleBanner(text: banner)
                }
                if let workspace = snapshot.workspace {
                    Section {
                        AvailabilityRow(
                            store: store,
                            workspaceName: workspace.name,
                            availability: snapshot.availability
                        )
                    } header: {
                        Text(workspace.name)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Section {
                        liveRows
                        unreadRow
                        NavigationLink(value: WatchDestination.calls) {
                            Label(WatchCopy.calls, systemImage: "phone")
                        }
                        .accessibilityIdentifier("watch.home.calls")
                        NavigationLink(value: WatchDestination.inbox) {
                            Label(WatchCopy.inbox, systemImage: "tray")
                        }
                        .accessibilityIdentifier("watch.home.inbox")
                    }
                } else {
                    Text(WatchCopy.noWorkspace)
                        .font(.footnote)
                }
            }
            .navigationTitle("District AI")
        }
        // ⚠️ ASKED WHILE HOME IS SHOWN, and not otherwise: the list is a read on the phone.
        .task(id: snapshot.workspace?.id) {
            guard let workspaceId = snapshot.workspace?.id else { return }
            await store.live.pollCalls(workspaceId: workspaceId)
        }
    }

    /// A row per call in progress. ⛔ NONE FROM A PHONE THAT DOES NOT KNOW THE REQUEST.
    @ViewBuilder
    private var liveRows: some View {
        if store.live.liveSupported {
            ForEach(store.live.calls) { call in
                NavigationLink(value: WatchDestination.live(call)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(WatchCopy.liveCall, systemImage: "waveform")
                            .foregroundStyle(Color.accentColor)
                        Text(call.caller)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("watch.home.live")
            }
        }
    }

    @ViewBuilder
    private var unreadRow: some View {
        if let unread = snapshot.unreadCount {
            LabeledContent(WatchCopy.unread) {
                Text(unread, format: .number)
                    .font(.headline)
                    .foregroundStyle(unread > 0 ? Color.accentColor : .secondary)
            }
        }
    }
}

extension View {
    /// The screens of ``WatchDestination``, drawn from the snapshot shown now.
    ///
    /// ⛔ ONE REGISTRATION PER STACK, at its root: a second one for the same type further up
    /// the stack is ambiguous to SwiftUI.
    func watchDestinations(store: WatchStore, snapshot: WatchSnapshot) -> some View {
        navigationDestination(for: WatchDestination.self) { destination in
            switch destination {
            case .calls:
                CallsView(store: store, calls: snapshot.calls, workspaceId: snapshot.workspace?.id)
            case .inbox:
                InboxView(store: store, conversations: snapshot.conversations)
            case let .thread(conversation):
                ThreadView(store: store, conversation: conversation)
            case let .live(call):
                LiveCallView(store: store, call: call)
            case let .callCard(workspaceId, callId):
                CallCardView(
                    store: store,
                    workspaceId: workspaceId,
                    callId: callId,
                    seed: snapshot.calls?.first { $0.id == callId }
                )
            }
        }
    }
}

/// The "Available for calls" switch, naming its workspace.
///
/// ⛔ THE SWITCH SHOWS THE PHONE'S VALUE, NEVER THE ONE ASKED FOR. A write goes to the
/// phone; the switch moves when the next snapshot says the server wrote it.
struct AvailabilityRow: View {
    let store: WatchStore
    let workspaceName: String
    let availability: WatchSnapshot.Availability?

    var body: some View {
        if let availability {
            if availability.canToggle {
                Toggle(isOn: Binding(
                    get: { availability.available },
                    set: { value in Task { await store.setAvailable(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WatchCopy.availableForCalls)
                        Text(WatchCopy.callsIn(workspaceName))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(store.writes[WriteKey.availability] == .sending)
                .accessibilityIdentifier("watch.home.availability")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(availability.available ? WatchCopy.available : WatchCopy.notAvailable)
                    if let note = availability.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            WriteStatusRow(store: store, key: WriteKey.availability)
        } else {
            Text(WatchCopy.availabilityUnreadable)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Updated 20 min ago".
struct StaleBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.footnote)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("watch.stale")
    }
}

/// A whole screen that says one thing.
struct MessageScreen: View {
    let symbol: String
    let title: String?
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                if let title {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The state of one write, under the control that started it.
struct WriteStatusRow: View {
    let store: WatchStore
    let key: String

    var body: some View {
        switch store.writes[key] {
        case .none:
            EmptyView()
        case .sending:
            HStack {
                ProgressView()
                    .frame(width: 20)
                Text(WatchCopy.sending)
                    .font(.footnote)
            }
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        case let .failed(title, reason):
            failure(title: title, reason: reason)
        case .unreachable:
            failure(title: WatchCopy.iphoneNotReachable, reason: WatchCopy.iphoneNotReachableBody)
        }
    }

    private func failure(title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
            Text(reason)
                .font(.caption2)
            Button(WatchCopy.tryAgain) { store.dismissWrite(key) }
                .font(.footnote)
        }
        .accessibilityIdentifier("watch.write.failure")
    }
}
