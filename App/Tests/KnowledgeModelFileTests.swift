@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// "Read a text file" on the Knowledge model: what a file does to the form.
///
/// ⛔ NOTHING HERE TOUCHES THE NETWORK. A file fills the two boxes and the operator still
/// presses Add document; the container points at an unreachable host so a request that
/// slipped through would fail loudly rather than reach a server.
@MainActor
final class KnowledgeModelFileTests: XCTestCase {
    private let unreachable = URL(string: "https://knowledge.invalid")!
    /// ⚠️ ONE FOLDER PER TEST: XCTest builds a fresh instance for each method.
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    func testAFileFillsAnEmptyTitleAndTheText() {
        let model = model()
        model.editContent("an old paste")

        model.apply(.text(title: "Refund policy", content: "We refund in 30 days."))

        XCTAssertEqual(model.draftTitle, "Refund policy")
        XCTAssertEqual(model.draftContent, "We refund in 30 days.", "the text replaces the box")
        XCTAssertNil(model.fileRefusal)
        XCTAssertTrue(model.canAdd, "the form is ready for Add document, which is still the operator's press")
    }

    func testATypedTitleIsKept() {
        let model = model()
        model.editTitle("Refunds")

        model.apply(.text(title: "refund-policy-v3", content: "We refund in 30 days."))

        XCTAssertEqual(model.draftTitle, "Refunds")
        XCTAssertEqual(model.draftContent, "We refund in 30 days.")
    }

    func testARefusalLeavesTheFormAndIsSaid() {
        let model = model()
        model.editTitle("Refunds")
        model.editContent("typed")

        model.apply(.refused(SettingsCopy.knowledgeFileTooLarge))

        XCTAssertEqual(model.fileRefusal, SettingsCopy.knowledgeFileTooLarge)
        XCTAssertEqual(model.draftTitle, "Refunds")
        XCTAssertEqual(model.draftContent, "typed")
    }

    func testAKeystrokeInEitherBoxRetiresTheRefusal() {
        let model = model()
        model.apply(.refused(SettingsCopy.knowledgeFileEmpty))
        model.editTitle("R")
        XCTAssertNil(model.fileRefusal)

        model.apply(.refused(SettingsCopy.knowledgeFileEmpty))
        model.editContent("T")
        XCTAssertNil(model.fileRefusal)
    }

    func testAGoodFileRetiresTheLastRefusal() {
        let model = model()
        model.apply(.refused(SettingsCopy.knowledgeFileNotText))
        model.apply(.text(title: "hours", content: "Open 9 to 5"))
        XCTAssertNil(model.fileRefusal)
    }

    /// ⛔ A VIEWER IS OFFERED NO ADD FORM, so no file fills one either.
    func testAViewerCannotReadAFile() async throws {
        let model = model(role: .viewer)
        XCTAssertFalse(model.canReadFile)

        model.apply(.text(title: "hours", content: "Open 9 to 5"))
        model.fileImportFailed()
        let url = try write("hours.txt", Data("Open 9 to 5".utf8))
        await model.readFile(at: url)

        XCTAssertEqual(model.draftContent, "")
        XCTAssertNil(model.fileRefusal)
    }

    func testAFailedImportIsSaid() {
        let model = model()
        model.fileImportFailed()
        XCTAssertEqual(model.fileRefusal, SettingsCopy.knowledgeFileUnreadable)
    }

    // MARK: - From the disk

    func testAFileOnDiskIsReadIntoTheForm() async throws {
        let model = model()
        let url = try write("Refund policy.txt", Data("We refund in 30 days.\r\n".utf8))
        await model.readFile(at: url)
        XCTAssertEqual(model.draftTitle, "Refund policy")
        XCTAssertEqual(model.draftContent, "We refund in 30 days.\n")
    }

    /// ⚠️ AN EMPTY FILE IS "EMPTY", NOT "COULD NOT BE READ": the read returns no bytes at
    /// once, which is an answer rather than a failure.
    func testAnEmptyFileOnDiskIsEmpty() async throws {
        let model = model()
        let url = try write("empty.txt", Data())
        await model.readFile(at: url)
        XCTAssertEqual(model.fileRefusal, SettingsCopy.knowledgeFileEmpty)
    }

    /// The read stops one byte past the limit, which is enough to say the file is too large.
    func testALargeFileOnDiskIsTooLarge() async throws {
        let model = model()
        let large = Data(repeating: UInt8(ascii: "a"), count: KnowledgeFileReader.maxBytes + 4096)
        let url = try write("large.txt", large)
        await model.readFile(at: url)
        XCTAssertEqual(model.fileRefusal, SettingsCopy.knowledgeFileTooLarge)
        XCTAssertEqual(model.draftContent, "")
    }

    func testAFileThatIsGoneCouldNotBeRead() async {
        let model = model()
        await model.readFile(at: folder.appendingPathComponent("gone.txt"))
        XCTAssertEqual(model.fileRefusal, SettingsCopy.knowledgeFileUnreadable)
    }

    // MARK: - Helpers

    private func model(role: WorkspaceRole = .client) -> KnowledgeModel {
        KnowledgeModel(container: AppContainer(baseURL: unreachable), workspaceId: "ws_1", role: role)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
