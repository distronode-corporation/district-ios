@testable import DistrictAI
import DistrictL10n
import XCTest

/// A support request's status badge (3.0.1): the catalog's label in both languages, never the
/// help desk's raw word, and a localized generic label for a status this build does not list.
final class SupportStatusLabelTests: XCTestCase {
    /// What one status reads as, in each language.
    private struct Row {
        let input: String
        let english: String
        let french: String

        init(_ input: String, _ english: String, _ french: String) {
            self.input = input
            self.english = english
            self.french = french
        }
    }

    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    func testEveryListedStatusHasItsLabelInBothLanguages() {
        let expected: [Row] = [
            Row("Received", "Received", "Reçue"),
            Row("Open", "Open", "Ouverte"),
            Row("Reopened", "Open", "Ouverte"),
            Row("To Do", "Open", "Ouverte"),
            Row("Waiting for support", "Waiting for support", "En attente du soutien"),
            Row("Waiting for customer", "Waiting for your reply", "En attente de votre réponse"),
            Row("In Progress", "In progress", "En cours"),
            Row("Work in progress", "In progress", "En cours"),
            Row("Pending", "Pending", "En attente"),
            Row("Escalated", "Escalated", "Transmise à un niveau supérieur"),
            Row("Resolved", "Resolved", "Réglée"),
            Row("Done", "Done", "Terminée"),
            Row("Completed", "Done", "Terminée"),
            Row("Closed", "Closed", "Fermée"),
            Row("Canceled", "Canceled", "Annulée"),
            Row("Cancelled", "Canceled", "Annulée"),
            Row("Declined", "Declined", "Refusée"),
            Row("unknown", "Status unknown", "État inconnu"),
        ]
        for row in expected {
            XCTAssertEqual(SupportStatusLabel.label(row.input, category: "INDETERMINATE"), row.english, row.input)
            XCTAssertEqual(
                french { SupportStatusLabel.label(row.input, category: "INDETERMINATE") },
                row.french,
                row.input
            )
        }
    }

    func testANameIsMatchedTrimmedAndWithoutCase() {
        XCTAssertEqual(SupportStatusLabel.label("  WAITING FOR SUPPORT \n", category: "NEW"), "Waiting for support")
    }

    /// ⛔ THE DESK'S OWN WORD IS NEVER SHOWN: the live workflow is localised, so an unlisted
    /// name reads as its category's label, in the app's language.
    func testAnUnlistedNameReadsAsItsCategory() {
        let cases: [Row] = [
            Row("NEW", "Open", "Ouverte"),
            Row("new", "Open", "Ouverte"),
            Row("INDETERMINATE", "In progress", "En cours"),
            Row("indeterminate", "In progress", "En cours"),
            Row("DONE", "Closed", "Fermée"),
            Row("done", "Closed", "Fermée"),
            Row("PENDING", "Received", "Reçue"),
        ]
        for row in cases {
            XCTAssertEqual(SupportStatusLabel.label("完成", category: row.input), row.english, row.input)
            XCTAssertEqual(french { SupportStatusLabel.label("等待客户", category: row.input) }, row.french, row.input)
        }
    }

    func testAnUnlistedNameInAnUnknownCategoryIsTheGenericLabel() {
        XCTAssertEqual(SupportStatusLabel.label("Triage", category: "SOMETHING_NEW"), "Status unknown")
        XCTAssertEqual(french { SupportStatusLabel.label("Triage", category: "") }, "État inconnu")
    }
}
