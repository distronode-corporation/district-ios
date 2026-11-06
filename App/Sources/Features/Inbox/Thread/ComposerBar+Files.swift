import DistrictData
import PhotosUI
import SwiftUI

/// Reading what the operator picked, for ``ComposerBar``.
///
/// ⚠️ A SIBLING FILE BECAUSE `ComposerBar.swift` REACHED THE 500-LINE `file_length`
/// CEILING `swiftlint --strict` ENFORCES when the WhatsApp window joined it. Moved
/// verbatim; the two methods lost their `private` only because `private` is file-scoped.
extension ComposerBar {
    /// Read the picked item's bytes and hand them to the model.
    ///
    /// ⛔ THE BYTES CROSS INTO THE MODEL THROUGH ONE `@MainActor` CALL and nothing
    /// else is carried across: `Data` is a value, the model owns every decision about
    /// it, and the type and size are refused there before a byte is uploaded.
    ///
    /// ⚠️ A NIL OR THROWING LOAD IS "COULD NOT BE READ", WHICH IS NOT THE SAME AS A
    /// REJECTED TYPE OR SIZE. Those three call for three different next actions from
    /// the operator, and collapsing them would leave them re-picking the same file.
    func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.refuseAttachment(ThreadModel.unreadableAttachment)
            return
        }
        await model.attach(data, mimeType: item.preferredMIMEType(allowed: MediaUploadLimits.allowedMimeTypes))
    }

    /// Read a file chosen in the Files picker and hand it to the model, as ``read(_:)`` does.
    ///
    /// ⛔ THE SECURITY-SCOPED ACCESS IS OPENED AND CLOSED AROUND THE ONE READ. The picker
    /// grants this app the chosen file only, through the URL's scope; reading outside it fails
    /// as "could not be read".
    func readFile(_ result: Result<URL, any Error>) async {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            model.refuseAttachment(ThreadModel.unreadableAttachment)
            return
        }
        await model.attach(
            data,
            mimeType: AttachmentFile.mimeType(of: url, allowed: MediaUploadLimits.allowedMimeTypes)
        )
    }
}
