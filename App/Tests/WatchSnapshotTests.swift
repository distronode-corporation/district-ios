@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The watch bridge's wire: the same source is compiled into the watch app, so what holds
/// here holds on the wrist.
final class WatchSnapshotTests: XCTestCase {
    func testASnapshotSurvivesTheApplicationContext() throws {
        let snapshot = Self.full(rows: 10)

        let reading = try WatchSnapshot.read(snapshot.context())

        XCTAssertEqual(reading, .snapshot(snapshot))
    }

    func testRequestsAndRepliesRoundTrip() throws {
        let request = WatchRequest(action: .reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "J'arrive."))
        let data = try XCTUnwrap(try WatchRequest.read(request.message()))
        XCTAssertEqual(try WatchWire.decoder.decode(WatchRequest.self, from: data), request)

        XCTAssertEqual(WatchReply.read(WatchReply.success.message()), .success)
        XCTAssertEqual(WatchReply.read(WatchReply.failure("Non.").message())?.error, "Non.")
    }

    /// ⚠️ THE RESOLVE IS ADDED WITHOUT A BUMP: its reply's thread key is optional, so a reply
    /// written before it existed still reads, with no key.
    func testAResolveAndItsThreadKeyRoundTripAndAnOlderReplyStillReads() throws {
        let request = WatchRequest(action: .resolveMessage(workspaceId: "ws_1", messageId: "msg_1"))
        let data = try XCTUnwrap(try WatchRequest.read(request.message()))
        XCTAssertEqual(try WatchWire.decoder.decode(WatchRequest.self, from: data), request)
        XCTAssertEqual(WatchReply.read(WatchReply.thread("contact:c_1").message())?.threadKey, "contact:c_1")

        let older = Data(#"{"protocolVersion":1,"ok":true}"#.utf8)
        let reply = WatchReply.read([WatchReply.messageKey: older])
        XCTAssertEqual(reply, .success)
        XCTAssertNil(reply?.threadKey)
    }

    /// ⛔ A VERSION THIS BUILD DOES NOT SPEAK IS NEVER DECODED, IN EITHER DIRECTION, even when
    /// the rest of the bytes would decode.
    func testAnotherProtocolVersionIsAMismatchNotASnapshot() throws {
        for version in [WatchSnapshot.currentProtocolVersion + 1, 0] {
            var snapshot = Self.full(rows: 1)
            snapshot.protocolVersion = version
            XCTAssertEqual(try WatchSnapshot.read(data: snapshot.encoded()), .versionMismatch(version))
        }
    }

    /// A newer phone that changed the shape entirely is still read as "update", not garbage.
    func testANewerShapeIsStillReadAsAMismatch() {
        let data = Data(#"{"protocolVersion":2,"somethingElse":[1,2,3]}"#.utf8)
        XCTAssertEqual(WatchSnapshot.read(data: data), .versionMismatch(2))
    }

    func testNoSnapshotIsUnreadable() {
        XCTAssertEqual(WatchSnapshot.read([:]), .unreadable)
        XCTAssertEqual(WatchSnapshot.read(data: Data("{}".utf8)), .unreadable)
    }

    /// ⛔ WELL UNDER WATCHCONNECTIVITY'S LIMIT AT THE LIST SIZES THE PHONE SENDS, with every
    /// string at the length the composer allows.
    func testTenOfEachFitsTheBudget() throws {
        let data = try Self.full(rows: WatchSnapshot.listLimit).encoded()

        XCTAssertLessThan(data.count, WatchSnapshot.maximumEncodedBytes)
        XCTAssertEqual(Self.full(rows: WatchSnapshot.listLimit).fitted(), Self.full(rows: WatchSnapshot.listLimit))
    }

    /// ⛔ THE LISTS SHRINK, THE STATE NEVER DOES.
    func testAnOversizedSnapshotLosesRowsNotState() throws {
        let oversized = Self.full(rows: 200)
        XCTAssertGreaterThan(try oversized.encoded().count, WatchSnapshot.maximumEncodedBytes)

        let fitted = try XCTUnwrap(oversized.fitted())

        XCTAssertLessThanOrEqual(try fitted.encoded().count, WatchSnapshot.maximumEncodedBytes)
        XCTAssertEqual(fitted.workspace, oversized.workspace)
        XCTAssertEqual(fitted.availability, oversized.availability)
        XCTAssertEqual(fitted.unreadCount, oversized.unreadCount)
        XCTAssertLessThan(fitted.calls?.count ?? 0, 200)
        XCTAssertEqual(fitted.calls?.first, oversized.calls?.first)
    }

    func testStaleAfterFifteenMinutes() {
        let snapshot = Self.full(rows: 0)
        XCTAssertFalse(snapshot.isStale(at: snapshot.generatedAt.addingTimeInterval(15 * 60)))
        XCTAssertTrue(snapshot.isStale(at: snapshot.generatedAt.addingTimeInterval(15 * 60 + 1)))
    }

    func testSignedOutCarriesNothing() {
        let snapshot = WatchSnapshot.signedOut(at: Date(timeIntervalSince1970: 0), language: "en")
        XCTAssertFalse(snapshot.signedIn)
        XCTAssertNil(snapshot.workspace)
        XCTAssertNil(snapshot.calls)
        XCTAssertNil(snapshot.conversations)
        XCTAssertNil(snapshot.unreadCount)
    }

    // MARK: - Fixtures

    /// Every string at a realistic worst-case length.
    static func full(rows: Int) -> WatchSnapshot {
        let long = String(repeating: "é", count: WatchSnapshotComposer.previewLimit)
        return WatchSnapshot(
            protocolVersion: WatchSnapshot.currentProtocolVersion,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            language: "fr-CA",
            signedIn: true,
            workspace: .init(id: "ws_1", name: "Plomberie Desrosiers-Lanthier inc."),
            availability: .init(workspaceId: "ws_1", available: true, canToggle: true, note: nil),
            unreadCount: 12,
            calls: (0 ..< rows).map { index in
                .init(
                    id: "call_\(index)_cmabcdefghijklmnop",
                    caller: "Marie-Ève Tremblay-Desrosiers",
                    direction: "Entrant",
                    time: "23 oct. 2026, 14 h 05",
                    relativeTime: "il y a 12 min",
                    occurredAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 60),
                    outcome: "Terminé · Transfert échoué",
                    duration: "12 min 30 s"
                )
            },
            conversations: (0 ..< rows).map { index in
                .init(
                    id: "contact:cmabcdefghijklmnop\(index)",
                    workspaceId: "ws_1",
                    title: "Marie-Ève Tremblay-Desrosiers",
                    preview: "↓ \(long)…",
                    unread: index.isMultiple(of: 2),
                    canReply: true
                )
            }
        )
    }
}

/// The phone's words for the watch: the same mappers the phone's own screens use.
@MainActor
final class WatchSnapshotComposerTests: XCTestCase {
    func testANumberIsMaskedToItsLastFourAndANameIsNot() {
        XCTAssertEqual(WatchMasking.caller("+1 (416) 555-0134"), "••• 0134")
        XCTAssertEqual(WatchMasking.caller("+14165550134"), "••• 0134")
        XCTAssertEqual(WatchMasking.caller("Marie Tremblay"), "Marie Tremblay")
        XCTAssertEqual(WatchMasking.caller("paul@example.com"), "paul@example.com")
        XCTAssertEqual(WatchMasking.caller("911"), "911")
    }

    /// ⛔ A REASON MEANS NO SWITCH, AND THE REASON IS THE PHONE'S OWN SENTENCE.
    func testAvailabilityWithAReasonCannotBeToggled() throws {
        let viewer = try JSONDecoder().decode(
            AvailabilityResponse.self,
            from: Data(#"{"success":true,"availableForCalls":false,"reason":"role"}"#.utf8)
        )
        let mapped = WatchSnapshotComposer.availability(viewer, workspaceId: "ws_1")
        XCTAssertFalse(mapped.canToggle)
        XCTAssertEqual(mapped.note, AvailabilityCopy.reasonRole)

        let member = try JSONDecoder().decode(
            AvailabilityResponse.self,
            from: Data(#"{"success":true,"availableForCalls":true}"#.utf8)
        )
        XCTAssertTrue(WatchSnapshotComposer.availability(member, workspaceId: "ws_1").canToggle)
    }

    /// ⛔ A READ THAT FAILED IS nil ON THE WIRE, NEVER AN EMPTY LIST OR A ZERO.
    func testAFailedReadIsNilNotEmpty() {
        let reads = WatchSnapshotComposer.Reads(
            workspaceId: "ws_1",
            workspaceName: "Acme",
            availability: .failure(.transport("offline")),
            unread: .failure(.transport("offline")),
            conversations: .failure(.transport("offline")),
            calls: .success([])
        )

        let snapshot = WatchSnapshotComposer.compose(reads, at: Date(), language: "en")

        XCTAssertNil(snapshot.availability)
        XCTAssertNil(snapshot.unreadCount)
        XCTAssertNil(snapshot.conversations)
        XCTAssertEqual(snapshot.calls, [])
        XCTAssertEqual(snapshot.workspace?.name, "Acme")
    }
}
