@testable import DistrictAI
import DistrictData
import XCTest

/// What a thread's Block blocks: ``ThreadModerationModifier/subject(threadKey:)`` reads the
/// thread key and names a contact or a raw number, and names nothing for a key it cannot read,
/// so a malformed key blocks nobody rather than the wrong person.
@MainActor
final class ThreadModerationMarginTests: XCTestCase {
    func testAContactKeyBlocksThatContact() {
        XCTAssertEqual(ThreadModerationModifier.subject(threadKey: "contact:c_42"), .contact("c_42"))
    }

    func testAnAddressKeyBlocksTheRawNumber() {
        XCTAssertEqual(
            ThreadModerationModifier.subject(threadKey: "addr:+14165550123"),
            .phoneNumber("+14165550123")
        )
    }

    /// A prefix with nothing after it, an unknown prefix, a bare id, a key in the wrong case and
    /// an empty key all name nobody.
    func testAKeyThatNamesNobodyBlocksNobody() {
        for key in ["contact:", "addr:", "", "c_42", "Contact:c_42", "phone:+14165550123", " contact:c_42"] {
            XCTAssertNil(ThreadModerationModifier.subject(threadKey: key), "\(key) should block nobody")
        }
    }

    /// Only the prefix is read: what follows is kept as it is, colons included, for the server
    /// to resolve.
    func testOnlyThePrefixIsStripped() {
        XCTAssertEqual(ThreadModerationModifier.subject(threadKey: "contact:contact:x"), .contact("contact:x"))
        XCTAssertEqual(ThreadModerationModifier.subject(threadKey: "addr: 416 555"), .phoneNumber(" 416 555"))
    }
}
