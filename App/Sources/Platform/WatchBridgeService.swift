import Foundation
import UIKit

/// The iPhone's half of the Apple Watch app: it keeps the watch's picture current and
/// makes the watch's writes.
///
/// ⛔ THE WATCH IS A COMPANION AND HOLDS NOTHING. No credential, no request, no
/// DistrictCore: it shows the ``WatchSnapshot`` this service sends and asks this service
/// to write. Every request is made here, through the container's one
/// ``TokenRefreshCoordinator``.
///
/// ⛔ ACTIVATED IN `DistrictApp.init`, BESIDE THE NOTIFICATION HANDOVER, AND FOR THE SAME
/// REASON. A message from the watch launches the iPhone app in the BACKGROUND with no
/// scene, so a session activated from a view would not exist to receive it.
///
/// ⚠️ A SNAPSHOT COSTS FOUR READS, SO IT IS BUILT ONLY FOR A PAIRED WATCH WITH THE APP
/// INSTALLED, and requests made while one is building are coalesced into one more build
/// after it rather than one each.
@MainActor
final class WatchBridgeService {
    private let link: any WatchSessionLinking
    private let source: any WatchSnapshotSourcing
    private let actions: any WatchActionPerforming
    private let live: (any WatchLiveHandling)?
    private let backgroundTasks: any BackgroundTaskScheduling
    private let clock: @MainActor () -> Date

    private var building: Task<Void, Never>?
    private var needsAnother = false

    /// The last snapshot handed to WatchConnectivity. For tests and for the log.
    private(set) var lastPublished: WatchSnapshot?

    init(
        link: any WatchSessionLinking,
        source: any WatchSnapshotSourcing,
        actions: any WatchActionPerforming,
        live: (any WatchLiveHandling)? = nil,
        backgroundTasks: any BackgroundTaskScheduling = UIKitBackgroundTasks(),
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.link = link
        self.source = source
        self.actions = actions
        self.live = live
        self.backgroundTasks = backgroundTasks
        self.clock = clock
    }

    /// Start the session. Safe on a device with no watch: the link does nothing there.
    func activate() {
        link.activate(
            onReady: { [weak self] in self?.setNeedsSnapshot() },
            onRequest: { [weak self] data, reply in
                guard let self else {
                    reply(WatchReply.failure(WatchBridgeCopy.updateBothApps).message())
                    return
                }
                Task { await self.handle(requestData: data, reply: reply) }
            }
        )
    }

    /// Something the watch shows may have changed: sign-in or sign-out, a workspace switch,
    /// availability, the inbox or the call log, or the app coming forward.
    func setNeedsSnapshot() {
        guard link.isCompanionInstalled else { return }
        guard building == nil else {
            needsAnother = true
            return
        }
        building = Task { [weak self] in
            await self?.buildUntilCurrent()
        }
    }

    /// Wait for any build in flight. For tests, and for a write that must publish before
    /// its background time ends.
    func settle() async {
        while let running = building {
            await running.value
        }
    }

    /// ⛔ IMMEDIATELY, WITH NO READ. A signed-out phone has no session to read with, and the
    /// watch must stop showing the last account now rather than after a build.
    func publishSignedOut() {
        publish(.signedOut(at: clock(), language: WatchBridgeLanguage.current))
    }

    // MARK: - Writes from the watch

    /// One request from the watch: act, answer, then send the picture that resulted.
    ///
    /// ⛔ THE REPLY IS SENT AFTER THE WORK, NEVER BEFORE IT. The watch shows success only
    /// on `ok`, so answering first would claim a write that may yet fail.
    ///
    /// ⛔ HELD OPEN BY A BACKGROUND TASK FOR ITS WHOLE LENGTH, the lease PR #75 introduced.
    /// A message from the watch can launch this app in the background, where a suspension
    /// mid-request is the default rather than the exception.
    func handle(requestData: Data, reply: @escaping @Sendable ([String: Any]) -> Void) async {
        let lease = BackgroundTaskLease.begin("district.watch-request", on: backgroundTasks)
        let request = try? WatchWire.decoder.decode(WatchRequest.self, from: requestData)
        guard let request, request.protocolVersion == WatchSnapshot.currentProtocolVersion else {
            reply(WatchReply.failure(WatchBridgeCopy.updateBothApps).message())
            lease.end()
            return
        }
        switch request.action {
        case .refresh:
            reply(WatchReply.success.message())
        case let .resolveMessage(workspaceId, messageId):
            switch await actions.threadKey(workspaceId: workspaceId, messageId: messageId) {
            case let .success(threadKey):
                reply(WatchReply.thread(threadKey).message())
            case let .failure(failure):
                reply(WatchReply.failure(failure.sentence).message())
            }
        case .liveList, .liveSubscribe, .liveKeepalive, .liveUnsubscribe, .whisper, .callDetail:
            // ⛔ NO SNAPSHOT AFTER THESE. A keepalive arrives every 5 s, and a snapshot costs
            // four reads; none of these changes what the snapshot shows. Without a relay this
            // phone answers as one that predates them, and the watch hides Live.
            let answer = await live?.answer(request.action) ?? .failure(WatchBridgeCopy.updateBothApps)
            reply(answer.message())
            lease.end()
            return
        case .reply, .markRead, .setAvailability:
            switch await actions.perform(request.action) {
            case .success:
                reply(WatchReply.success.message())
            case let .failure(failure):
                reply(WatchReply.failure(failure.sentence).message())
            }
        }
        // ⚠️ EVEN AFTER A FAILURE: a refused write may still mean the picture moved (a
        // workspace the person was removed from), and the watch's next view should be true.
        // ⚠️ AND AFTER A RESOLVE: the message just tapped may be in a thread the last
        // snapshot predates, and the watch opens it when this one carries it.
        setNeedsSnapshot()
        await settle()
        lease.end()
    }

    // MARK: - Building

    private func buildUntilCurrent() async {
        repeat {
            needsAnother = false
            let lease = BackgroundTaskLease.begin("district.watch-snapshot", on: backgroundTasks)
            if let snapshot = await source.snapshot(at: clock()) {
                publish(snapshot)
            }
            lease.end()
        } while needsAnother
        building = nil
    }

    private func publish(_ snapshot: WatchSnapshot) {
        guard let fitted = snapshot.fitted() else { return }
        do {
            try link.publish(fitted.context())
            lastPublished = fitted
        } catch {
            // ⚠️ NOTHING TO RETRY: the next trigger builds again, and the watch keeps the
            // previous snapshot (with its age shown) rather than a blank one.
        }
    }
}

// MARK: - Seams

/// WatchConnectivity, behind a seam so a test can stand in for the watch.
@MainActor
protocol WatchSessionLinking: AnyObject {
    /// A paired watch with this app installed, on an activated session.
    var isCompanionInstalled: Bool { get }

    /// - Parameters:
    ///   - onReady: the session activated, or the watch app was installed.
    ///   - onRequest: a `sendMessage` from the watch, with its reply handler.
    func activate(
        onReady: @escaping @MainActor @Sendable () -> Void,
        onRequest: @escaping @MainActor @Sendable (Data, @escaping @Sendable ([String: Any]) -> Void) -> Void
    )

    func publish(_ context: [String: Any]) throws
}

/// Builds the watch's picture from the phone's repositories.
@MainActor
protocol WatchSnapshotSourcing {
    /// nil when the session could not be checked (a locked Keychain, a throttled refresh):
    /// the watch keeps what it has rather than being told the person signed out.
    func snapshot(at now: Date) async -> WatchSnapshot?
}

/// Makes the watch's writes.
@MainActor
protocol WatchActionPerforming {
    func perform(_ action: WatchAction) async -> Result<Void, WatchActionFailure>

    /// The thread key of the thread a message belongs to. See ``WatchAction/resolveMessage(workspaceId:messageId:)``.
    func threadKey(workspaceId: String, messageId: String) async -> Result<String, WatchActionFailure>
}

/// A write that did not go through, with the sentence the watch shows.
struct WatchActionFailure: Error, Equatable {
    let sentence: String
}

/// The phone's language, as the snapshot names it.
enum WatchBridgeLanguage {
    @MainActor static var current: String {
        AppL10n.copyLocale == .frCA ? "fr-CA" : "en"
    }
}
