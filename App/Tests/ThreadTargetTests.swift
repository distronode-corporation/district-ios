@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// Which thread a route's key selects, for reading and for `mark-read`.
///
/// ⛔ THESE ARE THE RULES PRODUCTION RUNS. A list row and a search hit both open a
/// thread through ``ThreadTarget/selector(threadKey:)``; the package's former
/// `ThreadSelector.forConversation`/`forSearchHit` pinned the same rules on code no
/// screen called, so they were deleted and their cases moved here.
final class ThreadTargetTests: XCTestCase {
    /// ⛔ PREFER THE CONTACT ID WHENEVER THERE IS ONE. It is exact and it survives an
    /// address changing.
    func testAContactKeySelectsOnTheContactId() {
        XCTAssertEqual(ThreadTarget.selector(threadKey: "contact:c_1"), .contact("c_1"))
    }

    /// ⛔ AND AN ADDRESS KEY SELECTS ON ITS SUFFIX, NEVER ON THE WHOLE KEY.
    /// `addr:14165550134` sent whole as the address parameter matches no message row,
    /// so a `mark-read` would succeed against nothing and the badge would never clear.
    func testAnAddressKeySelectsOnTheAddressNotTheWholeKey() {
        let selector = ThreadTarget.selector(threadKey: "addr:14165550134")

        XCTAssertEqual(selector, .address("14165550134"))
        XCTAssertNotEqual(selector, .address("addr:14165550134"))
    }

    /// An email-keyed thread (a search hit on an unresolved sender) works the same way.
    func testAnEmailAddressKeySelectsOnTheAddress() {
        XCTAssertEqual(ThreadTarget.selector(threadKey: "addr:ada@contract.test"), .address("ada@contract.test"))
    }

    /// ⚠️ A PRESENT-BUT-BLANK ID OR ADDRESS IS NOT ONE. It would reach the route as
    /// `contactId=`, a different instruction from omitting it.
    func testABlankContactOrAddressSelectsNothing() {
        XCTAssertNil(ThreadTarget.selector(threadKey: "contact:"))
        XCTAssertNil(ThreadTarget.selector(threadKey: "addr:"))
    }

    /// ⛔ A KEY IN NEITHER FORM IS A MALFORMED DESTINATION, not a guess at an address.
    func testAKeyInNeitherFormSelectsNothing() {
        XCTAssertNil(ThreadTarget.selector(threadKey: "+14165550134"))
        XCTAssertNil(ThreadTarget.selector(threadKey: ""))
    }

    func testTheTargetCarriesTheSelectorItsKeyImplies() {
        let target = ThreadTarget(workspaceId: "ws_1", threadKey: "contact:c_1", replyTargets: [])

        XCTAssertEqual(target.selector, .contact("c_1"))
        XCTAssertNil(target.replyTarget, "no reply targets means no reply box")
    }
}
