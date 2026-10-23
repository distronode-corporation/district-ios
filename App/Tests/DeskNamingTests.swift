@testable import DistrictAI
import DistrictL10n
import XCTest

/// The product is "Desk" in English and « Comptoir » in French, on every surface (Sean,
/// 2026-10-23). "District Desk" is gone, and its settings are "Desk settings" /
/// « Réglages du comptoir » (Apple's own word for settings).
final class DeskNamingTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    private func english<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.en, body)
    }

    func testTheProductIsDeskInEnglish() {
        english {
            XCTAssertEqual(DeskCopy.title, "Desk")
            XCTAssertEqual(DeskCopy.settingsEyebrow, "Desk")
            XCTAssertEqual(DeskCopy.offTitle, "Desk is off")
            XCTAssertEqual(DeskCopy.settingsTitle, "Desk settings")
            XCTAssertEqual(DeskCopy.offAction, "Desk settings")
            XCTAssertEqual(OverviewCopy.desk, "Desk")
        }
    }

    func testTheProductIsComptoirInFrench() {
        french {
            XCTAssertEqual(DeskCopy.title, "Comptoir")
            XCTAssertEqual(DeskCopy.settingsEyebrow, "Comptoir")
            XCTAssertEqual(DeskCopy.offTitle, "Le comptoir est désactivé")
            XCTAssertEqual(DeskCopy.settingsTitle, "Réglages du comptoir")
            XCTAssertEqual(DeskCopy.offAction, "Réglages du comptoir")
            XCTAssertEqual(OverviewCopy.desk, "Comptoir")
            XCTAssertTrue(DeskCopy.viewerNote.hasPrefix("Le comptoir "))
        }
    }

    /// ⛔ NO SCREEN STRING SAYS "District Desk" OR A BARE "Desk" IN FRENCH. Read from the
    /// generated accessors, which hold every catalog string the app can show.
    func testNoStringNamesDistrictDesk() throws {
        let copy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/L10n/Generated/Copy.swift")
        let lines = try String(contentsOf: copy, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { $0.contains("static var") || $0.contains("static func") || $0.contains("return ") }
        XCTAssertGreaterThan(lines.count, 1000, "the generated copy moved")
        for line in lines {
            XCTAssertFalse(line.contains("District Desk"), line)
            XCTAssertFalse(line.contains("frCA ? \"Desk\""), line)
        }
    }
}
