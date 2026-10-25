import DistrictLive
import DistrictModel
import Foundation
import UIKit

/// Answers the watch's live requests: the calls in progress, a call's transcript, a whisper,
/// and the after-call card. See ``WatchAction``.
@MainActor
protocol WatchLiveHandling: AnyObject {
    func answer(_ action: WatchAction) async -> WatchReply
}

/// The iPhone's half of the live transcript on the wrist.
///
/// ⛔ THE WATCH MAKES NO REQUEST. It asks this relay, every ~5 s, for what is new; the relay
/// reads the telemetry socket through the call screen's own ``LiveTranscriptModel`` and
/// answers with display-ready lines (``WatchLiveUpdate``).
///
/// ⛔ TWO MODES BEHIND ONE SWITCH, AND SNAPSHOT IS THE DEFAULT. A message from the watch wakes
/// this app in the background for seconds, and the system kills a background socket
/// (``LiveTranscriptModel``'s own note), so:
/// - ``Mode/snapshot``: on each keepalive, open a socket, take the subscribe's snapshot (the
///   broadcaster answers every subscribe with the whole buffer), close it, and answer with the
///   final lines the watch has not had. Nothing outlives the request.
/// - ``Mode/socket``: hold the socket, under a background task, while keepalives arrive, and
///   answer from what it has received. Cheaper and fresher, if the system lets it live; the W0
///   device spike measures whether it does (``WatchRelayDiagnostics/forceSocket``).
///
/// ⛔ IT ENDS ON ITS OWN: when the call ends, when the watch unsubscribes, and after
/// ``keepaliveTimeoutMilliseconds`` with no keepalive (a watch that walked out of range or
/// slept sends no unsubscribe).
///
/// ⚠️ ONE CALL AT A TIME: one wrist watches one call, and a subscribe to another ends the first.
@MainActor
final class WatchLiveRelay: WatchLiveHandling {
    enum Mode: String, Sendable {
        case snapshot
        case socket
    }

    /// No keepalive for this long, and the relay stops.
    static let keepaliveTimeoutMilliseconds: Int64 = 20000
    /// How long a request waits for a subscribe's snapshot before answering with what it has.
    /// ⚠️ Well inside the watch's patience and the few seconds a background wake is given.
    static let snapshotWaitMilliseconds: Int64 = 3500
    static let pollMilliseconds: Int64 = 100

    private let sources: any WatchLiveSourcing
    private let clock: any LiveClock
    private let backgroundTasks: any BackgroundTaskScheduling
    private let diagnostics: WatchRelayDiagnostics
    private let mode: @MainActor () -> Mode
    private let appState: @MainActor () -> String
    private let makeCursor: () -> String

    /// The call being relayed, if any. For tests and for the diagnostics.
    private(set) var session: Session?

    @MainActor
    final class Session {
        let workspaceId: String
        let callId: String
        let cursor: String
        let mode: Mode
        let feed: any WatchLiveTranscriptFeed
        let startedAt: Int64
        var lastKeepaliveAt: Int64
        /// Final segment ids the watch has been sent (or that were trimmed for it).
        var delivered: Set<String> = []
        /// ``Mode/socket``: the feed is activated and held.
        var holding = false
        /// ``Mode/socket``: when the socket was last seen open.
        var openSince: Int64?
        var watchdog: Task<Void, Never>?
        var lease: BackgroundTaskLease?

        init(
            workspaceId: String,
            callId: String,
            cursor: String,
            mode: Mode,
            feed: any WatchLiveTranscriptFeed,
            now: Int64
        ) {
            self.workspaceId = workspaceId
            self.callId = callId
            self.cursor = cursor
            self.mode = mode
            self.feed = feed
            startedAt = now
            lastKeepaliveAt = now
        }
    }

    init(
        sources: any WatchLiveSourcing,
        clock: any LiveClock = SystemLiveClock(),
        backgroundTasks: any BackgroundTaskScheduling = UIKitBackgroundTasks(),
        diagnostics: WatchRelayDiagnostics = .shared,
        mode: (@MainActor () -> Mode)? = nil,
        appState: @escaping @MainActor () -> String = { UIApplication.shared.applicationState.diagnosticName },
        makeCursor: @escaping () -> String = { UUID().uuidString }
    ) {
        self.sources = sources
        self.clock = clock
        self.backgroundTasks = backgroundTasks
        self.diagnostics = diagnostics
        self.mode = mode ?? { diagnostics.forceSocket ? .socket : .snapshot }
        self.appState = appState
        self.makeCursor = makeCursor
    }

    // MARK: - Answering

    func answer(_ action: WatchAction) async -> WatchReply {
        let received = clock.nowMilliseconds()
        diagnostics.record(
            .request,
            "\(action.diagnosticName) state=\(appState()) age=\(diagnostics.processAge(at: Date()))"
        )
        let reply = await respond(to: action)
        let took = clock.nowMilliseconds() &- received
        diagnostics.record(.reply, "\(action.diagnosticName) ok=\(reply.ok) took=\(took)ms")
        return reply
    }

    private func respond(to action: WatchAction) async -> WatchReply {
        switch action {
        case let .liveList(workspaceId):
            return await Self.reply(sources.liveCalls(workspaceId: workspaceId, now: Date()), WatchReply.liveCalls)
        case let .liveSubscribe(workspaceId, callId):
            return await update(workspaceId: workspaceId, callId: callId, cursor: nil)
        case let .liveKeepalive(workspaceId, callId, cursor, roundTrip):
            if let roundTrip {
                diagnostics.record(.watchRoundTrip, "\(roundTrip)ms")
            }
            return await update(workspaceId: workspaceId, callId: callId, cursor: cursor)
        case let .liveUnsubscribe(_, callId):
            if session?.callId == callId {
                end("unsubscribed")
            }
            return .success
        case let .whisper(workspaceId, callId, text):
            return await whisper(workspaceId: workspaceId, callId: callId, text: text)
        case let .callDetail(workspaceId, callId):
            return await Self.reply(
                sources.card(workspaceId: workspaceId, callId: callId, now: Date()),
                WatchReply.card
            )
        case .reply, .markRead, .setAvailability, .refresh, .resolveMessage:
            // ⚠️ NOT A LIVE REQUEST: `WatchBridgeService` never routes these here.
            return .failure(WatchBridgeCopy.updateBothApps)
        }
    }

    private static func reply<Value>(
        _ result: Result<Value, WatchActionFailure>,
        _ success: (Value) -> WatchReply
    ) -> WatchReply {
        switch result {
        case let .success(value): success(value)
        case let .failure(failure): .failure(failure.sentence)
        }
    }

    // MARK: - Steering

    private func whisper(workspaceId: String, callId: String, text: String) async -> WatchReply {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .failure(WatchBridgeCopy.whisperEmpty) }
        guard line.utf16.count <= WatchLiveComposer.whisperLimit else {
            return .failure(WatchBridgeCopy.whisperTooLong)
        }
        return await Self.reply(sources.whisper(workspaceId: workspaceId, callId: callId, text: line)) { _ in .success }
    }

    // MARK: - The transcript

    private func update(workspaceId: String, callId: String, cursor: String?) async -> WatchReply {
        let now = clock.nowMilliseconds()
        if let current = session {
            if current.callId != callId {
                end("another call")
            } else if current.cursor != cursor {
                end(cursor == nil ? "resubscribed" : "cursor changed")
            } else if now &- current.lastKeepaliveAt > Self.keepaliveTimeoutMilliseconds {
                // ⚠️ THE WATCHDOG DOES NOT RUN WHILE THE APP IS SUSPENDED, so a keepalive that
                // wakes it after the timeout finds the session it should already have ended.
                end("no keepalive")
            }
        }
        let reset = session == nil
        let session = session ?? start(workspaceId: workspaceId, callId: callId, now: now)
        session.lastKeepaliveAt = now
        armWatchdog(session)
        await refresh(session)
        // ⚠️ THE SESSION MAY HAVE ENDED WHILE THE SNAPSHOT WAS AWAITED (an unsubscribe, the
        // background time running out); the answer is still what was read.
        let update = compose(session, reset: reset)
        if update.phase == .ended, self.session === session {
            end("call ended")
        }
        return .live(update)
    }

    private func start(workspaceId: String, callId: String, now: Int64) -> Session {
        let mode = mode()
        let session = Session(
            workspaceId: workspaceId,
            callId: callId,
            cursor: makeCursor(),
            mode: mode,
            feed: sources.feed(workspaceId: workspaceId, callId: callId),
            now: now
        )
        if mode == .socket {
            // ⛔ THE SOCKET IS HELD ONLY UNDER A BACKGROUND TASK, and dropped when it expires: a
            // socket the system has frozen is not one to answer from.
            session.lease = BackgroundTaskLease.begin("district.watch-live", on: backgroundTasks) { [weak self] in
                self?.expired(session)
            }
        }
        self.session = session
        diagnostics.record(.sessionStarted, "call=\(WatchRelayDiagnostics.tail(callId)) mode=\(mode.rawValue)")
        return session
    }

    /// The system took the background time back: log it, and close the held socket.
    private func expired(_ session: Session) {
        diagnostics.record(.backgroundExpired, "after=\(clock.nowMilliseconds() &- session.startedAt)ms")
        if self.session === session {
            end("background time expired")
        }
    }

    /// Bring the feed up to date for this request.
    private func refresh(_ session: Session) async {
        let feed = session.feed
        // ⚠️ `not_live` IS FINAL FOR ITS SUBSCRIBE; the watch keeping the call open is the
        // call-status signal that asks again (the reducer allows it once per 30 s).
        if case .unavailable(.notLive) = feed.phase {
            feed.callShownInProgress()
        }
        switch session.mode {
        case .snapshot:
            await sources.willActivate()
            let before = feed.snapshotsReceived
            feed.activate()
            await settle(feed, since: before)
            feed.deactivate()
        case .socket:
            if !session.holding {
                await sources.willActivate()
                session.holding = true
                let before = feed.snapshotsReceived
                feed.activate()
                await settle(feed, since: before)
            } else if feed.connection != .open {
                // A held socket the system dropped, reconnecting: its subscribe brings a snapshot.
                await settle(feed, since: feed.snapshotsReceived)
            }
            trackSocket(session)
        }
    }

    /// Wait, on the clock, for a snapshot after `before`, or for the feed to settle otherwise.
    private func settle(_ feed: any WatchLiveTranscriptFeed, since before: Int) async {
        let deadline = clock.nowMilliseconds() &+ Self.snapshotWaitMilliseconds
        while feed.snapshotsReceived == before, !feed.fallsBack, clock.nowMilliseconds() < deadline {
            if case .ended = feed.phase {
                return
            }
            guard await (try? clock.sleep(milliseconds: Self.pollMilliseconds)) != nil else { return }
        }
    }

    /// ``Mode/socket``: how long the held socket lived, for the W0 log.
    private func trackSocket(_ session: Session) {
        let now = clock.nowMilliseconds()
        if session.feed.connection == .open {
            if session.openSince == nil {
                session.openSince = now
                diagnostics.record(.socketOpened, "call=\(WatchRelayDiagnostics.tail(session.callId))")
            }
        } else if let since = session.openSince {
            session.openSince = nil
            diagnostics.record(.socketDropped, "lived=\(now &- since)ms state=\(appState())")
        }
    }

    private func compose(_ session: Session, reset: Bool) -> WatchLiveUpdate {
        let lines = session.feed.lines
        let present = Set(lines.map(\.segmentId))
        let retracted = session.delivered.subtracting(present).sorted()
        session.delivered.subtract(retracted)
        let fresh = lines.filter { $0.final && !session.delivered.contains($0.segmentId) }
        let update = WatchLiveUpdate(
            callId: session.callId,
            cursor: session.cursor,
            reset: reset,
            lines: fresh.map(WatchLiveComposer.line),
            retracted: retracted,
            interim: lines.last { !$0.final }.map(WatchLiveComposer.line),
            phase: WatchLiveComposer.phase(of: session.feed),
            complete: session.feed.complete
        )
        // ⚠️ TRIMMED LINES COUNT AS SENT: they were the oldest, and offering them on the next
        // keepalive would put them below newer ones on the wrist.
        session.delivered.formUnion(fresh.map(\.segmentId))
        return update.fitted().update
    }

    // MARK: - Ending

    private func armWatchdog(_ session: Session) {
        session.watchdog?.cancel()
        let clock = clock
        session.watchdog = Task { [weak self, weak session] in
            guard await (try? clock.sleep(milliseconds: Self.keepaliveTimeoutMilliseconds)) != nil,
                  !Task.isCancelled, let self, let session, self.session === session
            else { return }
            end("no keepalive")
        }
    }

    /// Stop relaying: close any socket, end the background task, forget the session.
    func end(_ reason: String) {
        guard let session else { return }
        self.session = nil
        session.watchdog?.cancel()
        session.feed.deactivate()
        if session.mode == .socket {
            trackSocket(session)
        }
        session.lease?.end()
        let lived = clock.nowMilliseconds() &- session.startedAt
        diagnostics.record(.sessionEnded, "reason=\(reason) lived=\(lived)ms")
    }
}

private extension WatchAction {
    /// The request's kind, for the log: never its content.
    var diagnosticName: String {
        switch self {
        case .reply: "reply"
        case .markRead: "markRead"
        case .setAvailability: "setAvailability"
        case .refresh: "refresh"
        case .resolveMessage: "resolveMessage"
        case .liveList: "liveList"
        case let .liveSubscribe(_, callId): "liveSubscribe call=\(WatchRelayDiagnostics.tail(callId))"
        case let .liveKeepalive(_, callId, _, _): "liveKeepalive call=\(WatchRelayDiagnostics.tail(callId))"
        case let .liveUnsubscribe(_, callId): "liveUnsubscribe call=\(WatchRelayDiagnostics.tail(callId))"
        case .whisper: "whisper"
        case .callDetail: "callDetail"
        }
    }
}

extension UIApplication.State {
    /// `active`, `inactive` or `background`, for the W0 log.
    var diagnosticName: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
