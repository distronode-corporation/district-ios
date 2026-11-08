@testable import DistrictAI
import DistrictL10n
import Foundation
import UIKit
import XCTest

/// A received attachment is fetched without the bearer and branched on its `Content-Type`:
/// an image is drawn, anything else is a file opened in Quick Look, and a fetch that fails
/// says so. Before this a PDF that arrived by MMS drew as a broken image.
final class ReceivedAttachmentTests: XCTestCase {
    private static let media = "https://www.distronode.test/api/media/0b9f6c1e-media"
    private static let twilio = "https://api.twilio.test/2010-04-01/Accounts/AC0/Messages/MM0/Media/ME0"

    private static var png: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private static let pdf = Data("%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n".utf8)

    private static func answer(
        _ status: Int,
        _ contentType: String?,
        _ body: Data,
        seen: Seen? = nil
    ) -> ReceivedAttachmentLoader.Fetch {
        { request in
            seen?.record(request)
            var headers: [String: String] = [:]
            if let contentType {
                headers["Content-Type"] = contentType
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, response)
        }
    }

    /// The requests a stub fetch was handed.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.withLock { stored.append(request) }
        }

        var requests: [URLRequest] {
            lock.withLock { stored }
        }
    }

    // MARK: - The Content-Type branch

    func testAnImageTypeThatDecodesIsDrawnAsAnImage() async {
        let loaded = await ReceivedAttachmentLoader.load(Self.media, fetch: Self.answer(200, "image/png", Self.png))
        guard case .image = loaded else { return XCTFail("expected an image, got \(loaded)") }
    }

    /// ⛔ THE BUG: a PDF went to the image decoder and drew broken. It is a file now.
    func testAPdfIsAFileNotABrokenImage() async {
        let loaded = await ReceivedAttachmentLoader.load(
            Self.media, fetch: Self.answer(200, "application/pdf", Self.pdf)
        )
        guard case let .file(file) = loaded else { return XCTFail("expected a file, got \(loaded)") }
        XCTAssertEqual(file.mimeType, "application/pdf")
        XCTAssertEqual(file.fileExtension, "pdf")
        XCTAssertEqual(file.symbol, "doc.richtext")
        XCTAssertEqual(file.data, Self.pdf)
        XCTAssertNotNil(file.typeName, "iOS names a PDF, so the tile says what it is")
    }

    /// ⚠️ The header's parameters and case do not change the branch.
    func testParametersAndCaseInTheHeaderAreIgnored() async {
        let loaded = await ReceivedAttachmentLoader.load(
            Self.media, fetch: Self.answer(200, "Application/PDF; charset=binary", Self.pdf)
        )
        guard case let .file(file) = loaded else { return XCTFail("expected a file, got \(loaded)") }
        XCTAssertEqual(file.mimeType, "application/pdf")
    }

    /// ⛔ THE URL'S EXTENSION IS NOT TRUSTED: a `.jpg` path that serves a PDF is a file.
    func testTheHeaderWinsOverTheUrl() async {
        let loaded = await ReceivedAttachmentLoader.load(
            "https://media.contract.test/roof.jpg", fetch: Self.answer(200, "application/pdf", Self.pdf)
        )
        guard case .file = loaded else { return XCTFail("expected a file, got \(loaded)") }
    }

    /// ⚠️ An image type whose bytes do not decode (SVG, a truncated JPEG) opens in Quick Look
    /// rather than drawing broken.
    func testAnImageTypeThatDoesNotDecodeIsAFile() async {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        let loaded = await ReceivedAttachmentLoader.load(Self.media, fetch: Self.answer(200, "image/svg+xml", svg))
        guard case let .file(file) = loaded else { return XCTFail("expected a file, got \(loaded)") }
        XCTAssertEqual(file.mimeType, "image/svg+xml")
        XCTAssertEqual(file.fileExtension, "svg")
    }

    /// A response with no type is tried as an image, then kept as a generic file.
    func testNoContentTypeIsTriedAsAnImageThenAGenericFile() async {
        let image = await ReceivedAttachmentLoader.load(Self.media, fetch: Self.answer(200, nil, Self.png))
        guard case .image = image else { return XCTFail("expected an image, got \(image)") }

        let other = await ReceivedAttachmentLoader.load(Self.media, fetch: Self.answer(200, "  ", Data([1, 2, 3])))
        guard case let .file(file) = other else { return XCTFail("expected a file, got \(other)") }
        XCTAssertEqual(file.mimeType, "application/octet-stream")
        XCTAssertEqual(file.fileExtension, "bin", "an unknown type still gets an extension")
        XCTAssertEqual(file.symbol, "doc")
        XCTAssertNil(file.typeName, "the tile falls back to Attachment")
    }

    /// ⚠️ A type iOS has never heard of is a file named "Attachment", with a usable extension.
    func testAnUnknownTypeIsAnUnnamedFile() async {
        let loaded = await ReceivedAttachmentLoader.load(
            Self.media, fetch: Self.answer(200, "application/x-fixture-unknown", Data([7, 7, 7]))
        )
        guard case let .file(file) = loaded else { return XCTFail("expected a file, got \(loaded)") }
        XCTAssertNil(file.typeName)
        XCTAssertEqual(file.fileExtension, "bin")
        XCTAssertEqual(file.symbol, "doc")
    }

    func testATextFileGetsTheTextSymbol() async {
        let loaded = await ReceivedAttachmentLoader.load(
            Self.media, fetch: Self.answer(200, "text/plain", Data("Quote attached.".utf8))
        )
        guard case let .file(file) = loaded else { return XCTFail("expected a file, got \(loaded)") }
        XCTAssertEqual(file.symbol, "doc.text")
        XCTAssertEqual(file.fileExtension, "txt")
    }

    // MARK: - The failure state

    /// ⛔ A CARRIER URL THAT WANTS ITS OWN SIGN-IN ANSWERS 401, AND THAT IS SAID, not drawn as
    /// a broken image or a shimmer that never ends.
    func testARawCarrierUrlThatWantsAuthIsUnavailable() async {
        let xml = Data("<TwilioResponse><RestException><Status>401</Status></RestException></TwilioResponse>".utf8)
        let loaded = await ReceivedAttachmentLoader.load(Self.twilio, fetch: Self.answer(401, "application/xml", xml))
        guard case .unavailable = loaded else { return XCTFail("expected unavailable, got \(loaded)") }
    }

    func testEveryNon2xxIsUnavailable() async {
        for status in [301, 403, 404, 410, 500, 503] {
            let loaded = await ReceivedAttachmentLoader.load(
                Self.media,
                fetch: Self.answer(status, "image/png", Self.png)
            )
            guard case .unavailable = loaded else { return XCTFail("\(status): expected unavailable, got \(loaded)") }
        }
    }

    func testANetworkFailureIsUnavailable() async {
        let loaded = await ReceivedAttachmentLoader.load(Self.media) { _ in throw URLError(.notConnectedToInternet) }
        guard case .unavailable = loaded else { return XCTFail("expected unavailable, got \(loaded)") }
    }

    func testAnEmptyBodyIsUnavailable() async {
        let loaded = await ReceivedAttachmentLoader.load(Self.media, fetch: Self.answer(200, "application/pdf", Data()))
        guard case .unavailable = loaded else { return XCTFail("expected unavailable, got \(loaded)") }
    }

    /// ⛔ ONLY A WEB URL IS FETCHED: anything else is unavailable and never reaches the fetch.
    func testANonWebUrlIsNeverFetched() async {
        let seen = Seen()
        for string in ["", "not a url", "file:///etc/hosts", "javascript:alert(1)", "data:image/png;base64,AA=="] {
            let loaded = await ReceivedAttachmentLoader.load(
                string,
                fetch: Self.answer(200, "image/png", Self.png, seen: seen)
            )
            guard case .unavailable = loaded else { return XCTFail("\(string): expected unavailable, got \(loaded)") }
        }
        XCTAssertTrue(seen.requests.isEmpty)
    }

    /// A response that is not HTTP at all is unavailable.
    func testANonHttpResponseIsUnavailable() throws {
        let response = try URLResponse(
            url: XCTUnwrap(URL(string: Self.media)),
            mimeType: "image/png",
            expectedContentLength: 4,
            textEncodingName: nil
        )
        guard case .unavailable = ReceivedAttachmentLoader.classify(data: Self.png, response: response)
        else { return XCTFail("expected unavailable") }
    }

    // MARK: - No bearer

    /// ⛔ THE REQUEST CARRIES NO `Authorization`: these are anonymous capability URLs
    /// (DistrictCore's `ThreadEvent.mediaUrls`), and the access token must never reach one.
    func testTheRequestCarriesNoAuthorization() async {
        let seen = Seen()
        _ = await ReceivedAttachmentLoader.load(
            Self.media,
            fetch: Self.answer(200, "application/pdf", Self.pdf, seen: seen)
        )
        XCTAssertEqual(seen.requests.count, 1)
        XCTAssertEqual(seen.requests.first?.url?.absoluteString, Self.media)
        XCTAssertNil(seen.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(seen.requests.first?.allHTTPHeaderFields?["Authorization"])
    }

    // MARK: - The temporary files

    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceivedAttachmentTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The file is named for the person and typed for Quick Look, and removed with its folder.
    func testAPreviewFileIsNamedTypedAndRemovedOnDismiss() throws {
        let root = scratchRoot()
        defer { AttachmentPreviewFiles.purge(root) }
        let file = ReceivedAttachmentFile(data: Self.pdf, mimeType: "application/pdf")

        let url = try AttachmentPreviewFiles.write(file, named: "Attachment", under: root)
        XCTAssertEqual(url.lastPathComponent, "Attachment.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Self.pdf)

        AttachmentPreviewFiles.discard(url, under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "only the one folder goes")
    }

    /// ⛔ ONE AT A TIME: a second preview clears the first's copy, so nothing a crash left
    /// mid-preview outlives the next one.
    func testWritingANewPreviewClearsTheLastOne() throws {
        let root = scratchRoot()
        defer { AttachmentPreviewFiles.purge(root) }
        let file = ReceivedAttachmentFile(data: Self.pdf, mimeType: "application/pdf")

        let first = try AttachmentPreviewFiles.write(file, named: "Attachment", under: root)
        let second = try AttachmentPreviewFiles.write(file, named: "Attachment", under: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
    }

    /// ⚠️ Discard removes only a folder it wrote: the parent of any other file is left alone.
    func testDiscardLeavesAFolderOutsideTheRootAlone() throws {
        let root = scratchRoot()
        let elsewhere = scratchRoot()
        defer {
            AttachmentPreviewFiles.purge(root)
            AttachmentPreviewFiles.purge(elsewhere)
        }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let stranger = elsewhere.appendingPathComponent("keep.pdf")
        try Self.pdf.write(to: stranger)

        AttachmentPreviewFiles.discard(stranger, under: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func testTheDefaultRootIsInTheTemporaryDirectory() {
        XCTAssertEqual(
            AttachmentPreviewFiles.root.deletingLastPathComponent().standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        )
    }

    // MARK: - Wording

    func testTheWordsInBothLanguages() {
        XCTAssertEqual(InboxCopy.attachmentCannotOpen, "This attachment can't be opened here")
        XCTAssertEqual(InboxCopy.attachmentFile, "Attachment")
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(InboxCopy.attachmentCannotOpen, "Cette pièce jointe ne peut pas être ouverte ici")
            XCTAssertEqual(InboxCopy.attachmentFile, "Pièce jointe")
            XCTAssertEqual(InboxCopy.attachmentOpenHint, "Ouvre un aperçu que vous pouvez partager.")
            XCTAssertEqual(InboxCopy.imageAttachment, "Image jointe")
            XCTAssertEqual(InboxCopy.loadingAttachment, "Chargement de la pièce jointe")
        }
    }
}
