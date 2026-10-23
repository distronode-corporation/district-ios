import Foundation
import WatchConnectivity

/// `WCSession` on the iPhone.
///
/// ⚠️ THE DELEGATE IS A SEPARATE, NONISOLATED OBJECT. WatchConnectivity calls it on a
/// background queue of its own, so it lifts each callback onto the main actor, where the
/// service lives, and copies out only `Sendable` values (the request's `Data`) before the
/// hop. The reply handler is not `Sendable` by declaration but is documented safe to call
/// from any thread, which is what ``ReplyBox`` records.
@MainActor
final class LiveWatchSessionLink: WatchSessionLinking {
    private let delegate = WatchSessionDelegate()

    var isCompanionInstalled: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func activate(
        onReady: @escaping @MainActor @Sendable () -> Void,
        onRequest: @escaping @MainActor @Sendable (Data, @escaping @Sendable ([String: Any]) -> Void) -> Void
    ) {
        // ⚠️ AN iPad ACTIVATES TOO AND IS NEVER PAIRED, so `isCompanionInstalled` stays
        // false and no snapshot is ever built there.
        guard WCSession.isSupported() else { return }
        delegate.onReady = { Task { @MainActor in onReady() } }
        delegate.onRequest = { data, reply in
            Task { @MainActor in onRequest(data) { reply.send($0) } }
        }
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    func publish(_ context: [String: Any]) throws {
        guard isCompanionInstalled else { return }
        try WCSession.default.updateApplicationContext(context)
    }
}

/// The reply handler WatchConnectivity hands over, carried across the hop to the main actor.
///
/// ⚠️ `@unchecked Sendable` IS APPLE'S CONTRACT, NOT A GUESS: the handler may be called on
/// any thread, once. Calling it is the only thing this type does.
struct ReplyBox: @unchecked Sendable {
    let handler: ([String: Any]) -> Void

    func send(_ message: [String: Any]) {
        handler(message)
    }
}

/// The session's delegate. Every callback arrives on WatchConnectivity's own queue.
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// ⚠️ SET ONCE, BEFORE `activate()`, AND ONLY READ AFTER IT: no callback can arrive
    /// before the session is activated, which is why these need no lock.
    var onReady: (@Sendable () -> Void)?
    var onRequest: (@Sendable (Data, ReplyBox) -> Void)?

    func session(_: WCSession, activationDidCompleteWith state: WCSessionActivationState, error _: (any Error)?) {
        guard state == .activated else { return }
        onReady?()
    }

    func sessionWatchStateDidChange(_: WCSession) {
        onReady?()
    }

    func sessionDidBecomeInactive(_: WCSession) {}

    /// ⚠️ A WATCH SWITCH: Apple's documented answer is to activate again, for the new watch.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(
        _: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let box = ReplyBox(handler: replyHandler)
        guard let data = WatchRequest.read(message), let onRequest else {
            // ⚠️ ANSWERED, NOT DROPPED: an unanswered message leaves the watch waiting for its
            // timeout. The sentence is resolved on the main actor, where the copy lives.
            Task { @MainActor in box.send(WatchReply.failure(WatchBridgeCopy.updateBothApps).message()) }
            return
        }
        onRequest(data, box)
    }
}
