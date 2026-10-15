import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension PhotosPickerItem {
    /// The MIME type to upload this item's bytes as.
    ///
    /// ⚠️ THE TYPE COMES FROM THE ITEM, NOT FROM A FILE EXTENSION. A picker item often
    /// has no name at all, and every upload route's allowlist is on the MIME type, so
    /// a guess from a name would refuse legitimate images and could label a non-image
    /// as one, spending the upload to be refused server-side.
    ///
    /// ⛔ ONE COPY FOR EVERY PICKER (the composer's attachment, the Desk logo, the
    /// scheduling images); each passes its own route's allowlist.
    func preferredMIMEType(allowed: Set<String>) -> String {
        Self.preferredMIMEType(
            declared: supportedContentTypes.compactMap(\.preferredMIMEType),
            allowed: allowed
        )
    }

    /// ⚠️ AN ITEM DECLARING NOTHING THE ROUTE ACCEPTS FALLS BACK TO ITS FIRST DECLARED
    /// TYPE, OR TO A DELIBERATELY UNACCEPTABLE ONE. Either way the route's limits
    /// refuse it BY NAME rather than this function inventing a type the bytes might
    /// not be. Separate from the item so it is testable: a test cannot build a
    /// `PhotosPickerItem` that declares types.
    static func preferredMIMEType(declared: [String], allowed: Set<String>) -> String {
        if let accepted = declared.first(where: { allowed.contains($0) }) {
            return accepted
        }
        return declared.first ?? unknownMIMEType
    }

    static let unknownMIMEType = "application/octet-stream"
}

/// The MIME type of a file chosen in the Files picker (the composer's file control, 3.0.1).
///
/// ⚠️ IT GOES THROUGH THE PICKER'S OWN RULE (``PhotosPickerItem/preferredMIMEType(declared:allowed:)``),
/// so a file and a photo of the same type are labelled alike. The type comes from the file's
/// extension, which is what the picker filtered on; a file with none is
/// `application/octet-stream`, which the model refuses with its own sentence. The same type as
/// District AI for Mac's.
enum AttachmentFile {
    static func mimeType(of url: URL, allowed: Set<String>) -> String {
        let declared = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return PhotosPickerItem.preferredMIMEType(declared: declared.map { [$0] } ?? [], allowed: allowed)
    }
}
