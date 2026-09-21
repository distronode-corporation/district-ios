@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The fixtures and the one assertion every scheduling-write test is built on.
///
/// ⛔ THE ASSERTION IS ABOUT THE `op` AND THE `params`, WHICH IS THE ONLY PLACE
/// THE ANSWER IS. All 75 scheduling admin ops cross the wire through ONE endpoint
/// as `{workspaceId, op, params}`, so "did the editor send a create or a patch",
/// "did the create carry the fourteen fields it must not" and "was the group
/// delete addressed by `groupId` rather than `group_id`" are questions about the
/// encoded document. The repository names no URL per op and no typed model can be
/// inspected for it.
///
/// ⛔ AND THE BODY IS PARSED, NEVER SUBSTRING-MATCHED. `JSONValue.object(_:)` is
/// backed by a DICTIONARY, so key order is not a promise; a test asserting
/// `contains("\"slug\":\"x\",\"name\"")` would pass or fail on hash seeding.
///
/// ⚠️ IT REUSES `SettingsTransport` rather than declaring a second stub. That type
/// already queues bodies and records requests, which is the whole requirement, and
/// a queue that has run dry answers 500 — so a test that drives one request too
/// many fails on an assertion instead of hanging.
enum SchedulingWritesFixtures {
    static func repository(_ transport: SettingsTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(
            client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            ),
            // ⛔ THE APP'S REPORTER TRAPS IN A DEBUG BUILD, which is what a test run
            // is (see AppContainer). Passing a no-op is what makes the RELEASE
            // behaviour reachable here.
            reportUnknownOp: { _ in }
        )
    }

    /// The success envelope every op answers inside.
    static func ok(_ data: String) -> String {
        #"{"ok":true,"data":\#(data)}"#
    }

    /// The sixteen ops that answer nothing still answer an object. See
    /// ``SchedulingNoContent``.
    static let noContent = #"{"ok":true,"data":{"ok":true}}"#

    /// ⛔ A FAILED OP IS A **200**. Anything asserting a refusal has to send this
    /// shape rather than a 4xx, or it is testing the wrong half of the contract.
    static func failure(_ reason: String) -> String {
        #"{"ok":false,"failure":"\#(reason)","status":503}"#
    }

    static func eventType(
        slug: String = "phone-consultation",
        name: String = "Phone consultation",
        extras: String = ""
    ) -> String {
        ok(#"{"id":"et_1","slug":"\#(slug)","name":"\#(name)","duration_minutes":30\#(extras)}"#)
    }

    static func items(_ rows: String) -> String {
        ok(#"{"items":[\#(rows)]}"#)
    }

    /// Every request this transport recorded, as `(op, params)`.
    static func calls(_ transport: SettingsTransport) -> [(op: String, params: [String: Any])] {
        transport.bodies.compactMap { body in
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = object["op"] as? String,
                  let params = object["params"] as? [String: Any]
            else {
                return nil
            }
            return (op, params)
        }
    }

    static func lastCall(_ transport: SettingsTransport) -> (op: String, params: [String: Any])? {
        calls(transport).last
    }
}

/// ⚠️ A TEST CLASS OF ITS OWN SO THE FIXTURES ABOVE ARE THEMSELVES PINNED. A
/// helper that silently stopped decoding bodies would make every assertion in this
/// suite vacuous — `calls` returns `[]` rather than failing, which is exactly the
/// shape that turns a green suite into no suite at all.
@MainActor
final class SchedulingWritesSupportTests: XCTestCase {
    func testTheCallReaderSeesTheOpAndTheParamsOfEveryRequest() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.noContent])
        let admin = SchedulingWritesFixtures.repository(transport)
        _ = try? await admin.deleteEventType(workspaceId: "ws_1", slug: "phone-consultation")

        let calls = SchedulingWritesFixtures.calls(transport)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.op, "eventTypes.delete")
        XCTAssertEqual(calls.first?.params["slug"] as? String, "phone-consultation")
    }

    /// ⛔ THE ENVELOPE, NOT THE STATUS. A refused op answers HTTP 200 carrying
    /// `{ok:false}`; a fixture that got this wrong would exercise a code path the
    /// production client never takes.
    func testAFailureFixtureIsATwoHundred() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.failure("unavailable")])
        let admin = SchedulingWritesFixtures.repository(transport)
        do {
            _ = try await admin.eventTypeHosts(workspaceId: "ws_1", slug: "s")
            XCTFail("a {ok:false} envelope has to throw")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .failure(.unavailable))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
