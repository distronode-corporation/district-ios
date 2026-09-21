import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the three workspace-settings writes a phone may
/// make.
///
/// ⛔ THE INTERESTING PROPERTY OF THESE THREE FIXTURES IS WHAT THEY DO NOT
/// CONTAIN, WHICH IS WHY THEY GET A FILE RATHER THAN A LINE. Each body is a bare
/// `{"success": true}`: no echoed config, no updated row, nothing a client could
/// adopt. That absence is the reason a caller has to re-read
/// `workspace/config` after every save, and it is load-bearing on this surface in
/// particular, because two of the three routes REPLACE their stored value
/// wholesale and the next save is built on whatever the client believes the
/// current state to be.
///
/// ⛔ SO THIS IS ALSO THE PLACE THE RE-READ CAN EVENTUALLY BE RETIRED FROM. The
/// strict gate's re-encode walk fails on an ADDED key exactly as loudly as on a
/// dropped one, so the day any of these routes starts echoing the row it wrote,
/// that one fixture reds. Nothing else on either client watches for it.
///
/// ⚠️ THE FOURTH SIBLING IS GATED ELSEWHERE. `district-directory-patch.json` is
/// the same route family and the same body, and it sits with the contacts group in
/// `ImplementedFixtures` because it writes the workspace CALL directory, i.e.
/// staff phone numbers. It is asserted here alongside the other three anyway,
/// since the claim being made is about all four.
final class WorkspaceWriteContractTests: XCTestCase {
    /// The three fixtures this batch ported, each affirming its envelope and
    /// carrying nothing else.
    ///
    /// ⚠️ RUN THROUGH THE GATE INDIVIDUALLY RATHER THAN COMPARED TO ONE ANOTHER.
    /// They happen to be byte-identical today, and an assertion to that effect
    /// would be a claim about three routes that are free to diverge: a shared type
    /// is safe here only because each fixture is pinned SEPARATELY, so the day one
    /// of them grows a field, that one fails and the others do not.
    func testTheSettingsWritesAreBareAcknowledgements() throws {
        let fixtures = [
            "district-persona-patch.json",
            "district-tools-patch.json",
            "district-routing-patch.json",
            "district-directory-patch.json",
        ]
        for name in fixtures {
            let response = try StrictDecodeVerifier.verify(fixture: name, as: SuccessResponse.self)
            XCTAssertTrue(response.success, name)
        }
    }

    /// ⛔ ONE KEY, ASSERTED ON THE RAW BYTES, BECAUSE THAT IS THE CLAIM THE
    /// RE-READ RESTS ON. The gate already proves the DTO's key set matches the
    /// fixture's, but it proves that against ``SuccessResponse`` rather than
    /// against the number one, and a reader checking whether a save echoes its
    /// config should not have to infer it from a type declared in another file.
    /// ⚠️ `success` is also asserted to be exactly the key present, so a
    /// regeneration that renamed it to `ok` (which the scheduling enable route
    /// really does spell that way) fails here rather than decoding to false.
    func testNoSettingsWriteEchoesTheConfigItWrote() throws {
        let fixtures = [
            "district-persona-patch.json",
            "district-tools-patch.json",
            "district-routing-patch.json",
            "district-directory-patch.json",
        ]
        for name in fixtures {
            let raw = try ContractFixtures.read(name)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: raw) as? [String: Any],
                "\(name) is not a JSON object"
            )
            XCTAssertEqual(Set(object.keys), ["success"], "\(name) carries more than the flag")
        }
    }
}
