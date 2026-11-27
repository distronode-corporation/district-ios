@testable import DistrictAI
import UIKit
import XCTest

/// What each room phase allows (whether it is live, whether Join is offered), the lobby's refusals,
/// and the tab bar's three faces of each tab.
final class RoomPhaseRulesTests: XCTestCase {
    private static let every: [RoomPhase] = [
        .idle, .joining, .connected, .reconnecting, .left, .droppedRemotely(reason: nil),
        .droppedRemotely(reason: "Room deleted"), .yielded(.telephoneCall), .yielded(.sessionEnded),
        .yielded(.workspaceChanged), .failed(message: nil), .failed(message: "x"),
    ]

    /// ⛔ JOINING COUNTS AS LIVE: the back button is hidden from the press of Join, not from the connect.
    func testWhichPhasesAreLive() {
        let live = Self.every.filter(\.isLive)
        XCTAssertEqual(live, [.joining, .connected, .reconnecting])
    }

    /// ⛔ JOIN IS NOT OFFERED AFTER A LEAVE (the person asked to go), only after an ending that was
    /// not theirs, and never while a join is under way.
    func testWhichPhasesOfferJoin() {
        let joinable = Self.every.filter(\.canJoin)
        XCTAssertEqual(joinable, [
            .idle, .droppedRemotely(reason: nil), .droppedRemotely(reason: "Room deleted"),
            .yielded(.telephoneCall), .yielded(.sessionEnded), .yielded(.workspaceChanged),
            .failed(message: nil), .failed(message: "x"),
        ])
        XCTAssertFalse(RoomPhase.left.canJoin)
    }

    /// No phase is both live and joinable, and only `left` is neither.
    func testLiveAndJoinableNeverOverlap() {
        for phase in Self.every {
            XCTAssertFalse(phase.isLive && phase.canJoin, "\(phase)")
        }
        XCTAssertEqual(Self.every.filter { !$0.isLive && !$0.canJoin }, [.left])
    }

    /// The lobby's refusals offer nothing to press: pressing again cannot change any of them.
    func testTheLobbysRefusalsOfferNoAction() {
        for failure in [RoomsCopy.busyWithCall, RoomsCopy.busyWithRoom, RoomsCopy.unusableName] {
            XCTAssertEqual(failure.action, .none)
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertNotEqual(RoomsCopy.busyWithCall.message, RoomsCopy.busyWithRoom.message)
    }

    /// Each tab has its own label, identifier and symbol, and the identifiers are Android's tokens.
    func testEveryTabIsDistinct() {
        XCTAssertEqual(Set(Tab.allCases.map(\.label)).count, Tab.allCases.count)
        XCTAssertEqual(Set(Tab.allCases.map(\.accessibilityID)).count, Tab.allCases.count)
        XCTAssertEqual(Set(Tab.allCases.map(\.systemImage)).count, Tab.allCases.count)
        XCTAssertEqual(Tab.overview.accessibilityID, A11yID.Nav.overview)
        XCTAssertEqual(Tab.account.systemImage, "person.crop.circle")
        for tab in Tab.allCases {
            XCTAssertNotNil(UIImage(systemName: tab.systemImage), "\(tab) names a symbol that exists")
        }
    }
}
