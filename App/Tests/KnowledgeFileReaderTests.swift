@testable import DistrictAI
import Foundation
import XCTest

/// "Read a text file": what a picked file becomes.
///
/// ⛔ THE CASES ARE district-windows' `settings/knowledge.rs` tests, file for file, so the
/// two apps refuse the same files for the same reasons. A case added there is added here.
final class KnowledgeFileReaderTests: XCTestCase {
    func testATextFileFillsTheForm() {
        XCTAssertEqual(
            read("C:\\Docs\\Refund policy.txt", Array("We refund in 30 days.\r\n".utf8)),
            .text(title: "Refund policy", content: "We refund in 30 days.\n")
        )
    }

    /// With a UTF-8 mark, and as Notepad's "Unicode" (UTF-16, both orders).
    func testMarkedUTF8AndBothUTF16OrdersAreText() {
        let words = "Open 9 to 5"
        let marked: [UInt8] = [0xEF, 0xBB, 0xBF] + Array(words.utf8)
        let little: [UInt8] = [0xFF, 0xFE] + words.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let big: [UInt8] = [0xFE, 0xFF] + words.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        for bytes in [marked, little, big] {
            XCTAssertEqual(read("hours.md", bytes), .text(title: "hours", content: words))
        }
    }

    func testTheTitleLosesFolderExtensionAndControlCharacters() {
        XCTAssertEqual(KnowledgeFileReader.title(of: "../a/b/notes.v2.txt"), "notes.v2")
        XCTAssertEqual(KnowledgeFileReader.title(of: "ro\r\nof.txt"), "roof")
        XCTAssertEqual(KnowledgeFileReader.title(of: ".txt"), ".txt")
        XCTAssertEqual(KnowledgeFileReader.title(of: "README"), "README")
        XCTAssertEqual(KnowledgeFileReader.title(of: "folder\\"), "")
        let long = KnowledgeFileReader.title(of: String(repeating: "a", count: 300) + ".txt")
        XCTAssertEqual(long.unicodeScalars.count, 200)
    }

    /// ⛔ BY ITS BYTES, WHATEVER ITS NAME SAYS.
    func testAFileThatIsNotTextIsRefusedByItsBytes() {
        let cases: [(String, [UInt8])] = [
            ("scan.txt", Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3]),
            ("photo.md", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D] + Array("IHDR".utf8)),
            ("latin1.txt", Array("caf".utf8) + [0xE9]),
            ("binary.txt", Array("abc".utf8) + [0] + Array("def".utf8)),
            ("odd.txt", [0xFF, 0xFE, 0x41]),
            ("lone.txt", [0xFF, 0xFE, 0x00, 0xD8]),
            ("bad.txt", [0xEF, 0xBB, 0xBF, 0xFF]),
        ]
        for (name, bytes) in cases {
            XCTAssertEqual(read(name, bytes), .refused(SettingsCopy.knowledgeFileNotText), name)
        }
    }

    func testTheOtherSignaturesWindowsSniffsAreRefused() {
        let riff = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        let heic = [0, 0, 0, 0x18] + Array("ftypheic".utf8)
        let heif = [0, 0, 0, 0x18] + Array("ftypmif1".utf8)
        for bytes in [[0xFF, 0xD8, 0xFF, 0xE0], Array("GIF89a".utf8), Array("GIF87a".utf8), riff, heic, heif] {
            XCTAssertEqual(read("image.txt", bytes), .refused(SettingsCopy.knowledgeFileNotText))
        }
        // An `ftyp` box of another brand (an MP4) is left to the decode, which refuses it.
        XCTAssertFalse(KnowledgeFileReader.isKnownBinary(ArraySlice([0, 0, 0, 0x18] + Array("ftypisom".utf8))))
    }

    func testAnEmptyOrLargeFileIsRefused() {
        XCTAssertEqual(read("empty.txt", []), .refused(SettingsCopy.knowledgeFileEmpty))
        XCTAssertEqual(read("blank.txt", Array(" \r\n\t ".utf8)), .refused(SettingsCopy.knowledgeFileNoText))
        let cap = KnowledgeFileReader.maxBytes
        var large = [UInt8](repeating: UInt8(ascii: "a"), count: cap + 1)
        XCTAssertEqual(read("large.txt", large), .refused(SettingsCopy.knowledgeFileTooLarge))
        large.removeLast()
        guard case .text = read("large.txt", large) else {
            XCTFail("a file of exactly 1 MB is read")
            return
        }
        // The file system says it is larger than what was read: still too large.
        XCTAssertEqual(
            KnowledgeFileReader.read(KnowledgePickedFile(name: "large.txt", size: cap + 10, bytes: Data("short".utf8))),
            .refused(SettingsCopy.knowledgeFileTooLarge)
        )
    }

    func testTabsFormFeedsAndLoneCarriageReturnsAreText() {
        XCTAssertEqual(
            read("table.txt", Array("a\tb\u{0C}c\rd".utf8)),
            .text(title: "table", content: "a\tb\u{0C}c\rd")
        )
    }

    // MARK: - Helpers

    private func read(_ name: String, _ bytes: [UInt8]) -> KnowledgeFileRead {
        KnowledgeFileReader.read(KnowledgePickedFile(name: name, size: bytes.count, bytes: Data(bytes)))
    }
}
