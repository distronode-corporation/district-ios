@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import SwiftUI
import XCTest

/// A meeting room: the screen before Join for a member who may publish and one who may not, the
/// banner for every phase a room can be in, the notices above the grid, the tiles in it, and a
/// finished meeting's record sheet drawn from the service's recorded meeting.
///
/// ⚠️ A JOINED ROOM NEEDS A LIVE LIVEKIT ENGINE, which no test here starts, so the grid is drawn
/// through its tiles (``RoomParticipantTile``) rather than through a connected ``ActiveRoomModel``.
final class RoomsSnapshotTests: ScreenSnapshotTestCase {
    private static func room() throws -> RoomName {
        try XCTUnwrap(RoomName("meet_weekly-review"))
    }

    // MARK: - Before Join

    /// A client: what is about to happen, the microphone and camera choices, Join.
    func testReadyToJoin() async throws {
        let room = try Self.room()
        try await assertScreen { container in
            ActiveRoomView(container: container, roomName: room, role: .client)
        }
    }

    /// A viewer, who may listen but not publish.
    func testReadyToJoinViewer() async throws {
        let room = try Self.room()
        try await assertScreen(devices: [.iPhone]) { container in
            ActiveRoomView(container: container, roomName: room, role: .viewer)
        }
    }

    // MARK: - The banner

    /// Every phase with a banner, one under another: connecting, reconnecting, left, dropped,
    /// each of the three audio yields and the failure. Idle and connected draw none.
    func testBanners() async throws {
        let phases: [RoomPhase] = [
            .idle, .joining, .connected, .reconnecting, .left, .droppedRemotely(reason: "Room deleted"),
            .yielded(.telephoneCall), .yielded(.sessionEnded), .yielded(.workspaceChanged),
            .failed(message: "Something went wrong."),
        ]
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                VStack(spacing: DistrictSpacing.tight) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        RoomConnectionBanner(phase: phase)
                    }
                }
                .padding()
            }
        }
    }

    func testBannerWording() {
        XCTAssertNil(RoomBanner.of(.idle), "before Join the card explains, not a banner")
        XCTAssertNil(RoomBanner.of(.connected), "no green bar over every meeting")
        XCTAssertEqual(RoomBanner.of(.reconnecting)?.tone, .warning, "a reconnect is recoverable, not an error")
        XCTAssertEqual(
            RoomBanner.of(.droppedRemotely(reason: "Room deleted"))?.text,
            RoomsCopy.stateDropped,
            "never the SDK's own English reason"
        )
        XCTAssertEqual(RoomBanner.of(.failed(message: "x"))?.tone, .danger)
        XCTAssertEqual(RoomBanner.of(.yielded(.telephoneCall))?.text, RoomsCopy.stateYieldedToCall)
        XCTAssertEqual(RoomBanner.of(.yielded(.sessionEnded))?.text, RoomsCopy.stateYieldedToSession)
        XCTAssertEqual(RoomBanner.of(.yielded(.workspaceChanged))?.text, RoomsCopy.stateYieldedToWorkspace)
        XCTAssertEqual(RoomBanner.of(.yielded(.telephoneCall))?.tone, .neutral, "nothing went wrong")
    }

    // MARK: - The notices

    /// The permission notices in each shape, the companion chip, a refused join and a control
    /// that did not respond.
    func testNotices() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                    RoomCompanionChip()
                    RoomPermissionNotices(
                        canPublish: true,
                        permissions: RoomPermissions(requested: true, microphoneGranted: false, cameraGranted: false)
                    )
                    RoomPermissionNotices(
                        canPublish: true,
                        permissions: RoomPermissions(requested: true, microphoneGranted: true, cameraGranted: false)
                    )
                    RoomPermissionNotices(
                        canPublish: false,
                        permissions: RoomPermissions(requested: false, microphoneGranted: false, cameraGranted: false)
                    )
                    RoomJoinFailure(failure: FailureText(message: "This room is full.", action: .none))
                    RoomNotice(text: RoomsCopy.flipFailed)
                }
                .padding()
            }
        }
    }

    // MARK: - The tiles

    /// An audio-only grid: a speaking member, a muted one with no name, and the agent.
    func testParticipantTiles() async throws {
        let people = [
            Self.participant("p1", name: "Ada Lovelace", speaking: true),
            Self.participant("p2", name: "  ", microphone: false),
            Self.participant("agent", name: "District", agent: true),
        ]
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack(spacing: DistrictSpacing.tight) {
                ForEach(people) { person in
                    RoomParticipantTile(participant: person).frame(width: 240)
                }
                Spacer()
            }
            .padding()
        }
    }

    private static func participant(
        _ identity: String,
        name: String?,
        agent: Bool = false,
        microphone: Bool = true,
        speaking: Bool = false
    ) -> RoomParticipantSnapshot {
        RoomParticipantSnapshot(
            identity: identity,
            name: name,
            isAgent: agent,
            isMicrophoneEnabled: microphone,
            isSpeaking: speaking,
            audioLevel: speaking ? 0.6 : 0,
            video: nil
        )
    }

    // MARK: - The record

    /// The recorded meeting: the minutes first, then the transcript behind its own label.
    func testMeetingRecord() async throws {
        let meeting = try JSONDecoder().decode(
            MeetingDetail.self,
            from: FixtureTransport.fixtureData("district-meeting-detail")
        )
        try await assertScreen { _ in MeetingRecordSheet(state: .ready(meeting), onClose: {}) }
    }

    /// Still reading.
    func testMeetingRecordLoading() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            MeetingRecordSheet(state: .loading, onClose: {})
        }
    }

    /// Not found (not yours or not there): the service's sentence, promising neither.
    func testMeetingRecordFailed() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            MeetingRecordSheet(
                state: .failed(FailureText(message: "That meeting was not found.", action: .none)),
                onClose: {}
            )
        }
    }
}
