@testable import DistrictAI
import DistrictCall
import Foundation
import XCTest

/// A call asks for the microphone before it can fail for want of one.
///
/// ⚠️ EVERY CONTAINER HERE POINTS AT `https://calls.invalid`. The `.invalid` TLD is reserved and never
/// resolves, so a path that did reach the network fails on this device and no credential the
/// simulator's keychain may hold is sent anywhere. ⛔ That is what keeps the dial tests honest about a
/// telephone: nothing here can ring one, even if the model under test regressed into dialling.
///
/// ⚠️ THE MODELS RUN THEIR WORK IN TASKS THEY OWN AND EXPOSE NO COMPLETION TO AWAIT, so each test polls
/// for the state it expects, with a bound, rather than sleeping a fixed time and hoping.
@MainActor
final class MicrophoneAccessTests: XCTestCase {
    private let unreachable = URL(string: "https://calls.invalid")!
    private let dialable = "+14165550100"

    // MARK: - Dialling

    /// ⛔ A REFUSED MICROPHONE PLACES NOTHING. The dial route is reached only from `beginDial(uuid:)`,
    /// which runs once CallKit reports the start action performed, and the start is requested only
    /// after a grant. A refusal that ends with no session and no claim therefore dialled nothing.
    func testADeniedMicrophoneDialsNothingAndSaysWhy() async {
        let microphone = FakeMicrophoneAccess(status: .denied)
        let container = AppContainer(baseURL: unreachable, microphone: microphone)
        let model = DialerModel(container: container, workspaceId: "ws_1", role: .agency)
        model.onEntryChange(dialable)
        XCTAssertTrue(model.canPlaceCall, "the fixture number must be dialable or this test proves nothing")

        model.placeCall()
        await waitUntil { microphone.requestCount == 1 && !model.placing }

        XCTAssertEqual(model.refusal?.message, DialerModel.microphoneOff.message)
        XCTAssertNil(model.call, "a session exists only once CallKit performed the start, which the dial follows")
        XCTAssertFalse(container.callStack.hasLiveCall, "a refusal must drop the claim on the call stack")
    }

    /// ⚠️ A GRANT CHANGES NOTHING DOWNSTREAM. The start still goes to the OS; whatever the simulator's
    /// CallKit or the unresolvable host then answers, the reason the call did not proceed is never the
    /// microphone.
    ///
    /// ⛔ AND A START THE OS REFUSES ENDS WHEN iOS SAYS SO, NOT WHEN THE WATCHDOG FIRES. The simulator
    /// refuses this build's `CXStartCallAction` within milliseconds, as unentitled, so the case also
    /// pins that a reported refusal ends the attempt at once. A pass that waited out the ten-second
    /// timer would be a bound racing a clock on a busy machine.
    func testAGrantedMicrophoneStillHandsTheCallToTheOS() async {
        let microphone = FakeMicrophoneAccess(status: .granted)
        let container = AppContainer(baseURL: unreachable, microphone: microphone)
        let model = DialerModel(container: container, workspaceId: "ws_1", role: .agency)
        model.onEntryChange(dialable)
        let pressed = Date()

        model.placeCall()
        let settled = { !model.placing && model.call == nil && !container.callStack.hasLiveCall }
        // ⚠️ FIFTEEN SECONDS IS FOR A START THE OS PERFORMS, which fails later, at the unresolvable
        // host. A refused one settles in milliseconds.
        await waitUntil(timeout: 15, state: Self.state(of: model, in: container)) {
            microphone.requestCount == 1 && settled()
        }

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertNotNil(model.refusal, "with no carrier reachable the attempt must end with a reason")
        XCTAssertNotEqual(model.refusal?.message, DialerModel.microphoneOff.message)
        // ⚠️ ONLY WHEN A TRANSACTION WAS REFUSED: a performed start records no failure, and how
        // long it takes to fail is up to the unresolvable host rather than iOS.
        if container.callStack.callKit.lastTransactionFailure != nil {
            XCTAssertLessThan(
                Date().timeIntervalSince(pressed),
                Double(DialerModel.startTimeoutSeconds),
                "iOS refused the start, yet the attempt waited out the watchdog "
                    + Self.state(of: model, in: container)
            )
        }
    }

    // MARK: - Answering

    /// ⛔ ASKED ONLY WHERE IT CAN BE ANSWERED, AND ONLY ONCE. A backgrounded answer (lock screen, car,
    /// headset) cannot show the alert and must not wait on one; an answered question is never put again.
    func testAtAnswerOnlyAnUnaskedQuestionIsPutAndOnlyInTheForeground() async {
        let fresh = FakeMicrophoneAccess(status: .notDetermined, grantsWhenAsked: true)

        let fromTheLockScreen = await IncomingCallModel.askAtAnswer(fresh, appIsActive: false)
        XCTAssertFalse(fromTheLockScreen, "a backgrounded answer cannot show an alert")
        XCTAssertEqual(fresh.requestCount, 0)

        let onScreen = await IncomingCallModel.askAtAnswer(fresh, appIsActive: true)
        XCTAssertTrue(onScreen)
        XCTAssertEqual(fresh.requestCount, 1)

        let again = await IncomingCallModel.askAtAnswer(fresh, appIsActive: true)
        XCTAssertFalse(again, "an answered question is never put twice")

        let refused = FakeMicrophoneAccess(status: .denied)
        let afterARefusal = await IncomingCallModel.askAtAnswer(refused, appIsActive: true)
        XCTAssertFalse(afterARefusal)
        XCTAssertEqual(refused.requestCount, 0)
    }

    // ⚠️ NO CASE DRIVES `incomingPush` HERE. It awaits `CXProvider.reportNewIncomingCall`,
    // which the simulator never completes, and a bounded poll cannot save a test that is
    // stuck before it: measured, the case hung the whole unit lane for 30 minutes.
    // The property it wanted (a refused microphone still answers) is the
    // `askAtAnswer` contract above; the round trip itself is exercised on a device.

    // MARK: - Support

    /// ⚠️ A BOUNDED POLL, read on the main actor between short sleeps. A timeout fails the test at the
    /// caller's line rather than hanging the run, and says where the attempt stood.
    private func waitUntil(
        timeout seconds: Double = 5,
        state: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(seconds)s \(state())", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Where a dial attempt stands, for a failure message.
    private static func state(of model: DialerModel, in container: AppContainer) -> String {
        let phase = model.call.map { String(describing: $0.state.phase) } ?? "none"
        let refusal = model.refusal?.message ?? "none"
        let failure = container.callStack.callKit.lastTransactionFailure ?? "none"
        return "[placing: \(model.placing), phase: \(phase), claim held: \(container.callStack.hasLiveCall), "
            + "refusal: \(refusal), refused transaction: \(failure)]"
    }
}
