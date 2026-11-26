@testable import DistrictAI
import DistrictCall
import SwiftUI
import XCTest

/// The call screen of an outbound softphone call in each phase, drawn from states the core's own
/// reducer (``SoftphoneSession``) reaches from the events a real call delivers, and the dialer's
/// country picker.
final class InCallSnapshotTests: ScreenSnapshotTestCase {
    /// What the call screen's buttons would do: nothing, in a drawing.
    @MainActor
    private final class InertControls: LiveCallControls {
        func toggleMute() {}
        func toggleSpeaker() async {}
        func hangUp() async {}
        func dismissEndedCall() {}
    }

    private static let number = "+1 416 555 0199"

    /// The session after `events`, from a dial request.
    private static func session(_ events: [SoftphoneEvent]) -> SoftphoneState {
        var session = SoftphoneSession(number: number)
        session.handle(.dialRequested)
        for event in events {
            session.handle(event)
        }
        return session.state
    }

    private static let accepted = SoftphoneEvent.dialAccepted(
        url: "wss://sfu.example.test",
        token: "t",
        callId: "call_1"
    )
    private static let answered: [SoftphoneEvent] = [
        accepted,
        .engine(.connected),
        .engine(.participantJoined(CallParticipant(identity: "sip_callee"))),
    ]

    private func assertCall(
        _ state: SoftphoneState,
        endedByOperator: Bool = false,
        devices: [Device] = [.iPhone],
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        let controls = InertControls()
        try await assertScreen(devices: devices, testName: testName, line: line) { _ in
            InCallView(display: .softphone(state, endedByOperator: endedByOperator), controls: controls)
        }
    }

    // MARK: - Under way

    /// The dial is out: Calling, mute, speaker and hang up.
    func testCalling() async throws {
        let state = Self.session([Self.accepted])
        XCTAssertFalse(state.phase.isEnded)
        try await assertCall(state, devices: Device.allCases)
    }

    /// In the room, nobody on the line yet.
    func testRinging() async throws {
        let state = Self.session([Self.accepted, .engine(.connected)])
        XCTAssertEqual(state.phase, .ringing)
        try await assertCall(state)
    }

    /// Answered, a minute and five seconds in.
    func testConnected() async throws {
        let state = Self.session(Self.answered + Array(repeating: .tick, count: 65))
        XCTAssertEqual(state.phase, .connected)
        XCTAssertEqual(state.media.elapsedSeconds, 65)
        try await assertCall(state, devices: Device.allCases)
    }

    /// The media dropped and is coming back: the reconnecting line under the duration.
    func testReconnecting() async throws {
        let state = Self.session(Self.answered + [.tick, .engine(.reconnecting)])
        XCTAssertTrue(state.media.reconnecting)
        try await assertCall(state)
    }

    // MARK: - Ended

    /// The operator hung up an answered call: the duration and the call log notice, Done.
    func testEndedByOperator() async throws {
        let state = Self.session(
            Self.answered + Array(repeating: .tick, count: 65) + [.hangUpPressed, .engine(.disconnected(reason: nil))]
        )
        XCTAssertTrue(state.phase.isEnded)
        try await assertCall(state, endedByOperator: true, devices: Device.allCases)
    }

    /// The callee hung up.
    func testEndedRemotely() async throws {
        let left = SoftphoneEvent.engine(.participantLeft(CallParticipant(identity: "sip_callee")))
        let state = Self.session(Self.answered + [.tick, .tick, left])
        XCTAssertEqual(state.phase, .ended(.remoteHungUp))
        try await assertCall(state)
    }

    /// The service refused the dial: never answered, so no duration.
    func testDialRefused() async throws {
        let state = Self.session([.dialRefused])
        XCTAssertTrue(state.phase.isEnded)
        XCTAssertFalse(state.answered)
        try await assertCall(state)
    }

    // MARK: - The dialer

    /// A viewer opens the dialer: the viewer notice in place of the microphone one, no call to place.
    func testDialerViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            DialerView(container: container, workspaceId: "ws-contract-test", role: .viewer)
        }
    }

    // MARK: - The country picker

    /// Every country, the home one first and the chosen one marked.
    func testCountryPicker() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            DialerCountryPicker(home: "CA", selected: "FR") { _ in }
        }
    }

    /// No home country known (a workspace with no region) and nothing chosen.
    func testCountryPickerNoHome() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            DialerCountryPicker(home: nil, selected: nil) { _ in }
        }
    }
}
