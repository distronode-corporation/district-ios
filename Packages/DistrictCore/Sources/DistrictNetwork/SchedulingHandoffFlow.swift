import DistrictModel
import Foundation

/// How one tap on "Open in browser" ended.
public enum SchedulingHandoffOutcome: Equatable, Sendable {
    /// Leg 2 answered; open ``SchedulingHandoff/url`` in the SAME browser component
    /// that opened leg 1.
    case minted(SchedulingHandoff)

    /// Leg 2 refused. ⛔ Never retried here: the next tap starts again from leg 1.
    case failed(SchedulingHandoffFailure)

    /// A hand-off was already running. ⛔ Nothing happened: one hand-off per tap.
    case alreadyPending

    /// The user closed the leg-1 browser before any callback. Nothing was minted.
    case abandoned
}

/// One scheduling hand-off at a time, across its three legs.
///
/// ⛔ THE BOUND FLOW, WITH A FALLBACK THAT KEEPS ANY RELEASE ORDER SAFE.
/// 1. Open `/dashboard/handoff/start?state=S` in the browser. The server sets the
///    nonce cookie in that browser and redirects to `districtai://handoff?state=S&nonce=N`.
/// 2. On a callback carrying THIS state, mint with `nonce: N`.
/// 3. The caller opens the minted URL in the same browser component, which redeems it
///    only if the cookie is there.
///
/// If no matching callback arrives within ``callbackTimeout``, or leg 1 visibly
/// fails, the hand-off falls back to the unbound mint (no `nonce` key at all), which
/// is what every installed build does today and what the server accepts until
/// `HANDOFF_REQUIRE_NONCE` is switched on. A server without leg 1 therefore costs a
/// wait, never a broken button.
///
/// ⛔ A CALLBACK IS SPENT ONLY AGAINST THE STATE THIS FLOW GENERATED FOR THE HAND-OFF
/// IN FLIGHT. Any app can register `districtai://`, so a callback with another state,
/// or one arriving with nothing pending, is dropped without touching anything.
///
/// ⛔ THE LOG SAYS WHICH PATH WAS TAKEN AND NOTHING ELSE. The nonce is half of a
/// sign-in and the state is what makes a callback ours, so neither is ever written
/// to `log`, which is the only output this type has.
///
/// ⚠️ AN ACTOR, AND RE-ENTRANT ON PURPOSE. ``run(workspaceId:next:open:)`` suspends
/// while the browser is up; the callback, the leg-1 failure and the browser closing
/// all arrive through the other methods during that suspension, and the actor makes
/// them one ordered stream with the timeout.
public actor SchedulingHandoffFlow {
    /// How long leg 1 has to call back before the unbound fallback.
    ///
    /// ⚠️ IT INCLUDES THE USER'S OWN TIME ON THE "Open in District AI?" PROMPT that
    /// `SFSafariViewController` may show for the redirect. Ten seconds is long enough
    /// for a person to answer it and short enough that a server without leg 1 does not
    /// look like a dead button.
    public static let callbackTimeout: Duration = .seconds(10)

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Opens a URL in the browser sheet. The `String` is the leg-1 state, which the
    /// caller hands back through ``legOneFailed(state:)`` and
    /// ``browserClosed(state:)`` so a late event from an old sheet cannot touch a
    /// newer hand-off.
    public typealias Open = @MainActor @Sendable (URL, String) async -> Void

    private enum Resolution: Equatable {
        case bound(nonce: String)
        case fallback
        case abandoned
    }

    /// ⚠️ `resolution` HOLDS AN ANSWER THAT ARRIVED BEFORE ANYTHING WAS WAITING FOR
    /// IT, which happens when the callback lands while `open` is still running.
    private struct Pending {
        let state: String
        var resolution: Resolution?
        var waiter: CheckedContinuation<Resolution, Never>?
    }

    private let client: SchedulingHandoffClient
    private let newState: @Sendable () -> String
    private let timeout: Duration
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void

    /// ⛔ COVERS THE MINT AS WELL AS THE WAIT. A second tap during leg 2 would start a
    /// second leg 1, whose cookie replaces the first one's and turns the first redeem
    /// into a 410.
    private var running = false
    private var pending: Pending?

    /// - Parameters:
    ///   - newState: a fresh leg-1 state per hand-off. The app passes `PKCE.newState`
    ///     (32 random bytes, base64url); a value the server would refuse falls back to
    ///     the unbound flow rather than opening a page that answers 400.
    ///   - sleep: the timeout's clock. ⚠️ Injectable only so a test can fire or hold it.
    ///   - log: one line per hand-off naming the path. Never given a nonce or a state.
    public init(
        client: SchedulingHandoffClient,
        newState: @escaping @Sendable () -> String,
        timeout: Duration = SchedulingHandoffFlow.callbackTimeout,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.client = client
        self.newState = newState
        self.timeout = timeout
        self.sleep = sleep
        self.log = log
    }

    /// Run one hand-off: leg 1 through `open`, then leg 2. The caller opens the
    /// minted URL (leg 3).
    public func run(workspaceId: String, next: String? = nil, open: Open) async -> SchedulingHandoffOutcome {
        guard !running else { return .alreadyPending }
        running = true
        defer { running = false }

        switch await legOne(open: open) {
        case let .bound(nonce):
            log("handoff path=bound")
            return await SchedulingHandoffOutcome(client.mint(workspaceId: workspaceId, next: next, nonce: nonce))
        case .fallback:
            log("handoff path=unbound-fallback")
            return await SchedulingHandoffOutcome(client.mint(workspaceId: workspaceId, next: next))
        case .abandoned:
            log("handoff path=abandoned")
            return .abandoned
        }
    }

    /// The scene received `districtai://handoff…`.
    ///
    /// ⛔ DROPPED unless it is well formed AND carries the state of the hand-off in
    /// flight. A dropped callback changes nothing: the hand-off it did not match keeps
    /// waiting, and the timeout still applies.
    public func receive(_ url: URL) {
        if let values = SchedulingHandoffCallback.values(in: url), resolve(values.state, .bound(nonce: values.nonce)) {
            return
        }
        log("handoff callback dropped")
    }

    /// Leg 1 rendered a page instead of redirecting, or did not load at all. Falls
    /// back now rather than at the timeout.
    public func legOneFailed(state: String) {
        resolve(state, .fallback)
    }

    /// The leg-1 browser went away before any callback: the user closed it. Nothing
    /// is minted. ⚠️ A no-op once the hand-off has moved on, which is what makes the
    /// sheet being REPLACED by leg 3 harmless.
    public func browserClosed(state: String) {
        resolve(state, .abandoned)
    }

    /// Whether a hand-off is parked waiting for its callback. ⚠️ Internal, for a test
    /// to deliver an event at the one moment that exercises the waiting path.
    var isWaitingForCallback: Bool {
        pending?.waiter != nil
    }

    // MARK: - Leg 1

    private func legOne(open: Open) async -> Resolution {
        let state = newState()
        guard SchedulingHandoffCallback.isValidState(state), let url = client.startURL(state: state) else {
            return .fallback
        }
        pending = Pending(state: state)
        // ⚠️ THE TASK INHERITS THIS ACTOR, so the resolve below is a plain call in
        // the same ordered stream as a callback; cancelling it when the hand-off is
        // answered first is what stops the sleep, not what makes a late fire safe.
        let timer = Task { [sleep, timeout] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            resolve(state, .fallback)
        }
        await open(url, state)
        let resolution = await answer()
        timer.cancel()
        return resolution
    }

    /// ⚠️ `pending` IS NEVER NIL HERE. Only ``resolve(_:_:)`` clears it, and only
    /// when a waiter is installed, which happens nowhere but below.
    private func answer() async -> Resolution {
        if let early = pending?.resolution {
            pending = nil
            return early
        }
        return await withCheckedContinuation { pending?.waiter = $0 }
    }

    /// The single place a pending hand-off is answered. The first answer wins; later
    /// ones, and any for another state, return false and change nothing.
    @discardableResult
    private func resolve(_ state: String, _ resolution: Resolution) -> Bool {
        guard var current = pending, current.state == state, current.resolution == nil else { return false }
        if let waiter = current.waiter {
            pending = nil
            waiter.resume(returning: resolution)
        } else {
            current.resolution = resolution
            pending = current
        }
        return true
    }
}

private extension SchedulingHandoffOutcome {
    init(_ result: Result<SchedulingHandoff, SchedulingHandoffFailure>) {
        switch result {
        case let .success(handoff): self = .minted(handoff)
        case let .failure(failure): self = .failed(failure)
        }
    }
}
