import Foundation
import Observation

/// A watched call's transcript, as the wrist holds it.
struct WatchLiveTranscript: Equatable {
    let call: WatchLiveCall
    /// Final lines, in order.
    var lines: [WatchLiveLine] = []
    /// The newest interim line, drawn as provisional below the rest.
    var interim: WatchLiveLine?
    var phase: WatchLivePhase = .connecting
    var complete = true
    /// The phone's relay session, sent back with each keepalive.
    var cursor: String?
    /// ⛔ WHY THE LAST ASK FAILED, IN WORDS, until the next one succeeds: an unreachable phone
    /// is said, never shown as a transcript that simply stopped.
    var failure: String?
}

/// The after-call card, as the wrist holds it.
enum WatchCardState: Equatable {
    case loading
    /// `asking`: the summary is still on its way and the phone will be asked again.
    case card(WatchCallCard, asking: Bool)
    case failed(String)
}

/// The watch's live surfaces: the calls in progress, one call's transcript, the after-call card.
///
/// ⛔ MEMORY ONLY. Nothing here is written to the App Group, the snapshot or the application
/// context: a transcript is what a caller said, and it lives as long as the screen that asked
/// for it. ``reset()`` drops it all on sign-out.
///
/// ⛔ NO REQUEST OF ITS OWN, like ``WatchStore``: each value is the phone's answer to a
/// ``WatchAction``. A phone that predates them answers "update both apps", and Live is hidden
/// (``liveSupported``), while the card falls back to what the snapshot says about the call.
@MainActor
@Observable
final class WatchLiveStore {
    /// How often a watched transcript asks for more. ⚠️ The phone stops relaying after 20 s
    /// without one (`WatchLiveRelay`), so this must stay well inside that.
    static let keepaliveInterval: Duration = .seconds(5)
    /// How often Home asks for the calls in progress while it is shown.
    static let listInterval: Duration = .seconds(15)
    /// The waits before asking again for a summary still on its way: asked at once, then at
    /// 10, 30 and 60 s.
    static let cardRetryDelays: [Duration] = [.seconds(10), .seconds(20), .seconds(30)]
    /// The most lines held for one call. The oldest go first; the phone keeps the rest.
    static let lineLimit = 200

    /// The workspace's calls in progress. Empty until the phone says.
    private(set) var calls: [WatchLiveCall] = []
    /// ⛔ FALSE UNTIL THE PHONE ANSWERED THE LIST: an older phone never does, and Home then
    /// draws no Live row at all.
    private(set) var liveSupported = false
    /// The call whose transcript is open, if any.
    private(set) var transcript: WatchLiveTranscript?
    /// Each card asked for, by call id.
    private(set) var cards: [String: WatchCardState] = [:]

    /// Told when a watched call ends, so the screen can become its card.
    @ObservationIgnored var onCallEnded: (@MainActor (WatchLiveCall) -> Void)?

    private let link: any PhoneLinking
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var keepalives: Task<Void, Never>?
    @ObservationIgnored private var lastRoundTrip: Int?

    init(
        link: any PhoneLinking,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.link = link
        self.now = now
        self.sleep = sleep
    }

    // MARK: - The calls in progress

    /// Ask the phone for the calls in progress, now and every ``listInterval`` until cancelled
    /// (Home's `.task`).
    func pollCalls(workspaceId: String) async {
        while !Task.isCancelled {
            await loadCalls(workspaceId: workspaceId)
            guard await (try? sleep(Self.listInterval)) != nil else { return }
        }
    }

    func loadCalls(workspaceId: String) async {
        guard link.isReachable else { return }
        switch await link.send(WatchRequest(action: .liveList(workspaceId: workspaceId))) {
        case let .reply(reply):
            // ⚠️ NO LIST IS NO LIVE: "update both apps" from an older phone, or a read that
            // failed. Either way there is nothing to open.
            liveSupported = reply.liveCalls != nil
            calls = (reply.liveCalls ?? []).filter { $0.workspaceId == workspaceId }
        case .unreachable, .noAnswer:
            // ⚠️ KEPT: out of reach says nothing about the calls, and the transcript screen says
            // so itself if one is opened.
            return
        }
    }

    // MARK: - One call's transcript

    /// Open a call's transcript: subscribe, then keep it alive until ``close()`` or the end.
    func open(_ call: WatchLiveCall) {
        guard transcript?.call.id != call.id else { return }
        close()
        transcript = WatchLiveTranscript(call: call)
        lastRoundTrip = nil
        keepalives = Task { [weak self] in
            await self?.ask(cursor: nil, subscribe: true)
            while let self, transcript?.call.id == call.id, transcript?.phase != .ended {
                guard await (try? sleep(Self.keepaliveInterval)) != nil, !Task.isCancelled else { return }
                await keepalive()
            }
        }
    }

    /// One keepalive, answered with what is new.
    func keepalive() async {
        guard let transcript else { return }
        await ask(cursor: transcript.cursor, subscribe: false)
    }

    /// The transcript screen closed: stop asking, tell the phone, and forget the lines.
    func close() {
        keepalives?.cancel()
        keepalives = nil
        guard let call = transcript?.call else { return }
        transcript = nil
        guard link.isReachable else { return }
        let link = link
        Task { _ = await link.send(WatchRequest(action: .liveUnsubscribe(
            workspaceId: call.workspaceId,
            callId: call.id
        ))) }
    }

    private func ask(cursor: String?, subscribe: Bool) async {
        guard let call = transcript?.call else { return }
        guard link.isReachable else {
            transcript?.failure = WatchCopy.iphoneNotReachable
            return
        }
        let action: WatchAction = subscribe
            ? .liveSubscribe(workspaceId: call.workspaceId, callId: call.id)
            : .liveKeepalive(
                workspaceId: call.workspaceId,
                callId: call.id,
                cursor: cursor,
                roundTripMilliseconds: lastRoundTrip
            )
        let sent = now()
        let answer = await link.send(WatchRequest(action: action))
        lastRoundTrip = Int(now().timeIntervalSince(sent) * 1000)
        // ⚠️ THE SCREEN MAY HAVE CLOSED, OR MOVED TO ANOTHER CALL, WHILE THIS WAS ON ITS WAY.
        guard transcript?.call.id == call.id else { return }
        switch answer {
        case let .reply(reply):
            if let update = reply.live {
                apply(update)
            } else {
                transcript?.failure = reply.error ?? WatchCopy.iphoneDidNotAnswer
            }
        case .unreachable:
            transcript?.failure = WatchCopy.iphoneNotReachable
        case .noAnswer:
            transcript?.failure = WatchCopy.iphoneDidNotAnswer
        }
    }

    /// Merge the phone's answer into what is held.
    func apply(_ update: WatchLiveUpdate) {
        guard var held = transcript, held.call.id == update.callId else { return }
        if update.reset || held.cursor != update.cursor {
            held.lines = []
        }
        let retracted = Set(update.retracted)
        held.lines.removeAll { retracted.contains($0.id) }
        let known = Set(held.lines.map(\.id))
        held.lines += update.lines.filter { !known.contains($0.id) }
        held.lines.sort { ($0.epoch, $0.index, $0.id) < ($1.epoch, $1.index, $1.id) }
        if held.lines.count > Self.lineLimit {
            held.lines.removeFirst(held.lines.count - Self.lineLimit)
        }
        held.interim = update.interim
        held.phase = update.phase
        held.complete = update.complete
        held.cursor = update.cursor
        held.failure = nil
        transcript = held
        if update.phase == .ended {
            keepalives?.cancel()
            keepalives = nil
            onCallEnded?(held.call)
        }
    }

    // MARK: - The after-call card

    /// Ask for a call's card, and again at 10, 30 and 60 s while its summary is on its way.
    func loadCard(workspaceId: String, callId: String) async {
        if cards[callId] == nil {
            cards[callId] = .loading
        }
        for attempt in 0 ... Self.cardRetryDelays.count {
            if attempt > 0 {
                guard await (try? sleep(Self.cardRetryDelays[attempt - 1])) != nil, !Task.isCancelled else { return }
            }
            guard link.isReachable else {
                fail(callId, WatchCopy.iphoneNotReachable)
                return
            }
            let answer = await link.send(WatchRequest(action: .callDetail(workspaceId: workspaceId, callId: callId)))
            switch answer {
            case let .reply(reply):
                guard let card = reply.card else {
                    fail(callId, reply.error ?? WatchCopy.iphoneDidNotAnswer)
                    return
                }
                let asking = card.summaryPending && attempt < Self.cardRetryDelays.count
                cards[callId] = .card(card, asking: asking)
                guard asking else { return }
            case .unreachable:
                fail(callId, WatchCopy.iphoneNotReachable)
                return
            case .noAnswer:
                fail(callId, WatchCopy.iphoneDidNotAnswer)
                return
            }
        }
    }

    /// ⚠️ A CARD ALREADY SHOWN STAYS, no longer asking: a re-ask that failed does not unsay what
    /// the phone already answered.
    private func fail(_ callId: String, _ reason: String) {
        if case let .card(card, _) = cards[callId] {
            cards[callId] = .card(card, asking: false)
        } else {
            cards[callId] = .failed(reason)
        }
    }

    // MARK: - Sign-out

    /// ⛔ NOTHING OF THE LAST ACCOUNT SURVIVES A SIGN-OUT OR A VERSION CHANGE.
    func reset() {
        keepalives?.cancel()
        keepalives = nil
        transcript = nil
        calls = []
        cards = [:]
        liveSupported = false
    }

    #if DEBUG
        /// The debug preview screens only (``WatchPreviewSeam``). Compiled out of Release.
        func preview(calls: [WatchLiveCall], transcript: WatchLiveTranscript?, cards: [String: WatchCardState]) {
            liveSupported = true
            self.calls = calls
            self.transcript = transcript
            self.cards = cards
        }
    #endif
}
