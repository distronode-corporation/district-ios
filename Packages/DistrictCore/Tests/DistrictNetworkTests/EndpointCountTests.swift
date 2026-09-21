import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// The counter bookkeeping: how many endpoints exist, and how they partition.
///
/// ⛔ ITS OWN FILE BECAUSE OF SwiftLint's 500-LINE `file_length`, and because the
/// seam is real rather than arbitrary. `EndpointSurfaceTests.swift` asserts what this
/// client must NOT be able to ask for — absences, each pinned by walking the
/// expressible surface. This one asserts how many things it CAN ask for and that the
/// three classification lists partition them exactly. The two answer different
/// questions and move for different reasons: the negative tests change when a refusal
/// changes, these change whenever a route is added.
///
/// ⚠️ RE-DERIVE EVERY NUMBER BELOW BY COUNTING THE LIVE LISTS, NEVER BY ADDING A DELTA
/// TO A NUMBER QUOTED IN A COMMENT. Two branches that each edit these assertions
/// against their own base compose into a figure neither of them wrote, and a delta
/// from a branch is only true of that branch.
extension EndpointSurfaceTests {
    /// ⛔ THE THREE CLASSIFICATION LISTS MUST PARTITION THE SURFACE. Without this,
    /// an endpoint added later defaults to "not in any list" and the
    /// `UNTYPED_ENDPOINTS` burn-down quietly stops being the truth.
    func testTheClassificationListsPartitionEveryEndpoint() {
        let untyped = UntypedEndpoints.all
        let typed = TypedEndpoints.all
        let redirect = RedirectEndpoints.all

        XCTAssertTrue(untyped.isDisjoint(with: typed))
        XCTAssertTrue(untyped.isDisjoint(with: redirect))
        XCTAssertTrue(typed.isDisjoint(with: redirect))
        XCTAssertEqual(untyped.union(typed).union(redirect), Set(EndpointID.allCases))

        // The burn-down's current position, stated so a DTO landing without its
        // list entry removed is a failing test rather than a stale comment.
        //
        // ⛔ AN ENDPOINT MOVES FROM UNTYPED TO TYPED WHEN A REPOSITORY DECODES IT, NOT
        // WHEN A TYPE EXISTS. A DTO can be proven by the contract gate while nothing in
        // `DistrictData` decodes it, and until then the route answers bytes on every
        // path a screen can reach — which is the ⛔ at the top of `UntypedEndpoints`.
        //
        // ⚠️ THE PARTITION FIXES THE TOTAL TO `EndpointID.allCases`, NOT TO A NUMBER. A
        // route that lands typed from its first commit (descriptor, DTO and repository
        // together) never visits the untyped list, so the TOTAL moves rather than the
        // two lists moving against each other. So does a route that was already live
        // but unreachable (no `EndpointID`, no descriptor, no constant): being untyped
        // requires being askable first. Read the total off `EndpointTableTests`, which
        // asserts it directly.
        //
        // ⚠️ SIZE A BURN-DOWN BY ENDPOINTS, NEVER BY FIXTURES. A fixture is a body, not
        // a route: the messaging read and its credential probe answer two bodies each,
        // `hqPrompt` and `campaignStatus` two, `stripeBilling` three. Counting fixtures
        // would claim endpoints that do not exist.
        //
        // ⛔ A ROUTE WITH NO CONTRACT FIXTURE MUST NOT MOVE
        // `ContractManifest.expectedFixtureCount`. The corpus mirrors the Kotlin
        // client, so a surface that client lacks (search, support, the desk, call
        // handling, the hang-up, blocking) arrives with no fixture, and the count is
        // asserted EXACTLY against the files on disk. Its wire shape is pinned by the
        // byte-exact rows in `EndpointTable` instead.
        //
        // ⚠️ `calls/{id}/hangup` EXISTS FOR A REASON NO OTHER ENTRY SHARES. Every other
        // route here lets a screen understand an answer; this one exists because
        // `Room.disconnect()` is not a hang-up, and a call the operator ended goes on
        // being billed at the carrier until the server ends the leg.
        //
        // ⛔ `workspace/numbers/purchase` IS NOT ON ANY LIST AND NEVER WILL BE: App Store
        // Guideline 3.1.1. Its absence is asserted in `NumberSurfaceTests` rather than
        // merely observed.
        XCTAssertEqual(untyped.count, 2)
        // ⚠️ "TYPED" IS NARROWER FOR THE SCHEDULING ADMIN RPC THAN ANYWHERE ELSE.
        // `SchedulingAdminRepository.perform` is generic and decodes whatever type the
        // CALLER names, so what is fixed is the ENVELOPE rather than the payload. See
        // `TypedEndpoints.schedulingAdmin`.
        XCTAssertEqual(typed.count, 114)
        // ⛔ A REDIRECT ENDPOINT ANSWERS A 302 TO A PRESIGNED OBJECT, and following it
        // would download the object (for `scheduling/admin/download/{id}`, a
        // multi-hundred-megabyte video) to learn its address.
        // ⚠️ A 302 IS NOT ENOUGH TO JOIN THIS LIST. `scheduling/sso` answers one too
        // and is deliberately absent — its `Location` is a single-use sign-in
        // credential rather than an object, so it has no `EndpointID` at all.
        XCTAssertEqual(redirect.count, 2)
    }
}
