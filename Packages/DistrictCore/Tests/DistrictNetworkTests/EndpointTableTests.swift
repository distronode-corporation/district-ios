@testable import DistrictNetwork
import Foundation
import XCTest

/// Asserts every endpoint's method, URL and body bytes against a hand-written
/// table.
///
/// ⛔ THE COUNT ASSERTION IS THE POINT OF THE SHAPE. A per-endpoint test file
/// would let a new route ship with no test and a green suite; here the table is
/// compared against ``EndpointID/allCases``, so an endpoint added without a row
/// fails, and a row for an endpoint that no longer exists fails to compile.
final class EndpointTableTests: XCTestCase {
    private let base = URL(string: EndpointTable.host)!

    func testEveryEndpointHasExactlyOneRow() {
        let rows = EndpointTable.all()
        let covered = rows.map(\.id)

        XCTAssertEqual(
            Set(covered).count,
            covered.count,
            "an EndpointID appears twice in EndpointTable"
        )
        XCTAssertEqual(
            Set(covered),
            Set(EndpointID.allCases),
            "EndpointTable and EndpointID disagree: "
                + "missing \(Set(EndpointID.allCases).subtracting(covered).map(\.rawValue).sorted())"
        )
        // ⛔ THIS NUMBER COUNTS WHAT THIS CLIENT CAN ADDRESS; THE TWO IN
        // `EndpointSurfaceTests` COUNT WHAT IT CAN UNDERSTAND, and they move for
        // different reasons. Porting a DTO and a repository moves those two (untyped
        // down, typed up) and adds no row here. A row is added only when a route
        // becomes expressible: a new server route, or a live one this client simply
        // could not ask for (no `EndpointID`, no descriptor, no ``DistrictPaths``
        // constant).
        //
        // ⚠️ A ROUTE MAY ANSWER TO SEVERAL BODIES AND STILL BE ONE ROW. `markAllRead`
        // is a third selector on `messages/mark-read`; `contacts/block` carries
        // block-by-id, block-by-number and unblock as three documents on one row; the
        // scheduling admin RPC carries seventy-five operations whose name travels in
        // the BODY (pinned in `SchedulingAdminOpTests`). The other shapes are pinned
        // in their repository tests, because a duplicate id fails
        // `Set(covered).count == covered.count` above. Conversely one PATH can be two
        // rows: `desk/settings` is GET + PATCH and `desk/logo` is POST + DELETE.
        //
        // ⚠️ THIS FILE AND `EndpointSurfaceTests` CAN DISAGREE ON A DELTA ON PURPOSE.
        // `scheduling/admin/download/{id}` is a 302 and belongs to the redirect list,
        // neither typed nor untyped, so it adds a row here and nothing to typed there.
        //
        // ⚠️ `persona/options` AND `persona/preview-token` ARE CHILDREN OF
        // `workspace/persona`, WHICH IS PATCH-ONLY. A GET on the parent is a 405 and
        // the preview is its own path rather than an action key in the save body, so
        // their rows are written out longhand in `EndpointTable+Persona.swift`: a
        // table built from `DistrictPaths` would assert only that the code equals
        // itself.
        //
        // ⛔ `workspace/numbers/purchase` IS DELIBERATELY ABSENT and must stay that
        // way. It is a setup fee plus a recurring charge for a service consumed in
        // the app, i.e. App Store Guideline 3.1.1, so it gets no `EndpointID`, no
        // path, no descriptor and no row — and `NumberSurfaceTests` asserts its
        // absence so that adding one fails rather than ships.
        //
        // ⚠️ `contacts/block` AND `contacts/blocked` EXIST FOR App Store Guideline 1.2,
        // which requires a binary carrying user-generated content to offer a way to
        // BLOCK the person producing it; callers are those people and inbox threads
        // and transcripts are that content.
        //
        // ⚠️ THE KOTLIN CLIENT'S ROUTE LIST IS NOT A SUPERSET OF THIS ONE. The
        // scheduling routes exist here and not there, so a parity diff between the two
        // expects named routes to be missing on each side rather than the lists to
        // match.
        //
        // ⚠️ IF YOU COUNT ROWS WITH A GREP, EXCLUDE THIS FILE. Spelling the row
        // constructor's name in a comment here makes a `grep -c` over
        // `EndpointTable*.swift` report one more than the real rows, which reads
        // exactly like a duplicate row. The assertions are immune — they compare the
        // built array against `EndpointID.allCases` — but the ad-hoc check a reader
        // reaches for first is not.
        XCTAssertEqual(rows.count, 118)
    }

    func testMethodPathQueryAndBodyForEveryEndpoint() throws {
        for row in EndpointTable.all() {
            XCTAssertEqual(row.descriptor.id, row.id, "\(row.id.rawValue): wrong id on the descriptor")
            XCTAssertEqual(row.descriptor.method, row.method, "\(row.id.rawValue): wrong method")

            let url = ApiURL.build(
                base: base,
                segments: row.descriptor.segments,
                query: row.descriptor.query
            )
            XCTAssertEqual(url?.absoluteString, row.url, "\(row.id.rawValue): wrong URL")

            switch (row.descriptor.body, row.body) {
            case (.none, .none):
                break
            case let (.json(value), .json(expected)):
                let encoded = try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
                XCTAssertEqual(unescapeSlashes(encoded), expected, "\(row.id.rawValue): wrong body")
            // ⛔ THE FIELDS ARE COMPARED PER ROW AND WERE HARD-CODED UNTIL THE DESK
            // LANDED. `messages/media` carries the workspace as a form FIELD;
            // `desk/logo` carries it in the QUERY and sends no fields at all. A
            // hard-coded expectation was true of the only multipart row that existed
            // and would have gone green against the second one having the media
            // route's part list — which is exactly the mistake that leaves the desk
            // route's `requireWorkspaceRole` with null while the URL reads correctly.
            case let (.multipart(part), .multipart(fields, fileName)):
                XCTAssertEqual(part.fields, fields, "\(row.id.rawValue): wrong multipart fields")
                XCTAssertEqual(part.fileName, fileName, "\(row.id.rawValue): wrong multipart filename")
            default:
                XCTFail("\(row.id.rawValue): body kind does not match the table")
            }
        }
    }

    /// ⛔ EVERY DELETE ON THIS API CARRIES QUERY PARAMETERS, AND EXACTLY ONE ALSO
    /// CARRIES A BODY. The routes read `searchParams`; a body would be ignored and the
    /// reads would answer 400, which looks like a broken client rather than the wrong
    /// convention.
    ///
    /// ⛔ THE EXCEPTION IS NAMED RATHER THAN THE RULE RELAXED, AND THAT IS THE WHOLE
    /// POINT OF THE ALLOW-LIST. `DELETE …/numbers/registrations/documents` reads
    /// `bundleId` and `documentId` off `req.json()` and only the workspace off the
    /// query, so it genuinely needs a body. Dropping the `.none` assertion for all
    /// deletes to accommodate it would retire the check for the other four; listing it
    /// by id keeps them held and makes the next such route a deliberate edit here.
    /// ⚠️ THE QUERY ASSERTION STILL APPLIES TO IT, and that half is the one that
    /// matters most: `workspaceId` in the URL is what lets `requireWorkspaceRole` run
    /// before `req.json()` is parsed.
    func testNoDeleteCarriesABodyExceptTheOneThatMust() {
        // ⛔ ONE ENTRY. Adding a second is a decision about a convention, not a fix.
        let bodyBearingDeletes: Set<EndpointID> = [.deleteRegistrationDocument]

        for row in EndpointTable.all() where row.descriptor.method == .delete {
            if !bodyBearingDeletes.contains(row.id) {
                XCTAssertEqual(
                    row.descriptor.body,
                    .none,
                    "\(row.id.rawValue): a DELETE must not carry a body"
                )
            }
            XCTAssertFalse(row.descriptor.query.isEmpty, "\(row.id.rawValue): a DELETE needs its query")
        }

        // ⚠️ ASSERTED POSITIVELY TOO, so the allow-list cannot outlive the reason for it:
        // if that route ever moves its ids into the query, this fails rather than leaving
        // a permanent hole in the rule above.
        let documents = EndpointTable.all().first { $0.id == .deleteRegistrationDocument }
        XCTAssertNotEqual(
            documents?.descriptor.body,
            ApiBody.none,
            "the registration-document delete reads bundleId and documentId off req.json()"
        )
    }

    /// ⚠️ `JSONEncoder` ESCAPES `/` AS `\/` ON LINUX AND NOT ON DARWIN, and both
    /// are valid JSON that decodes identically — so a byte-exact assertion on a
    /// body containing a URL would pass on this runner and fail the day anything
    /// runs on a Mac. The escape is normalised away rather than the URL removed,
    /// because `mediaUrls` carrying the upload route's own URL is the case worth
    /// pinning. ⚠️ It is a real divergence to know about before comparing request
    /// bytes across the two platforms.
    private func unescapeSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    /// ⚠️ A nil query value must never reach the wire as an empty parameter. The
    /// table's URLs pin the resulting strings; this pins the mechanism for the
    /// three descriptors that deliberately carry nil entries.
    func testNilQueryEntriesAreDroppedNotSentEmpty() {
        let usage = DistrictEndpoints.usage(workspaceId: "ws_1")
        XCTAssertEqual(usage.query.count, 3, "the two nil switches are stated explicitly")
        XCTAssertEqual(
            ApiURL.build(base: base, segments: usage.segments, query: usage.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/workspace/usage?workspaceId=ws_1"
        )

        let timeline = DistrictEndpoints.timeline(workspaceId: "ws_1", contactId: nil, address: nil)
        XCTAssertEqual(
            ApiURL.build(base: base, segments: timeline.segments, query: timeline.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/timeline?workspaceId=ws_1",
            "a no-cursor timeline read must be byte-identical to the pre-paging request"
        )

        let overview = DistrictEndpoints.overview(workspaceId: nil)
        XCTAssertEqual(
            ApiURL.build(base: base, segments: overview.segments, query: overview.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/overview"
        )
    }
}
