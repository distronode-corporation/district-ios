import Foundation
import UIKit
import UniformTypeIdentifiers

/// What one received attachment turned out to be, once fetched.
///
/// ⛔ DECIDED BY THE RESPONSE'S `Content-Type`, NOT BY THE URL. A timeline's `mediaUrls` is a
/// bare list of strings with no type or name, and an inbound MMS stores the carrier's raw
/// `MediaUrl0..N`, which carry no extension. `/api/media/<uuid>` answers with the stored type
/// and `nosniff`, so the header is the one statement of what the bytes are. Before this a PDF
/// went to `AsyncImage`, failed to decode and drew as a broken image.
enum ReceivedAttachment {
    /// Drawn in place, as before.
    case image(UIImage)
    /// Anything else: drawn as a file tile and opened in Quick Look.
    case file(ReceivedAttachmentFile)
    /// ⛔ SAID, NEVER A SILENT BLANK: a non-2xx (a carrier URL that wants its own auth), a
    /// network failure, an empty body or a string that is not a web URL.
    case unavailable
}

/// The bytes of a non-image attachment and the type its server named.
struct ReceivedAttachmentFile: Equatable {
    let data: Data
    /// Lowercased, parameters dropped (`application/pdf`, never `application/PDF; q=1`).
    let mimeType: String

    private var type: UTType? {
        UTType(mimeType: mimeType)
    }

    /// The system's own name for the type (`PDF document`, `document PDF`), localised by iOS.
    /// Nil for a type it does not know, where the tile says "Attachment".
    ///
    /// ⚠️ `application/octet-stream` IS KNOWN, AS `public.data`, and iOS names it "data"
    /// ("données"), which tells the operator nothing; it gets "Attachment" too.
    var typeName: String? {
        guard let type, type != .data, !type.isDynamic else { return nil }
        return type.localizedDescription
    }

    /// The extension Quick Look needs to pick a previewer. ⚠️ Without one a PDF previews as
    /// an unknown file, so an unknown type falls back to the generic `bin`.
    var fileExtension: String {
        type?.preferredFilenameExtension ?? "bin"
    }

    /// The tile's symbol: a PDF, any other document, or a plain file.
    var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .pdf) {
            return "doc.richtext"
        }
        if type.conforms(to: .text) {
            return "doc.text"
        }
        return "doc"
    }
}

enum ReceivedAttachmentLoader {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// ⛔ `URLSession.shared` WITH NO `Authorization` HEADER, exactly as `AsyncImage` loaded it
    /// before. DistrictCore's `ThreadEvent.mediaUrls` and `UploadedMedia.url` say why: they are
    /// anonymous capability URLs, and this client's bearer token must never be sent to one.
    /// A carrier URL that wants the carrier's own credentials answers 401, which is
    /// ``ReceivedAttachment/unavailable``, said on screen.
    static let anonymous: Fetch = { request in
        try await URLSession.shared.data(for: request)
    }

    static func load(_ string: String, fetch: Fetch = anonymous) async -> ReceivedAttachment {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return .unavailable }
        do {
            let (data, response) = try await fetch(URLRequest(url: url))
            return classify(data: data, response: response)
        } catch {
            return .unavailable
        }
    }

    static func classify(data: Data, response: URLResponse) -> ReceivedAttachment {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              !data.isEmpty
        else { return .unavailable }
        let mimeType = mimeType(http.value(forHTTPHeaderField: "Content-Type"))
        // ⚠️ AN IMAGE TYPE THAT DOES NOT DECODE (SVG, say) IS STILL A FILE, opened in Quick
        // Look rather than drawn broken. A response with no type is tried as an image first.
        if mimeType == nil || mimeType?.hasPrefix("image/") == true, let image = UIImage(data: data) {
            return .image(image)
        }
        return .file(ReceivedAttachmentFile(data: data, mimeType: mimeType ?? "application/octet-stream"))
    }

    /// `application/pdf; charset=binary` to `application/pdf`; nil when absent or blank.
    static func mimeType(_ header: String?) -> String? {
        guard let header else { return nil }
        let bare = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = bare.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The temporary files Quick Look previews from.
///
/// ⛔ ONE AT A TIME, AND GONE WHEN THE PREVIEW CLOSES. Each file is written to a fresh folder
/// under one root, the root is emptied before each write (which also clears anything a crash
/// left mid-preview), and the folder is removed on dismiss. A received document is the
/// customer's, and a copy left in the app's temporary directory outlives the reason it was made.
enum AttachmentPreviewFiles {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ReceivedAttachments", isDirectory: true)
    }

    /// ⚠️ NAMED FOR THE PERSON, because Quick Look shows the name as its title and the share
    /// sheet hands it on: `Attachment.pdf`, never `<uuid>.pdf`.
    static func write(_ file: ReceivedAttachmentFile, named name: String, under root: URL = root) throws -> URL {
        purge(root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension(file.fileExtension)
        try file.data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Remove one previewed file and the folder it was written to.
    ///
    /// ⚠️ ONLY A FOLDER DIRECTLY UNDER `root`: the parent of anything else is left alone.
    static func discard(_ url: URL, under root: URL = root) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func purge(_ root: URL = root) {
        try? FileManager.default.removeItem(at: root)
    }
}
