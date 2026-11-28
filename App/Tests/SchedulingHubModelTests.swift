@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import XCTest

/// The hub's model: the status read, the poll that must stay silent, the enable and the
/// sentence each of its outcomes leaves, and the hand-off's notices.
///
/// ⚠️ OVER THE SNAPSHOT HARNESS'S CONTAINER, because the model takes an ``AppContainer``
/// and nothing narrower; the replies are the recorded fixtures or a refusal stated here.
final class SchedulingHubModelTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let status = "/api/district/scheduling/status"
    private static let enable = "POST /api/district/scheduling/enable"

    private var kept: AppContainer?

    override func tearDown() async throws {
        kept = nil
        try await super.tearDown()
    }

    private func hub(_ replies: [String: FixtureTransport.Reply]) async throws -> (SchedulingModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        kept = container
        return (SchedulingModel(container: container, workspaceId: Self.workspace), transport)
    }

    // MARK: - The status read

    func testInitialReadFailureIsAFailureNotAnEmptyCard() async throws {
        let (model, _) = try await hub([Self.status: .serverError])
        await model.load()
        guard case .failed = model.state else {
            return XCTFail("a refused status read must draw a failure, got \(model.state)")
        }
    }

    /// ⛔ A POLL SAYS NOTHING: a re-read that fails while provisioning is polled leaves the
    /// screen as it was instead of replacing it with a failure.
    func testFailedPollDrawsNoFailure() async throws {
        let (model, _) = try await hub([Self.status: .serverError])
        await model.load(.poll)
        guard case .loading = model.state else {
            return XCTFail("a failed poll must not change the screen, got \(model.state)")
        }
    }

    func testIsProvisioningOnlyForAProvisioningTenancy() async throws {
        for (fixture, expected) in [
            ("district-scheduling-status-provisioning", true),
            ("district-scheduling-status-ready", false),
            ("district-scheduling-status-error", false),
            ("district-scheduling-status-legacy", false),
        ] {
            let (model, _) = try await hub([Self.status: .fixture(fixture)])
            await model.load()
            XCTAssertEqual(model.isProvisioning, expected, fixture)
        }
    }

    // MARK: - Enable

    /// A provision that went through leaves no notice, and the status is read again.
    func testEnableThatProvisionedLeavesNoNoticeAndReReads() async throws {
        let (model, transport) = try await hub([
            Self.status: .fixture("district-scheduling-status-legacy"),
            Self.enable: .fixture("district-scheduling-enable"),
        ])
        await model.enable()
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(transport.requested.filter { $0.contains("/scheduling/") }, [
            "POST /api/district/scheduling/enable",
            "GET /api/district/scheduling/status",
        ])
        guard case .ready = model.state else {
            return XCTFail("the re-read must land, got \(model.state)")
        }
    }

    /// ⛔ `ok: false` IS A WELL-FORMED ANSWER CARRYING THE PROVISIONER'S SENTENCE, which is
    /// shown as it came.
    func testEnableRefusedByTheProvisionerShowsItsSentence() async throws {
        let refused = FixtureTransport.Reply.json(
            #"{"ok":false,"status":"error","publicHost":"book.example.com","error":"DNS refused (HTTP 403)"}"#
        )
        let (model, _) = try await hub([
            Self.status: .fixture("district-scheduling-status-error"),
            Self.enable: refused,
        ])
        await model.enable()
        XCTAssertEqual(model.notice, "DNS refused (HTTP 403)")
    }

    func testEnableRefusedWithoutAReasonSaysSo() async throws {
        let refused = FixtureTransport.Reply.json(#"{"ok":false,"status":"error","publicHost":null,"error":null}"#)
        let (model, _) = try await hub([
            Self.status: .fixture("district-scheduling-status-error"),
            Self.enable: refused,
        ])
        await model.enable()
        XCTAssertEqual(model.notice, SchedulingCopy.enableFailedFallback)
    }

    func testEnableOutsideTheAllowlistIsNotEligible() async throws {
        let (model, _) = try await hub([
            Self.status: .fixture("district-scheduling-status-legacy"),
            Self.enable: .json(#"{"error":"not_eligible"}"#, status: 403),
        ])
        await model.enable()
        XCTAssertEqual(model.notice, SchedulingCopy.notEligible)
    }

    func testEnableTooOftenIsTooManyAttempts() async throws {
        let (model, _) = try await hub([
            Self.status: .fixture("district-scheduling-status-legacy"),
            Self.enable: .json(#"{"error":"rate_limited"}"#, status: 429),
        ])
        await model.enable()
        XCTAssertEqual(model.notice, SchedulingCopy.tooManyAttempts)
    }

    /// Any other refusal is the ordinary failure sentence, and still re-reads.
    func testEnableServerErrorIsTheOrdinaryFailureSentence() async throws {
        let (model, transport) = try await hub([
            Self.status: .fixture("district-scheduling-status-legacy"),
            Self.enable: .serverError,
        ])
        await model.enable()
        let notice = try XCTUnwrap(model.notice)
        XCTAssertFalse(notice.isEmpty)
        XCTAssertNotEqual(notice, SchedulingCopy.notEligible)
        XCTAssertNotEqual(notice, SchedulingCopy.tooManyAttempts)
        XCTAssertEqual(
            transport.requested.filter { $0.contains("/scheduling/") }.last,
            "GET /api/district/scheduling/status"
        )
    }

    func testDismissNoticeClearsIt() async throws {
        let (model, _) = try await hub([
            Self.status: .fixture("district-scheduling-status-legacy"),
            Self.enable: .json(#"{"error":"not_eligible"}"#, status: 403),
        ])
        await model.enable()
        XCTAssertNotNil(model.notice)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    // MARK: - Hand-off notices

    func testHandOffNoticeForEachFailure() {
        XCTAssertEqual(
            SchedulingModel.handOffNotice(for: .nonceRequired(message: "Update District to continue.")),
            "Update District to continue."
        )
        XCTAssertEqual(
            SchedulingModel.handOffNotice(for: .nonceRequired(message: nil)),
            SchedulingCopy.updateToOpenWebsite
        )
        XCTAssertEqual(SchedulingModel.handOffNotice(for: .invalidNonce), SchedulingCopy.handOffFailed)
        XCTAssertEqual(
            SchedulingModel.handOffNotice(for: .api(.http(status: 409, message: nil))),
            SchedulingCopy.notReadyYet
        )
        let other = SchedulingModel.handOffNotice(for: .api(.http(status: 500, message: nil)))
        XCTAssertFalse(other.isEmpty)
        XCTAssertNotEqual(other, SchedulingCopy.notReadyYet)
    }

    /// ⚠️ ONLY TWO OUTCOMES SPEAK: a refusal and a leg 1 that never called back. A tap that
    /// found a hand-off running, or a browser closed on purpose, says nothing.
    func testHandOffNoticeForEachOutcome() {
        XCTAssertEqual(SchedulingModel.handOffNotice(for: .noCallback), SchedulingCopy.handOffNoCallback)
        XCTAssertEqual(SchedulingModel.handOffNotice(for: .failed(.invalidNonce)), SchedulingCopy.handOffFailed)
        XCTAssertNil(SchedulingModel.handOffNotice(for: .alreadyPending))
        XCTAssertNil(SchedulingModel.handOffNotice(for: .abandoned))
    }
}
