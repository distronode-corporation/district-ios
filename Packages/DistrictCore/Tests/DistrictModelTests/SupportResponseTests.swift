import DistrictModel
import Foundation
import XCTest

/// The support DTOs' own decisions: the resolved-bucket predicate, the message
/// role, and the three-way filing outcome.
///
/// ⚠️ THESE SHAPES HAVE NO CONTRACT FIXTURE BEHIND THEM, which is a property of the
/// corpus rather than a lowered bar: the contract corpus mirrors the Kotlin
/// client and that client has no support surface. So this file and
/// `SupportRepositoryTests` are what pin them, alongside the route source.
final class SupportResponseTests: XCTestCase {
    // MARK: - The resolved bucket

    /// ⛔ CASE-INSENSITIVE, AND THAT IS NOT TIDINESS. The server unified two
    /// vocabularies into `DONE` — the core issue API reports a lowercase key, the
    /// servicedeskapi an uppercase one — and older production rows still hold
    /// lowercase `done`. A literal `==` against either spelling is silently wrong
    /// for half the corpus, and the bug it produces is a dashboard offering
    /// "Close" on requests that are already closed, forever.
    func testTheResolvedBucketMatchesBothSpellings() {
        XCTAssertTrue(SupportStatusCategory.isResolved("DONE"))
        XCTAssertTrue(SupportStatusCategory.isResolved("done"))
        XCTAssertTrue(SupportStatusCategory.isResolved("Done"))
        XCTAssertEqual(SupportStatusCategory.resolved, "DONE", "the canonical spelling the server stores")
    }

    /// ⚠️ EVERY OTHER BUCKET IS UNRESOLVED, INCLUDING THE SYNTHETIC `PENDING` an
    /// unfiled request carries. A request we have not managed to file yet is
    /// emphatically not finished.
    func testEveryOtherBucketIsUnresolved() {
        for category in ["NEW", "INDETERMINATE", "PENDING", "", "DONE_SOON"] {
            XCTAssertFalse(SupportStatusCategory.isResolved(category), "\(category) is not resolved")
        }
    }

    func testASummaryAndADetailAgreeAboutBeingResolved() throws {
        let resolved = try decodeSummary(statusCategory: "done")
        let open = try decodeSummary(statusCategory: "INDETERMINATE")
        XCTAssertTrue(resolved.isResolved)
        XCTAssertFalse(open.isResolved)

        let detail = try decodeDetail(statusCategory: "DONE")
        XCTAssertTrue(detail.isResolved)
    }

    // MARK: - Who wrote a message

    /// ⛔ nil MEANS "A ROLE THIS BUILD DOES NOT KNOW" AND MUST NOT COLLAPSE ONTO
    /// EITHER SIDE. Defaulting it to `customer` would draw a message the workspace
    /// did not write as though they had; defaulting it to `agent` would put words in
    /// Distronode's mouth. The caller lays an unknown role out neutrally and shows
    /// `author`, which the server computed and is right about either way.
    func testAnUnknownMessageRoleIsNilRatherThanEitherSide() throws {
        XCTAssertEqual(try decodeMessage(role: "agent").knownRole, .agent)
        XCTAssertEqual(try decodeMessage(role: "customer").knownRole, .customer)
        XCTAssertNil(try decodeMessage(role: "system").knownRole)
        XCTAssertNil(try decodeMessage(role: "").knownRole)
    }

    /// ⚠️ `author` IS A SERVER-SIDE SUBSTITUTION AND IS CARRIED VERBATIM. The route
    /// answers "Distronode Support" or "You" and never passes an agent's real
    /// display name through, so this is the string to show.
    func testTheAuthorLineIsCarriedRatherThanDerived() throws {
        XCTAssertEqual(try decodeMessage(role: "agent").author, "Distronode Support")
    }

    // MARK: - What happened to a new request

    /// ⛔ THREE OUTCOMES, ALL OF THEM A 200 WITH `success: true`, AND NONE OF THEM A
    /// FAILURE. `deduplicated` is the one that reads like an error: it means the
    /// idempotency key did its job, and wording it as a fault is what invites a
    /// third attempt into a human's queue.
    func testTheThreeFilingBranchesStayDistinct() throws {
        XCTAssertEqual(try decodeCreate(#"{"success":true,"issueKey":"DA-42"}"#).filing, .filed(issueKey: "DA-42"))
        XCTAssertEqual(try decodeCreate(#"{"success":true,"deduplicated":true}"#).filing, .deduplicated)
        XCTAssertEqual(try decodeCreate(#"{"success":true,"pending":true}"#).filing, .pending)
    }

    /// ⛔ THE FALL-THROUGH IS `pending` AND THAT IS A CHOICE ABOUT THE SAFE
    /// DIRECTION. Every branch of this route that answers 200 has already written
    /// the claim row, so "we have your request" is still true on a body this build
    /// cannot classify; reporting drift as a failure would tell a customer their
    /// request was lost when it was not, and they would send it again.
    func testAnUnclassifiableBodyReadsAsPending() throws {
        XCTAssertEqual(try decodeCreate(#"{"success":true}"#).filing, .pending)
        XCTAssertEqual(try decodeCreate(#"{"success":true,"issueKey":""}"#).filing, .pending)
        XCTAssertEqual(try decodeCreate(#"{"success":true,"deduplicated":false}"#).filing, .pending)
    }

    /// ⚠️ THE ORDERING IS EXPLICIT SO THAT "THE SERVER NEVER SENDS TWO AT ONCE" IS
    /// AN OBSERVATION RATHER THAN A LOAD-BEARING ASSUMPTION: a key wins over a
    /// deduplication flag.
    func testAKeyWinsOverTheDeduplicationFlag() throws {
        let both = try decodeCreate(#"{"success":true,"issueKey":"DA-42","deduplicated":true}"#)
        XCTAssertEqual(both.filing, .filed(issueKey: "DA-42"))
    }

    // MARK: - Decoding

    /// ⛔ A NULL `issueKey` IS A STATE RATHER THAN AN ABSENCE, and it arrives as an
    /// explicit null because the route serialises the summary whole. A request
    /// between its local claim and the Atlassian call is a real row the customer can
    /// see.
    func testAnUnfiledSummaryDecodesItsNullKey() throws {
        let unfiled = try decodeSummary(issueKey: nil, filed: false)
        XCTAssertNil(unfiled.issueKey)
        XCTAssertFalse(unfiled.filed)
        XCTAssertEqual(unfiled.id, "st_1", "the row id is what a list keys on")
    }

    // MARK: - Helpers

    private func decodeSummary(
        issueKey: String? = "DA-42",
        statusCategory: String = "NEW",
        filed: Bool = true
    ) throws -> SupportRequestSummary {
        let key = issueKey.map { #""\#($0)""# } ?? "null"
        let json = #"""
        {"issueKey":\#(key),"id":"st_1","subject":"Outbound calls failing",
         "statusName":"Waiting for support","statusCategory":"\#(statusCategory)",
         "createdAt":"2026-09-06T09:41:00.000Z","updatedAt":"2026-09-06T10:02:00.000Z",
         "filed":\#(filed),"source":"workspace","region":"us"}
        """#
        return try JSONDecoder().decode(SupportRequestSummary.self, from: Data(json.utf8))
    }

    private func decodeDetail(statusCategory: String) throws -> SupportRequestDetail {
        let json = #"""
        {"issueKey":"DA-42","id":"st_1","subject":"Outbound calls failing",
         "statusName":"Resolved","statusCategory":"\#(statusCategory)",
         "createdAt":"2026-09-06T09:41:00.000Z","updatedAt":"2026-09-06T10:02:00.000Z",
         "filed":true,"source":"workspace","region":"us","closeable":false,"messages":[]}
        """#
        return try JSONDecoder().decode(SupportRequestDetail.self, from: Data(json.utf8))
    }

    private func decodeMessage(role: String) throws -> SupportMessage {
        let author = role == "agent" ? "Distronode Support" : "You"
        let json = #"""
        {"id":"c_1","role":"\#(role)","author":"\#(author)","body":"Looking into it now.",
         "createdAt":"2026-09-06T10:02:00.000Z"}
        """#
        return try JSONDecoder().decode(SupportMessage.self, from: Data(json.utf8))
    }

    private func decodeCreate(_ json: String) throws -> SupportRequestCreateResponse {
        try JSONDecoder().decode(SupportRequestCreateResponse.self, from: Data(json.utf8))
    }
}
