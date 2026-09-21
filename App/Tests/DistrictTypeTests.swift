@testable import DistrictAI
import SwiftUI
import XCTest

/// ⛔ THE GUARD ON THE ANCHOR, WHICH IS THE ONE THING A COMPILER CANNOT CHECK HERE.
/// `DistrictFont` requires a `style`, so no token can be written without one — but a
/// fifteenth token could be added as a raw `Font.system(...)`, which compiles, renders
/// identically at the default text size, and is then the single label on the app that
/// never grows. Nothing would fail. This pins the COUNT of `allScalable`, so a token
/// missing from that list is a red test rather than a silent hole.
///
/// ⚠️ Swift cannot enumerate a caseless enum's static members — `Mirror` reflects
/// instances — so the list is hand-maintained and this test is what keeps it honest.
final class DistrictTypeTests: XCTestCase {
    func testEveryScalableTokenIsAccountedFor() {
        XCTAssertEqual(
            DistrictType.allScalable.count, 14,
            "a token was added or removed without updating DistrictType.allScalable, "
                + "so it either does not scale or is no longer covered here"
        )
    }

    func testNoTokenIsZeroOrNegativelySized() {
        for (name, font) in DistrictType.allScalable {
            XCTAssertGreaterThan(font.size, 0, "\(name) has a nonsensical base size")
        }
    }

    /// ⚠️ THE ANCHOR IS NOT FREE-CHOICE: iOS scales each style by its own curve, so a
    /// caption anchored to `.body` grows on the wrong one. These pin the four that
    /// carry the most text, so a well-meaning "tidy-up" to one shared anchor fails.
    func testTheAnchorsMatchWhatEachTokenIsFor() {
        let expected: [String: Font.TextStyle] = [
            "body": .body,
            "caption": .caption,
            "labelSmall": .caption2,
            "display": .largeTitle,
        ]
        for (name, style) in expected {
            let token = DistrictType.allScalable.first { $0.name == name }
            XCTAssertEqual(token?.font.style, style, "\(name) is anchored to the wrong text style")
        }
    }

    /// ⛔ SIZES AND WEIGHTS DID NOT MOVE. The whole argument for the descriptor over
    /// semantic styles (`Font.system(.body)`) was that Apple's sizes would replace
    /// ours and shift every screen at the DEFAULT text size. This pins that they did not.
    func testTheScaleItselfIsUnchanged() {
        XCTAssertEqual(DistrictType.body.size, 16)
        XCTAssertEqual(DistrictType.body.weight, .regular)
        XCTAssertEqual(DistrictType.display.size, 36)
        XCTAssertEqual(DistrictType.display.weight, .bold)
        XCTAssertEqual(DistrictType.eyebrow.size, 10)
        XCTAssertEqual(DistrictType.eyebrow.design, .monospaced)
    }
}
