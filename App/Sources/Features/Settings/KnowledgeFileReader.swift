import Foundation

/// What a text file picked for a knowledge document gave: a title and text to put in
/// the form, or why it was refused.
enum KnowledgeFileRead: Equatable {
    /// Plain text: the file's name less its extension, and its text.
    case text(title: String, content: String)
    /// Refused, and why, in words to show. Nothing is put in the form.
    case refused(String)
}

/// One file the operator picked, as it was read: Windows' `PickedFileView`.
struct KnowledgePickedFile: Sendable {
    /// The file's name, without its folder.
    let name: String
    /// Its size as the file system reported it, which may be more than ``bytes`` holds,
    /// or nil when it did not say.
    let size: Int?
    /// Its first bytes, no more than ``KnowledgeFileReader/maxBytes`` + 1.
    let bytes: Data
}

/// "Read a text file": a picked file as a knowledge document's title and text.
///
/// ⛔ A PORT OF district-windows `crates/district-ffi/src/settings/knowledge.rs`
/// (`knowledge_file`, `read_text`, `decode`, `title_of`), and its rules are that file's:
/// the same 1 MB limit, the same refusals in the same order, the same decoding. A change
/// here is a change there first, so the apps keep refusing the same files for the same
/// reasons.
///
/// ⛔ THE BYTES DECIDE, NEVER THE NAME. A PDF renamed `.txt` is refused by its first bytes,
/// and a file that does not decode as UTF-8 (with or without its mark) or UTF-16 with its
/// mark is not plain text whatever its type says.
///
/// ⚠️ FOUNDATION ONLY AND NO FILE ACCESS, so the Mac (and DistrictCore, if it moves there)
/// takes it unchanged and the tests need no file. ``KnowledgeModel/readFile(at:)`` does the
/// reading.
enum KnowledgeFileReader {
    /// The largest file read in, in bytes. The service takes any length and bills by it,
    /// so the app keeps a file to a size a person would paste.
    static let maxBytes = 1024 * 1024

    /// The longest title the service keeps, in characters.
    static let titleLimit = 200

    /// `file` as a document's title and text, or why it is refused.
    static func read(_ file: KnowledgePickedFile) -> KnowledgeFileRead {
        switch text(size: file.size, bytes: file.bytes) {
        case let .success(content):
            .text(title: title(of: file.name), content: content)
        case let .failure(refusal):
            .refused(refusal.message)
        }
    }

    // MARK: - The text

    /// Why a file is refused.
    enum Refusal: Error, Equatable {
        case tooLarge
        case empty
        case notText
        case noText

        var message: String {
            switch self {
            case .tooLarge: SettingsCopy.knowledgeFileTooLarge
            case .empty: SettingsCopy.knowledgeFileEmpty
            case .notText: SettingsCopy.knowledgeFileNotText
            case .noText: SettingsCopy.knowledgeFileNoText
            }
        }
    }

    /// ⚠️ IN WINDOWS' ORDER: size, emptiness, a known binary signature, decoding, control
    /// characters, then words. An empty file is "empty" rather than "no text", and a
    /// large one is "too large" before anything else is looked at.
    static func text(size: Int?, bytes: Data) -> Result<String, Refusal> {
        if (size ?? 0) > maxBytes || bytes.count > maxBytes {
            return .failure(.tooLarge)
        }
        if bytes.isEmpty {
            return .failure(.empty)
        }
        let raw = [UInt8](bytes)
        if isKnownBinary(raw.prefix(12)) {
            return .failure(.notText)
        }
        guard let scalars = decode(raw) else {
            return .failure(.notText)
        }
        if scalars.contains(where: isRefusedControl) {
            return .failure(.notText)
        }
        let content = joiningLines(scalars)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.noText)
        }
        return .success(content)
    }

    /// ⚠️ THE SIGNATURES WINDOWS SNIFFS (`files.rs`): PNG, JPEG, GIF, PDF, WebP and an
    /// ISO `ftyp` box of a HEIC or HEIF brand. Most other binaries fail the decode or the
    /// control-character check after this.
    static func isKnownBinary(_ head: ArraySlice<UInt8>) -> Bool {
        let head = Array(head)
        if signatures.contains(where: { head.starts(with: $0) }) {
            return true
        }
        guard head.count >= 12 else { return false }
        if head.starts(with: Array("RIFF".utf8)), Array(head[8 ..< 12]) == Array("WEBP".utf8) {
            return true
        }
        guard Array(head[4 ..< 8]) == Array("ftyp".utf8) else { return false }
        return imageBrands.contains(Array(head[8 ..< 12]))
    }

    /// PNG, JPEG, GIF (both versions) and PDF, by their first bytes.
    private static let signatures: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        [0xFF, 0xD8, 0xFF],
        Array("GIF87a".utf8),
        Array("GIF89a".utf8),
        Array("%PDF-".utf8),
    ]

    /// HEVC-coded image brands, then HEIF's other two.
    private static let imageBrands: [[UInt8]] = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1",
    ].map { Array($0.utf8) }

    /// UTF-8, with or without its mark, or UTF-16 with its mark (as Windows Notepad saves
    /// "Unicode"); nil for anything else.
    ///
    /// ⚠️ DECODED STRICTLY, scalar by scalar. A repairing decode would turn a Latin-1 file
    /// into replacement characters and hand them to the form as if they were the text.
    static func decode(_ bytes: [UInt8]) -> [Unicode.Scalar]? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return strictly(UTF8.self, Array(bytes.dropFirst(3)))
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return utf16(bytes.dropFirst(2)) { UInt16($0) | UInt16($1) << 8 }
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return utf16(bytes.dropFirst(2)) { UInt16($0) << 8 | UInt16($1) }
        }
        return strictly(UTF8.self, bytes)
    }

    private static func utf16(_ rest: ArraySlice<UInt8>, _ unit: (UInt8, UInt8) -> UInt16) -> [Unicode.Scalar]? {
        let rest = Array(rest)
        guard rest.count.isMultiple(of: 2) else { return nil }
        let units = stride(from: 0, to: rest.count, by: 2).map { unit(rest[$0], rest[$0 + 1]) }
        return strictly(UTF16.self, units)
    }

    private static func strictly<Codec: UnicodeCodec>(_: Codec.Type, _ units: [Codec.CodeUnit]) -> [Unicode.Scalar]? {
        var decoder = Codec()
        var iterator = units.makeIterator()
        var scalars: [Unicode.Scalar] = []
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                scalars.append(scalar)
            case .emptyInput:
                return scalars
            case .error:
                return nil
            }
        }
    }

    /// A control character other than tab, line feed, carriage return and form feed.
    private static func isRefusedControl(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.generalCategory == .control else { return false }
        return !["\t", "\n", "\r", "\u{0C}"].contains(scalar)
    }

    /// The text with each CR LF made one LF, as Windows' `replace("\r\n", "\n")`.
    ///
    /// ⚠️ ON SCALARS, BECAUSE A SWIFT `String` HOLDS CR LF AS ONE CHARACTER and a
    /// character-level replace would look past it.
    private static func joiningLines(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                continue
            }
            view.append(scalar)
        }
        return String(view)
    }

    // MARK: - The title

    /// The title a file's name suggests: without its folder, its last extension and any
    /// control character, no longer than ``titleLimit``; the name as it is when that
    /// leaves nothing.
    static func title(of fileName: String) -> String {
        let last = fileName.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.last ?? ""
        var name = String.UnicodeScalarView()
        name.append(contentsOf: last.unicodeScalars.filter { $0.properties.generalCategory != .control })
        let whole = String(name)
        var stem = whole
        if let dot = whole.lastIndex(of: ".") {
            let before = String(whole[..<dot])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stem = before
            }
        }
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = String.UnicodeScalarView()
        title.append(contentsOf: trimmed.unicodeScalars.prefix(titleLimit))
        return String(title)
    }
}
