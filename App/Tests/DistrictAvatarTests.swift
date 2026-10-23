@testable import DistrictAI
import XCTest

/// The avatar's fallback, matched to District AI for Mac (`DistrictAvatarTests` there): a
/// name gives up to two initials, a number or no name gives the person glyph (nil).
@MainActor
final class DistrictAvatarTests: XCTestCase {
    func test_IOS_AVATAR_1_aRealNameGivesUpToTwoInitials() {
        XCTAssertEqual(DistrictAvatar.initials(for: "Maya Okafor"), "MO")
        XCTAssertEqual(DistrictAvatar.initials(for: "jordan tremblay"), "JT")
        XCTAssertEqual(DistrictAvatar.initials(for: "Distronode Corporation Canada"), "DC")
        XCTAssertEqual(DistrictAvatar.initials(for: "reviewer@example.com"), "R")
        XCTAssertEqual(DistrictAvatar.initials(for: "  Anita  "), "A")
        XCTAssertEqual(DistrictAvatar.initials(for: "Élodie Côté"), "ÉC")
    }

    /// ⛔ A NUMBER IS NOT A NAME: it drew "+", and no name drew "·" (3.0.3 visual walk).
    func test_IOS_AVATAR_2_aPhoneNumberOrNoNameGivesTheGlyph() {
        XCTAssertNil(DistrictAvatar.initials(for: "+14165558888"))
        XCTAssertNil(DistrictAvatar.initials(for: "+1 416 555 1234"))
        XCTAssertNil(DistrictAvatar.initials(for: ""))
        XCTAssertNil(DistrictAvatar.initials(for: "   "))
        XCTAssertNil(DistrictAvatar.initials(for: "·"))
    }

    /// ⚠️ WORDS THAT DO NOT START WITH A LETTER ARE SKIPPED, not turned into a symbol.
    func test_IOS_AVATAR_3_nonLetterWordsAreSkipped() {
        XCTAssertEqual(DistrictAvatar.initials(for: "+1 John Smith"), "JS")
        XCTAssertEqual(DistrictAvatar.initials(for: "(416) Front desk"), "FD")
    }
}
