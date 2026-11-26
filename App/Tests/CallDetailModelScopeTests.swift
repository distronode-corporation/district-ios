@testable import DistrictAI
import DistrictModel
import XCTest

/// One call's detail read and its on-demand transcript, against the service's recorded
/// answers and its refusals.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER: nothing here draws.
final class CallDetailModelScopeTests: ScreenSnapshotTestCase {
    private static let detail = "/api/district/calls/call_contract_answered"
    private static let transcript = "/api/district/calls/call_contract_answered/transcript"

    private typealias Built = (CallDetailModel, FixtureTransport)

    private func callModel(_ replies: [String: FixtureTransport.Reply]) async throws -> Built {
        var all: [String: FixtureTransport.Reply] = [Self.detail: .fixture("district-call-detail")]
        all.merge(replies) { $1 }
        let transport = FixtureTransport(all)
        let model = try await CallDetailModel(
            container: container(transport),
            workspaceId: "ws-contract-test",
            callId: "call_contract_answered"
        )
        return (model, transport)
    }

    func testATranscriptIsReadOnceOnDemand() async throws {
        let (model, transport) = try await callModel([Self.transcript: .fixture("district-call-transcript")])
        await model.loadTranscript()
        XCTAssertFalse(transport.requested.contains("GET \(Self.transcript)"), "nothing is read before the call itself")

        await model.load()
        XCTAssertNil(model.live, "a completed call has no live transcript")
        await model.loadTranscript()
        await model.loadTranscript()

        guard case let .loaded(text) = model.transcript else {
            return XCTFail("expected a transcript, got \(model.transcript)")
        }
        XCTAssertTrue(text.hasPrefix("Agent: Good afternoon."))
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.transcript)" }.count, 1)
    }

    /// ⚠️ THE SERVICE SENDS "" FOR NO TRANSCRIPT, so blank text is absent, not shown empty.
    func testABlankTranscriptIsAbsent() async throws {
        let (model, _) = try await callModel([Self.transcript: .json(#"{"success":true,"transcript":"  \n "}"#)])
        await model.load()
        await model.loadTranscript()
        guard case .absent = model.transcript else {
            return XCTFail("expected absent, got \(model.transcript)")
        }
    }

    func testARefusedTranscriptIsAFailure() async throws {
        let (model, _) = try await callModel([Self.transcript: .refused(500)])
        await model.load()
        await model.loadTranscript()
        guard case .failed = model.transcript else {
            return XCTFail("expected failed, got \(model.transcript)")
        }
    }

    func testAMissingCallIsNotAvailableWithoutARetry() async throws {
        let (model, _) = try await callModel([Self.detail: .refused(404, "Call not found")])
        await model.load()
        guard case let .failed(failure) = model.state, case .none = failure.action else {
            return XCTFail("expected an unretryable failure, got \(model.state)")
        }
        XCTAssertEqual(failure.message, CallsCopy.callNotAvailable)
    }
}
