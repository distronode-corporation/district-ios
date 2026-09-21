import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// The two checks a client can make about an image before spending an upload.
///
/// ⛔ ADVISORY, NEVER THE BOUNDARY, AND THE DISTINCTION MATTERS FOR SVG. The fork
/// sniffs the first 512 bytes rather than trusting the declared type, so a real
/// SVG renamed `.png` and declared `image/png` still fails there. What checking
/// here buys is a sentence the app can word itself, one round trip earlier — never
/// a guarantee.
///
/// ⛔ AND THE THREE ANSWERS ARE KEPT APART. "Too large", "not a type we can use"
/// and "the picker gave us nothing readable" call for three different next actions;
/// collapsing them leaves an operator re-picking the same file. The upload route
/// itself answers 413 and 415 for the first two, and both land on
/// ``SchedulingAdminError/unknown`` — the five-code vocabulary has no "wrong file
/// type" arm — which is exactly why the mitigation belongs on the way IN.
enum SchedulingWritesBImage {
    /// nil means "send it".
    ///
    /// ⚠️ SIZE IS TESTED BEFORE TYPE, matching the web uploader, which checks only
    /// the size on the client and leaves the type to the picker's `accept`. A
    /// 9 MB SVG is refused for its size there and here; saying the same thing in
    /// the same order keeps the two clients' bug reports comparable.
    static func rejection(for file: SchedulingUploadFile) -> String? {
        if file.bytes.isEmpty {
            return SchedulingSettingsWriteCopy.imageUnreadable
        }
        if file.bytes.count > SchedulingUploadFile.maxBytes {
            return SchedulingSettingsWriteCopy.imageTooLarge
        }
        if !SchedulingUploadFile.acceptedMimeTypes.contains(file.mimeType) {
            return SchedulingSettingsWriteCopy.imageWrongType
        }
        return nil
    }

    /// ⛔ THE PART IS NAMED `file` ON THE WAY OUT AND IS RENAMED AT THE FAR END.
    /// Our route reads `form.get("file")` and forwards it to the fork under `logo`,
    /// `banner` or `avatar`; a part named after the TARGET is "file_required" here,
    /// before the scheduler is ever asked. ``MultipartBody/filePartName`` already
    /// holds that name — this is a note, not a second definition.
    ///
    /// ⚠️ The FILE NAME is carried for the far end's benefit, and omitting it makes
    /// the part a plain field rather than a file, at which point `file instanceof
    /// File` fails and the route answers 400. A picker item often has no name at
    /// all, so one is synthesised from the target and the type.
    static func file(bytes: Data, mimeType: String, target: SchedulingAdminUploadTarget) -> SchedulingUploadFile {
        SchedulingUploadFile(
            fileName: "\(target.rawValue).\(fileExtension(for: mimeType))",
            mimeType: mimeType,
            bytes: bytes
        )
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        // ⚠️ Unreachable through ``rejection(for:)``, and present so this function
        // is total rather than trapping on a type the picker invented.
        default: "img"
        }
    }
}
