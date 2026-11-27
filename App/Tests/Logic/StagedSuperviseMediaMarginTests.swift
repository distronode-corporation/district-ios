@testable import DistrictAI
import DistrictCall
import Foundation
import XCTest

/// The staged supervision device of the screenshot lane: it answers as CallKit and a LiveKit
/// room would, on a timer, and nothing else. ⚠️ A test that expects a callback waits for it
/// (bounded, failing if it never comes), never for a fixed time: the device's delays (800 ms
/// for the start, 3 s for the join) are minimums, and a loaded runner can run them late. Only
/// the tests that prove nothing arrives wait a fixed time past the device's delay.
@MainActor
final class StagedSuperviseMediaMarginTests: XCTestCase {
    private let uuid = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    // MARK: - Arming

    /// ⛔ The variable alone never arms it, and only the exact value "1" counts as the half it is.
    func testTheVariableAloneNeverArmsIt() {
        XCTAssertFalse(UITestSession.isArmed(), "a unit test run carries no launch argument")
        XCTAssertFalse(StagedSuperviseMedia.isArmed(environment: [StagedSuperviseMedia.variable: "1"]))
        XCTAssertFalse(StagedSuperviseMedia.isArmed(environment: [:]))
        XCTAssertFalse(StagedSuperviseMedia.isArmed(environment: [StagedSuperviseMedia.variable: "true"]))
        XCTAssertFalse(StagedSuperviseMedia.isArmed(environment: [StagedSuperviseMedia.variable: ""]))
        XCTAssertFalse(StagedHQVoiceEngine.isArmed(environment: [StagedSuperviseMedia.variable: "1"]))
        XCTAssertEqual(StagedSuperviseMedia.variable, "DISTRICT_UITEST_STAGED_MEDIA")
    }

    func testTheDeviceHoldsNothingAndItsMicrophoneIsAlwaysGranted() async {
        let media = StagedSuperviseMedia()
        XCTAssertFalse(media.hasLiveCall)
        XCTAssertFalse(media.hasLiveRoom)
        XCTAssertEqual(media.microphone.status, .granted)
        let granted = await media.microphone.request()
        XCTAssertTrue(granted)
    }

    // MARK: - The system call

    func testAStartIsPerformedAfterADelayAsTheOSWouldPerformIt() async {
        let media = StagedSuperviseMedia()
        let requests = StagedRequests()
        media.claim(self) { requests.all.append($0) }

        media.startCall(uuid: uuid, handle: "Maya Chen") {}
        XCTAssertEqual(requests.all, [], "never synchronously")
        await stagedWait { !requests.all.isEmpty }

        XCTAssertEqual(requests.all, [.dialRequested(uuid: uuid)])
    }

    /// ⚠️ A mute is echoed back as CallKit echoes it, so the model applies it only then.
    func testAMuteIsEchoedThroughTheHandler() async {
        let media = StagedSuperviseMedia()
        let requests = StagedRequests()
        media.claim(self) { requests.all.append($0) }

        media.requestMuted(uuid: uuid, muted: true)
        media.requestMuted(uuid: uuid, muted: false)
        await stagedWait { requests.all.count >= 2 }

        // ⚠️ EACH ECHO IS ITS OWN TASK, so the two can land in either order; both must land.
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertTrue(requests.all.contains(.muteRequested(uuid: uuid, muted: true)))
        XCTAssertTrue(requests.all.contains(.muteRequested(uuid: uuid, muted: false)))
    }

    func testAReleasedClaimHearsNothingThatWasStillPending() async throws {
        let media = StagedSuperviseMedia()
        let requests = StagedRequests()
        media.claim(self) { requests.all.append($0) }

        media.startCall(uuid: uuid, handle: "") {}
        media.requestMuted(uuid: uuid, muted: true)
        media.release(self)
        try await Task.sleep(for: .milliseconds(1200))

        XCTAssertEqual(requests.all, [])
    }

    /// The reports CallKit would draw are no-ops here: nothing reaches the handler.
    func testReportsReachNothing() async throws {
        let media = StagedSuperviseMedia()
        let requests = StagedRequests()
        media.claim(self) { requests.all.append($0) }

        media.reportConnecting(uuid: uuid, callerName: "Maya Chen")
        media.reportConnected(uuid: uuid)
        media.requestEnd(uuid: uuid)
        media.reportEnded(uuid: uuid)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(requests.all, [])
    }

    // MARK: - The legs

    /// A listener's join announces the two people present, then the connection, and no microphone.
    func testAListenJoinAnnouncesThePeoplePresentAndNoMicrophone() async {
        let media = StagedSuperviseMedia()
        let stream = await media.beginLeg(.listen)
        let seen = StagedEvents<CallEngineEvent>()
        let collector = Task { await seen.drain(stream) }

        await media.perform(.connect(url: "wss://staged.invalid", token: "t"))
        // ⛔ THE LEG ENDS ONLY AFTER THE JOIN HAS ARRIVED: ending it first finishes the stream
        // the delayed join yields into, and those events are dropped.
        await stagedWait { seen.all.count >= 3 }
        media.endLeg()
        await collector.value
        let events = seen.all

        XCTAssertEqual(events, [
            .participantJoined(CallParticipant(identity: "caller", name: nil, isAgent: false)),
            .participantJoined(CallParticipant(identity: "agent", name: "Ava", isAgent: true)),
            .connected,
        ])
    }

    /// ⚠️ The coach leg's microphone starts after the connection, as the engine reports it.
    func testATakeoverJoinAlsoReportsTheMicrophoneStarted() async {
        let media = StagedSuperviseMedia()
        let stream = await media.beginLeg(.takeover)
        let seen = StagedEvents<CallEngineEvent>()
        let collector = Task { await seen.drain(stream) }

        await media.perform(.connect(url: "wss://staged.invalid", token: "t"))
        await stagedWait { seen.all.count >= 4 }
        media.endLeg()
        await collector.value
        let events = seen.all

        XCTAssertEqual(events.last, .microphoneChanged(enabled: true))
        guard events.count == 4 else { return XCTFail("expected four events, got \(events)") }
        XCTAssertEqual(events[2], .connected, "the microphone follows the connection")
    }

    /// ⛔ The polarity: `setMuted(true)` is a microphone turned OFF.
    func testMuteCommandsReportTheMicrophoneInverted() async {
        let media = StagedSuperviseMedia()
        let stream = await media.beginLeg(.takeover)
        let collector = Task { await stagedDrain(stream) }

        await media.perform(.setMuted(true))
        await media.perform(.setMuted(false))
        await media.perform(.setSpeakerphone(true))
        await media.perform(.disconnect)
        media.endLeg()
        let events = await collector.value

        XCTAssertEqual(events, [.microphoneChanged(enabled: false), .microphoneChanged(enabled: true)])
    }

    /// ⛔ The previous leg's stream is finished when the next begins, as a takeover replaces a listen.
    func testANewLegFinishesThePreviousStream() async {
        let media = StagedSuperviseMedia()
        let listen = await media.beginLeg(.listen)
        let first = Task { await stagedDrain(listen) }
        let takeover = await media.beginLeg(.takeover)
        let second = Task { await stagedDrain(takeover) }

        await media.perform(.setMuted(true))
        let firstEvents = await first.value
        media.endLeg()
        let secondEvents = await second.value

        XCTAssertEqual(firstEvents, [], "the old leg hears nothing after the new one began")
        XCTAssertEqual(secondEvents, [.microphoneChanged(enabled: false)])
    }

    /// ⚠️ Hostile order: commands and an end with no leg are dropped, and a second end is harmless.
    func testCommandsWithNoLegAreDropped() async {
        let media = StagedSuperviseMedia()
        await media.perform(.setMuted(true))
        await media.perform(.connect(url: "", token: ""))
        media.endLeg()
        media.endLeg()

        let stream = await media.beginLeg(.listen)
        let collector = Task { await stagedDrain(stream) }
        media.endLeg()
        let events = await collector.value
        XCTAssertEqual(events, [], "nothing queued before the leg leaks into it")
    }
}

/// What reached a claim's handler.
@MainActor
final class StagedRequests {
    var all: [CallKitRequest] = []
}

/// Every element of `stream` until it finishes.
func stagedDrain<Element: Sendable>(_ stream: AsyncStream<Element>) async -> [Element] {
    var out: [Element] = []
    for await element in stream {
        out.append(element)
    }
    return out
}

/// The elements of a stream as they arrive, so a test can wait for a count before ending it.
@MainActor
final class StagedEvents<Element: Sendable> {
    private(set) var all: [Element] = []

    func drain(_ stream: AsyncStream<Element>) async {
        for await element in stream {
            all.append(element)
        }
    }
}

/// Waits until `condition` holds, for at most `seconds`, and fails the test if it never does.
@MainActor
func stagedWait(
    seconds: Int = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    for _ in 0 ..< seconds * 100 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    if !condition() {
        XCTFail("the expected callbacks never arrived", file: file, line: line)
    }
}
