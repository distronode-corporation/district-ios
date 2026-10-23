@testable import DistrictAI
import DistrictL10n
import XCTest

/// District HQ's question box has a placeholder of its own (3.0.3 visual walk): it showed
/// "Ask" both as the eyebrow above it and inside it. "Ask" stays the field's title, which
/// VoiceOver reads as its name.
final class HQComposerCopyTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    func test_HQ_PROMPT_1_thePlaceholderIsNotTheLabelInEitherLanguage() {
        XCTAssertEqual(HQCopy.promptPlaceholder, "Type your question…")
        XCTAssertEqual(french { HQCopy.promptPlaceholder }, "Posez votre question…")
        XCTAssertNotEqual(HQCopy.promptPlaceholder, HQCopy.promptLabel)
        XCTAssertNotEqual(french { HQCopy.promptPlaceholder }, french { HQCopy.promptLabel })
    }

    /// ⛔ THE FIELD PASSES ITS OWN PROMPT AND KEEPS THE LABEL AS ITS TITLE. Without a
    /// `prompt:` a `TextField` draws its title as the placeholder, which was the repeat.
    func test_HQ_PROMPT_2_theFieldUsesThePlaceholderAndKeepsTheLabelAsTitle() throws {
        let file = try SourceScan.sourceRoot().appendingPathComponent("Features/HQ/HQView.swift")
        let code = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(
            code.contains("TextField(HQCopy.promptLabel, text: $draft, prompt: Text(HQCopy.promptPlaceholder)"),
            "the question box must name itself with the label and show the placeholder"
        )
        XCTAssertTrue(code.contains("DistrictEyebrow(text: HQCopy.promptLabel)"), "the eyebrow stays")
    }
}
