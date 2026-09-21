import DistrictData
import Foundation

/// The composer's attachments: pick, hold, drop, refuse.
///
/// ⛔ A SIBLING FILE FOR THE REASON `ThreadDraftFlush.swift` AND `ThreadDraftRestore.swift`
/// BOTH GIVE: `ThreadModel.swift` sits within a few lines of the 500 `swiftlint --strict`
/// allows (`file_length` warns at 500 and every warning is an error in CI), and stored
/// properties such as the email subject need room in the type's own body — a stored
/// property cannot live in an extension. The attachment half is the largest piece that
/// stands WHOLE on its own, so it is the one that lives here.
///
/// ⚠️ IT WIDENS NOTHING'S ACCESS. ``ThreadModel/current``, ``ThreadModel/setContent(_:)``,
/// ``ThreadModel/inbox`` and ``ThreadModel/target`` are already internal for the two
/// files above; `attachmentFileName` is not `private` (`private` is file-scoped and its
/// only reader is ``attach(_:mimeType:)``, which is here) and is unreachable from
/// anywhere else because App is one module with no second caller.
extension ThreadModel {
    /// Upload one picked image and hold its URL for the next send.
    ///
    /// ⛔ THE TYPE AND SIZE ARE CHECKED BEFORE THE UPLOAD, NOT AFTER. Five megabytes
    /// spent on a metered connection to be told the format is wrong is a real cost to
    /// the operator, and the local refusal can name the actual rule.
    /// ``MediaUploadLimits`` re-checks inside the repository and the route checks
    /// again; this is a shortcut, never the boundary.
    ///
    /// ⚠️ EVERY REFUSAL LANDS IN THE SAME PLACE as a send or generation failure — the
    /// strip above the composer — because giving each its own slot would mean three
    /// dismiss controls in one visual location.
    func attach(_ data: Data, mimeType: String) async {
        guard canAttach, var content = current, !content.attaching else { return }
        guard content.attachments.count < Self.maximumAttachments else {
            refuseAttachment(Self.tooManyAttachments)
            return
        }
        if let refusal = MediaUploadLimits.refusal(mimeType: mimeType, byteCount: data.count) {
            refuseAttachment(refusal.message ?? Self.unsupportedAttachment)
            return
        }

        content.attaching = true
        content.sendFailure = nil
        setContent(content)

        let outcome = await inbox.uploadMedia(
            workspaceId: target.workspaceId,
            fileName: Self.attachmentFileName,
            mimeType: mimeType,
            bytes: data
        )
        guard var latest = current else { return }
        latest.attaching = false
        switch outcome {
        case let .success(media):
            latest.attachments.append(media.url)
        case let .failure(error):
            latest.sendFailure = FailureText.from(error)
        }
        setContent(latest)
    }

    /// Drop an attachment before it is sent.
    ///
    /// ⚠️ THE UPLOADED ROW IS NOT DELETED SERVER-SIDE, AND THERE IS NO ROUTE THAT
    /// WOULD. It becomes an orphan `MessageMedia` row that nothing references:
    /// bounded at 5MB, invisible, and cheaper than inventing a delete endpoint whose
    /// only caller would be this button.
    func removeAttachment(_ url: String) {
        guard var content = current else { return }
        content.attachments.removeAll { $0 == url }
        setContent(content)
    }

    /// Record a client-authored attachment refusal.
    ///
    /// ⚠️ ALWAYS `.none` RATHER THAN `.retry`: re-picking the identical image is
    /// refused identically, so the operator's next action is to choose a different
    /// one, not to press try-again.
    func refuseAttachment(_ message: String) {
        guard var content = current else { return }
        content.attaching = false
        content.sendFailure = FailureText(message: message, action: .none)
        setContent(content)
    }

    /// ⚠️ THE SERVER STORES THE MIME TYPE AND THE BYTE LENGTH AND NEVER READS THE
    /// NAME. It matters only because a multipart part with no filename is not a file
    /// part at all, and `file instanceof File` then fails server-side. The photo
    /// picker hands over bytes without one, so this constant is the whole of it.
    static let attachmentFileName = "attachment"

    static let tooManyAttachments = "You can attach up to 5 images to one message."
    static let unsupportedAttachment = "Only JPEG, PNG, GIF or WebP images can be attached."
    static let unreadableAttachment = "That image could not be read. Try picking it again."
}
