import Foundation
import WatchConnectivity

/// What became of one request to the phone.
enum PhoneAnswer: Equatable, Sendable {
    case reply(WatchReply)
    /// `isReachable` was false, or WatchConnectivity said so on send.
    case unreachable
    /// Sent, and nothing usable came back in time. ⚠️ The write may have happened.
    case noAnswer
}

/// WatchConnectivity on the watch, behind a seam so a test can stand in for the phone.
@MainActor
protocol PhoneLinking: AnyObject {
    /// ⛔ READ BEFORE EVERY WRITE: an unreachable phone is said so at once, not after a
    /// timeout.
    var isReachable: Bool { get }

    /// Start the session; `onReading` gets every application context, the one already
    /// received included, and `onReachable` every time the phone comes into reach.
    func activate(
        onReading: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable: @escaping @MainActor @Sendable () -> Void
    )

    /// ⛔ `sendMessage` WITH A REPLY HANDLER, NEVER `transferUserInfo`. See ``WatchAction``.
    func send(_ request: WatchRequest) async -> PhoneAnswer
}

/// `WCSession` on the watch.
@MainActor
final class LivePhoneLink: PhoneLinking {
    private let delegate = PhoneSessionDelegate()

    var isReachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func activate(
        onReading: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable: @escaping @MainActor @Sendable () -> Void
    ) {
        // ⛔ `@Sendable`, so not isolated to the main actor: the delegate calls them on
        // WatchConnectivity's queue. See ``deliver(_:)``.
        delegate.onReading = { @Sendable reading in Task { @MainActor in onReading(reading) } }
        delegate.onReachable = { @Sendable in Task { @MainActor in onReachable() } }
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        guard isReachable else { return .unreachable }
        return await Self.deliver(request)
    }

    /// Send one request and wait for whichever handler WatchConnectivity calls.
    ///
    /// ⛔ NONISOLATED, AND BOTH HANDLERS `@Sendable`, BECAUSE WATCHCONNECTIVITY CALLS THEM ON
    /// ITS OWN QUEUE. A closure written inside this `@MainActor` class is isolated to the main
    /// actor, and Swift 6 checks that isolation when an Objective-C API calls it: off the main
    /// thread the check traps (SIGILL in `dispatch_assert_queue`), so every answer to every
    /// write crashed the app. The fake link never runs this; ``LivePhoneLinkTests`` does.
    nonisolated static func deliver(_ request: WatchRequest) async -> PhoneAnswer {
        guard let message = try? request.message() else { return .unreachable }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            WCSession.default.sendMessage(
                message,
                replyHandler: { @Sendable reply in
                    once.resume(WatchReply.read(reply).map(PhoneAnswer.reply) ?? .noAnswer)
                },
                errorHandler: { @Sendable error in
                    let code = (error as? WCError)?.code
                    once.resume(code == .notReachable ? .unreachable : .noAnswer)
                }
            )
        }
    }

    /// Wait while WatchConnectivity still has content to hand over, for the background task
    /// that woke the app to deliver it. Bounded: the system gives a background task seconds.
    func waitForPendingContent() async {
        for _ in 0 ..< 50 where WCSession.default.hasContentPending {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// A continuation resumed exactly once, whichever handler WatchConnectivity calls.
///
/// ⚠️ APPLE DOCUMENTS ONE OF THE TWO, but a continuation resumed twice is a crash, so the
/// rule is enforced here rather than trusted.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhoneAnswer, Never>?

    init(_ continuation: CheckedContinuation<PhoneAnswer, Never>) {
        self.continuation = continuation
    }

    func resume(_ answer: PhoneAnswer) {
        let pending = lock.withLock { () -> CheckedContinuation<PhoneAnswer, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: answer)
    }
}

/// The session's delegate. Callbacks arrive on WatchConnectivity's own queue.
final class PhoneSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// ⚠️ SET ONCE, BEFORE `activate()`, which is why they need no lock.
    var onReading: (@Sendable (WatchSnapshotReading) -> Void)?
    var onReachable: (@Sendable () -> Void)?

    /// ⚠️ A TAP THAT RESUMES THE APP IS HANDLED BEFORE THE PHONE IS BACK IN REACH (measured
    /// on the simulator pair: reachable about half a second after the tap), and no new
    /// application context need follow. This is what lets ``WatchStore/open(_:)`` ask then.
    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        onReachable?()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error _: (any Error)?
    ) {
        guard state == .activated else { return }
        // ⚠️ THE CONTEXT RECEIVED WHILE THE APP WAS NOT RUNNING arrives here, not through
        // `didReceiveApplicationContext`.
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        onReading?(WatchSnapshot.read(context))
    }

    func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        onReading?(WatchSnapshot.read(applicationContext))
    }
}
