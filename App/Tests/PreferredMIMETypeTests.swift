@testable import DistrictAI
import PhotosUI
import SwiftUI
import XCTest

/// The one MIME choice every photo picker in the app uploads with.
final class PreferredMIMETypeTests: XCTestCase {
    private let allowed: Set<String> = ["image/jpeg", "image/png"]

    /// ⚠️ THE FIRST TYPE THE ROUTE ACCEPTS WINS, even when the item lists another first.
    func testTheFirstAcceptedDeclaredTypeWins() {
        let type = PhotosPickerItem.preferredMIMEType(declared: ["image/heic", "image/jpeg"], allowed: allowed)

        XCTAssertEqual(type, "image/jpeg")
    }

    /// ⚠️ NOTHING ACCEPTED: the item's own first type, so the route's limits refuse it
    /// by name rather than this inventing one.
    func testNothingAcceptedFallsBackToTheFirstDeclaredType() {
        let type = PhotosPickerItem.preferredMIMEType(declared: ["image/heic", "image/tiff"], allowed: allowed)

        XCTAssertEqual(type, "image/heic")
    }

    func testNothingDeclaredIsADeliberatelyUnacceptableType() {
        let type = PhotosPickerItem.preferredMIMEType(declared: [], allowed: allowed)

        XCTAssertEqual(type, "application/octet-stream")
        XCTAssertFalse(allowed.contains(type))
    }
}
