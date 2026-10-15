@testable import DistrictAI
import DistrictL10n
import XCTest

/// The 3.0.1 visual-QA rules for the reply composer and the Numbers tabs that a unit test can
/// hold: read from the source, as `A11yImageTests` reads it, because SwiftUI offers no view
/// tree to inspect. The look itself is proved by the capture walk's before and after frames.
final class ComposerAndNumbersTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let file = try SourceScan.sourceRoot().appendingPathComponent(relative)
        return try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
    }

    /// ⛔ SEND IS COMMAND-RETURN ON A HARDWARE KEYBOARD, NEVER RETURN: a reply is billed, and
    /// Return in the field is a new line. So the composer has no `onSubmit`, and Send is not
    /// the default action.
    func test_VQA_01_returnIsANewLineAndCommandReturnSends() throws {
        let code = try source("Features/Inbox/Thread/ComposerBar.swift")
        XCTAssertTrue(code.contains(".keyboardShortcut(.return, modifiers: .command)"))
        XCTAssertFalse(code.contains(".defaultAction"))
        XCTAssertFalse(code.contains(".onSubmit"))
        XCTAssertTrue(code.contains("TextField(InboxCopy.reply, text: text, axis: .vertical)"))
    }

    /// ⚠️ THE "Reply" EYEBROW IS GONE: the field's title is its placeholder and its spoken name.
    func test_VQA_02_theReplyFieldHasNoEyebrow() throws {
        let code = try source("Features/Inbox/Thread/ComposerBar.swift")
        XCTAssertFalse(code.contains("DistrictEyebrow(text: InboxCopy.reply)"))
    }

    /// ⚠️ THE NUMBERS TABS ARE THE SYSTEM'S PICKER, NOT FOUR STYLED BUTTONS.
    func test_VQA_03_theNumbersTabsAreAPicker() throws {
        let code = try source("Features/Marketplace/MarketplaceView.swift")
        XCTAssertTrue(code.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(code.contains("model.selectTab($0)"))
        XCTAssertFalse(code.contains("DistrictButtonStyle(variant: model.tab"))
    }

    /// ⛔ AT AN ACCESSIBILITY SIZE THE TABS ARE A `Menu` WITH OUR OWN WRAPPING LABEL, never a
    /// `.menu` picker: the system's menu button cut « Mes numéros » through both lines at AX5.
    func test_VQA_04_theAccessibilitySizeMenuLabelWraps() throws {
        let code = try source("Features/Marketplace/MarketplaceView.swift")
        XCTAssertFalse(code.contains(".pickerStyle(.menu)"))
        XCTAssertTrue(code.contains("tabPicker.pickerStyle(.inline)"))
        XCTAssertTrue(code.contains("Text(Self.tabTitle(model.tab))"))
        XCTAssertTrue(code.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    /// Every tab has its own name in both languages, and the menu's label is that name.
    func test_VQA_05_everyTabHasItsOwnName() {
        for locale in [L10nLocale.en, .frCA] {
            L10nRuntime.withLocale(locale) {
                let titles = MarketplaceTab.allCases.map { MarketplaceView.tabTitle($0) }
                XCTAssertEqual(titles.count, 4, "\(locale)")
                XCTAssertEqual(Set(titles).count, 4, "\(locale)")
                XCTAssertFalse(titles.contains(""), "\(locale)")
            }
        }
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(MarketplaceView.tabTitle(.owned), MarketplaceCopy.tabOwned)
            XCTAssertEqual(MarketplaceView.tabTitle(.carrier), MarketplaceCopy.tabCarrier)
        }
    }
}

/// A file chosen in the Files picker is labelled by the photo picker's own rule.
final class AttachmentFileTests: XCTestCase {
    private let allowed: Set = ["image/jpeg", "image/png", "image/gif"]

    func test_ATTACH_01_aFileIsTypedByItsExtension() {
        XCTAssertEqual(AttachmentFile.mimeType(of: URL(fileURLWithPath: "/tmp/a.png"), allowed: allowed), "image/png")
        XCTAssertEqual(AttachmentFile.mimeType(of: URL(fileURLWithPath: "/tmp/b.JPG"), allowed: allowed), "image/jpeg")
    }

    /// ⚠️ A TYPE THE ROUTE DOES NOT TAKE IS STILL NAMED, so the model refuses it with its own
    /// sentence; a file with no extension is the unknown type.
    func test_ATTACH_02_anUnacceptedOrUnknownTypeIsPassedThroughForTheModelToRefuse() {
        XCTAssertEqual(AttachmentFile.mimeType(of: URL(fileURLWithPath: "/tmp/c.heic"), allowed: allowed), "image/heic")
        XCTAssertEqual(
            AttachmentFile.mimeType(of: URL(fileURLWithPath: "/tmp/noextension"), allowed: allowed),
            "application/octet-stream"
        )
    }
}
