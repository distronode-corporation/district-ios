@testable import DistrictAIWatch
import XCTest

/// The real `WCSession` send, which the fake link in ``WatchStoreTests`` stands in for.
///
/// ⛔ THE ONE TEST HERE THAT TOUCHES WATCHCONNECTIVITY, AND WHY: WatchConnectivity calls
/// `sendMessage`'s handlers on its own queue, and a handler isolated to the main actor traps
/// there (the 2026-10-24 crash on every write). No fake can show that, because the trap is
/// in the handler the live link builds. With no reachable phone in the test host the session
/// fails the send at once, through the error handler, on that queue.
///
/// ⚠️ A REGRESSION IS A CRASHED TEST PROCESS, NOT A RED ASSERTION: xcodebuild reports the
/// test as failed after "Restarting after unexpected exit, crash, or test timeout".
final class LivePhoneLinkTests: XCTestCase {
    func testAnAnswerOnWatchConnectivitysQueueResumesRatherThanTraps() async {
        let answer = await LivePhoneLink.deliver(WatchRequest(action: .refresh))

        // The error handler ran, on WatchConnectivity's queue, and the send came back.
        XCTAssertTrue([PhoneAnswer.unreachable, .noAnswer].contains(answer), "\(answer)")
    }
}
