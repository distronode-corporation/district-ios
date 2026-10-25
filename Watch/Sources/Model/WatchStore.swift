import Foundation
import Observation

/// What the watch is showing.
enum WatchPhase: Equatable {
    /// Nothing heard from the phone yet, and nothing kept from before.
    case waiting
    /// ⛔ THE PHONE SPEAKS ANOTHER VERSION. Nothing it sent is shown.
    case versionMismatch
    case signedOut
    /// Signed in; the snapshot may still have no workspace.
    case ready(WatchSnapshot)
}

/// Where one write stands, for the screen that started it.
enum WatchWriteState: Equatable {
    case sending
    case succeeded(String)
    /// ⛔ THE TITLE SAYS WHAT DID NOT HAPPEN, THE REASON IS THE PHONE'S OWN SENTENCE. A failed
    /// reply must never read as sent.
    case failed(title: String, reason: String)
    /// ⛔ "iPhone not reachable", said before anything is sent.
    case unreachable
}

/// A screen on the signed-in stack, above Home.
///
/// ⚠️ A THREAD CARRIES ITS CONVERSATION, NOT ONLY ITS KEY, so an open thread keeps
/// drawing when a newer snapshot no longer lists it, as it did before the stack had a path.
enum WatchDestination: Hashable {
    case calls
    case inbox
    case thread(WatchSnapshot.Conversation)
}

/// The watch app's one model: the phone's latest snapshot and the writes in flight.
///
/// ⛔ IT MAKES NO REQUEST OF ITS OWN. Everything it shows came from the phone, and every
/// write is a message to the phone answered `{ok}` or `{error}`.
@MainActor
@Observable
final class WatchStore {
    private(set) var phase: WatchPhase = .waiting

    /// Keyed by ``WriteKey``, so the availability switch and a thread's reply each show
    /// their own state.
    private(set) var writes: [String: WatchWriteState] = [:]

    /// The signed-in stack above Home, which the views bind. A tapped notification sets it.
    var path: [WatchDestination] = []

    /// A tapped message notification still on its way to its thread. See ``open(_:)``.
    private var pendingRoute: PendingRoute?
    private var resolving: Task<Void, Never>?

    private let link: any PhoneLinking
    private let persistence: any SnapshotPersisting
    private let complication: any ComplicationPublishing
    private let backgroundRefresh: any BackgroundRefreshScheduling
    private let clock: @MainActor () -> Date

    init(
        link: any PhoneLinking,
        persistence: any SnapshotPersisting,
        complication: any ComplicationPublishing,
        backgroundRefresh: any BackgroundRefreshScheduling = NoBackgroundRefresh(),
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.link = link
        self.persistence = persistence
        self.complication = complication
        self.backgroundRefresh = backgroundRefresh
        self.clock = clock
    }

    /// The snapshot on screen, when signed in.
    var snapshot: WatchSnapshot? {
        guard case let .ready(snapshot) = phase else { return nil }
        return snapshot
    }

    /// Show what was kept from last time, then listen, then ask for a fresh picture.
    func start() {
        if let data = persistence.load() {
            apply(WatchSnapshot.read(data: data), persist: false)
        }
        link.activate(
            onReading: { [weak self] reading in self?.apply(reading) },
            onReachable: { [weak self] in self?.continuePendingRoute() }
        )
        refresh()
    }

    /// Start the background refresh chain. ⛔ CALLED BY ``WatchAppDelegate`` ONCE LAUNCH HAS
    /// FINISHED, NEVER FROM ``start()``: scheduling before the delegate is installed (the
    /// app's `init` runs first) is a crash. See ``refreshInBackground()``.
    func scheduleBackgroundRefresh() {
        backgroundRefresh.scheduleNext()
    }

    /// A background refresh the system woke the app for (``BackgroundRefreshScheduling``).
    ///
    /// ⛔ THE NEXT ONE IS SCHEDULED FIRST, so a task the system cuts short still leaves the
    /// chain running. Then the EXISTING `.refresh` request, and only while the unread
    /// complication is on a face: message pushes do not wake the phone app, so without this
    /// the count would wait for the next time somebody opened either app, and nothing else
    /// on the wrist needs a phone woken four times an hour. ⚠️ NO PROTOCOL BUMP: a phone of
    /// any version answers `.refresh`. The snapshot it sends arrives as an application
    /// context; the caller waits for it (``LivePhoneLink/waitForPendingContent()``).
    func refreshInBackground() async {
        backgroundRefresh.scheduleNext()
        guard link.isReachable, await backgroundRefresh.unreadComplicationIsOnAFace() else { return }
        _ = await link.send(WatchRequest(action: .refresh))
    }

    /// Ask the phone for a fresh snapshot. Fire and forget: the snapshot arrives as an
    /// application context, and an unreachable phone leaves the stale banner to say so.
    func refresh() {
        guard link.isReachable else { return }
        Task { _ = await link.send(WatchRequest(action: .refresh)) }
    }

    /// An application context from the phone.
    func apply(_ reading: WatchSnapshotReading) {
        apply(reading, persist: true)
    }

    private func apply(_ reading: WatchSnapshotReading, persist: Bool) {
        switch reading {
        case .unreadable:
            // ⚠️ KEEP WHAT IS SHOWN: an unreadable context says nothing about the account.
            return
        case .versionMismatch:
            phase = .versionMismatch
            WatchL10n.phoneLanguage = nil
            complication.publish(.unknown)
            path = []
            pendingRoute = nil
        case let .snapshot(snapshot):
            WatchL10n.phoneLanguage = snapshot.language
            phase = snapshot.signedIn ? .ready(snapshot) : .signedOut
            if persist, let data = try? snapshot.encoded() {
                persistence.save(data)
            }
            complication.publish(ComplicationState(snapshot))
            if snapshot.signedIn {
                continuePendingRoute()
            } else {
                // ⛔ NOTHING OF THE LAST ACCOUNT SURVIVES A SIGN-OUT, a pending failure, an open
                // thread and a tapped notification included.
                writes = [:]
                path = []
                pendingRoute = nil
            }
        }
    }

    // MARK: - Stale

    /// "Updated 20 min ago" once the snapshot is older than ``WatchSnapshot/staleAfter``,
    /// otherwise nil.
    func staleBanner(at now: Date) -> String? {
        guard let snapshot, snapshot.isStale(at: now) else { return nil }
        return WatchCopy.updated(WatchL10n.relative(snapshot.generatedAt, to: now))
    }

    /// A call's time against the watch's own clock, which keeps moving after the snapshot.
    func relativeTime(of call: WatchSnapshot.Call, at now: Date) -> String {
        guard let occurredAt = call.occurredAt else { return call.relativeTime }
        return WatchL10n.relative(occurredAt, to: now)
    }

    // MARK: - A tapped notification

    /// How long a tapped notification may still open its thread, once the phone has named
    /// it or a snapshot carries it. ⚠️ After that the person has moved on, and being pushed
    /// into a thread they did not just ask for is worse than staying on the inbox.
    static let routeWindow: TimeInterval = 60

    /// A tapped notification's flattened payload (see ``WatchNotificationDelegate``).
    func open(_ payload: [String: String]) async {
        guard let route = WatchNotificationRoute.parse(payload) else { return }
        await open(route)
    }

    /// Open a tapped message notification on its thread.
    ///
    /// ⛔ THE INBOX FIRST, AT ONCE, AND THE THREAD ONLY WHEN IT IS REALLY THERE. The push names
    /// a message, the watch lists threads, and only the phone can say which thread a message
    /// is in (``WatchAction/resolveMessage(workspaceId:messageId:)``). Until it has, and
    /// until a snapshot lists that thread, the inbox is shown: never a blank screen, never a
    /// guess. A phone out of reach is asked again when its next snapshot arrives.
    ///
    /// ⛔ ANOTHER WORKSPACE OPENS HOME. The snapshot is one workspace's, and its inbox is not
    /// the one the message arrived in; Home names the workspace that is shown.
    ///
    /// ⚠️ NOTHING SIGNED IN, NOTHING MOVES: the root is saying why there is nothing to open.
    func open(_ route: WatchNotificationRoute) async {
        guard case let .message(workspaceId, messageId) = route, let snapshot else { return }
        guard snapshot.workspace?.id == workspaceId else {
            pendingRoute = nil
            path = []
            return
        }
        path = [.inbox]
        pendingRoute = PendingRoute(
            workspaceId: workspaceId,
            messageId: messageId,
            expires: clock().addingTimeInterval(Self.routeWindow)
        )
        await resolvePendingRoute()
    }

    /// Wait for a resolve a snapshot started. For tests.
    func settleRoute() async {
        await resolving?.value
    }

    private func continuePendingRoute() {
        guard let route = pendingRoute else { return }
        if route.threadKey == nil {
            resolving = Task { await resolvePendingRoute() }
        } else {
            landPendingRoute()
        }
    }

    /// Still the person's latest wish: in time, on the inbox it opened, in its workspace.
    private func isLive(_ route: PendingRoute) -> Bool {
        clock() < route.expires && path == [.inbox] && snapshot?.workspace?.id == route.workspaceId
    }

    private func resolvePendingRoute() async {
        guard let route = pendingRoute, route.threadKey == nil, !route.asking else { return }
        guard isLive(route) else {
            pendingRoute = nil
            return
        }
        // ⚠️ OUT OF REACH IS NOT AN ANSWER: kept, and asked again on the next snapshot.
        guard link.isReachable else { return }
        pendingRoute?.asking = true
        let answer = await link.send(WatchRequest(
            action: .resolveMessage(workspaceId: route.workspaceId, messageId: route.messageId)
        ))
        // ⚠️ A NEWER TAP, A SIGN-OUT OR ANOTHER VERSION MAY HAVE REPLACED IT MEANWHILE.
        guard pendingRoute?.isSameMessage(as: route) == true else { return }
        pendingRoute?.asking = false
        switch answer {
        case let .reply(reply) where reply.ok && reply.threadKey?.isEmpty == false:
            pendingRoute?.threadKey = reply.threadKey
            landPendingRoute()
        case .unreachable:
            return
        case .reply, .noAnswer:
            // ⚠️ AN OLDER PHONE ANSWERS "update both apps", a refusal its sentence: either way
            // there is no thread to open, and the inbox stays.
            pendingRoute = nil
        }
    }

    private func landPendingRoute() {
        guard let route = pendingRoute, let threadKey = route.threadKey else { return }
        guard isLive(route) else {
            pendingRoute = nil
            return
        }
        // ⚠️ NOT LISTED YET: the message may be newer than this snapshot. The phone sends a
        // fresh one after answering, and that one is checked too.
        guard let conversation = snapshot?.conversations?.first(where: {
            $0.id == threadKey && $0.workspaceId == route.workspaceId
        }) else { return }
        path.append(.thread(conversation))
        pendingRoute = nil
    }

    // MARK: - Writes

    func setAvailable(_ available: Bool) async {
        guard let availability = snapshot?.availability, availability.canToggle else { return }
        await perform(
            .setAvailability(workspaceId: availability.workspaceId, available: available),
            key: WriteKey.availability,
            succeeded: nil,
            failureTitle: WatchCopy.availabilityFailed
        )
    }

    func reply(_ text: String, to conversation: WatchSnapshot.Conversation) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, conversation.canReply else { return }
        await perform(
            .reply(workspaceId: conversation.workspaceId, threadKey: conversation.id, text: trimmed),
            key: WriteKey.reply(conversation.id),
            succeeded: WatchCopy.replySent,
            failureTitle: WatchCopy.replyNotSent
        )
    }

    func markRead(_ conversation: WatchSnapshot.Conversation) async {
        await perform(
            .markRead(workspaceId: conversation.workspaceId, threadKey: conversation.id),
            key: WriteKey.markRead(conversation.id),
            succeeded: WatchCopy.markedRead,
            failureTitle: WatchCopy.markReadFailed
        )
    }

    func dismissWrite(_ key: String) {
        writes[key] = nil
    }

    #if DEBUG
        /// The debug preview screens only (``WatchPreviewSeam``). Compiled out of Release.
        func preview(_ reading: WatchSnapshotReading, writes: [String: WatchWriteState] = [:]) {
            apply(reading, persist: false)
            self.writes = writes
        }
    #endif

    /// ⛔ ONE REQUEST PER TAP. A second tap while the first is on its way is dropped: a
    /// reply sent twice is two messages to a customer.
    private func perform(_ action: WatchAction, key: String, succeeded: String?, failureTitle: String) async {
        guard writes[key] != .sending else { return }
        guard link.isReachable else {
            writes[key] = .unreachable
            return
        }
        writes[key] = .sending
        switch await link.send(WatchRequest(action: action)) {
        case let .reply(reply) where reply.ok:
            writes[key] = succeeded.map(WatchWriteState.succeeded)
        case let .reply(reply):
            writes[key] = .failed(title: failureTitle, reason: reply.error ?? WatchCopy.iphoneDidNotAnswer)
        case .unreachable:
            writes[key] = .unreachable
        case .noAnswer:
            writes[key] = .failed(title: failureTitle, reason: WatchCopy.iphoneDidNotAnswer)
        }
    }
}

/// A tapped message notification on its way to its thread.
private struct PendingRoute {
    let workspaceId: String
    let messageId: String
    let expires: Date
    /// The phone's answer, once it has given one.
    var threadKey: String?
    /// A resolve is on its way to the phone, so a snapshot arriving meanwhile asks nothing.
    var asking = false

    func isSameMessage(as other: PendingRoute) -> Bool {
        workspaceId == other.workspaceId && messageId == other.messageId && expires == other.expires
    }
}

/// The keys of ``WatchStore/writes``.
enum WriteKey {
    static let availability = "availability"

    static func reply(_ threadKey: String) -> String {
        "reply:\(threadKey)"
    }

    static func markRead(_ threadKey: String) -> String {
        "mark-read:\(threadKey)"
    }
}

extension ComplicationState {
    init(_ snapshot: WatchSnapshot) {
        self.init(
            signedIn: snapshot.signedIn,
            workspaceName: snapshot.workspace?.name,
            available: snapshot.availability?.available,
            language: snapshot.language,
            unreadCount: snapshot.unreadCount
        )
    }
}
