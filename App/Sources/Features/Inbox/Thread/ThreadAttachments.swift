import DistrictData
import Foundation

/// The composer's attachments: pick, hold, drop, refuse.
///
/// ⛔ A SIBLING FILE FOR THE REASON `ThreadDraftFlush.swift` AND `ThreadDraftRestore.swift`
/// BOTH GIVE: `ThreadModel.swift` sits within a few lines of the 500 `swiftlint --strict`
/// allows (`file_length` warns at 500 and every warning is an error in CI), and stored
/// properties such as the email subject need room in the type's own body, a stored
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
    /// ⚠️ EVERY REFUSAL LANDS IN THE SAME PLACE as a send or generation failure, the
    /// strip above the composer, because giving each its own slot would mean three
    /// dismiss controls in one visual location.
    ///
    /// ⛔ GATED ON THE ROLE, NOT THE CHANNEL (max review, #99 and #95). The picker reads its
    /// bytes before this runs, and a channel switch during that read used to drop the photo
    /// here without a word; an upload that lands off SMS is held instead (``land(_:)``).
    func attach(_ data: Data, mimeType: String) async {
        guard canMutate, var content = current, !content.attaching else { return }
        guard content.attachments.count + content.heldAttachments.count < Self.maximumAttachments else {
            refuseAttachment(Self.tooManyAttachments)
            return
        }
        if let refusal = MediaUploadLimits.refusal(mimeType: mimeType, byteCount: data.count) {
            refuseAttachment(refusal.localizedMessage ?? Self.unsupportedAttachment)
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
        switch outcome {
        case let .success(media):
            land(media.url)
        case let .failure(error):
            guard var latest = current else { return }
            latest.attaching = false
            latest.sendFailure = FailureText.from(error)
            setContent(latest)
        }
    }

    /// Put one finished upload where the selected channel can use it.
    ///
    /// ⛔ NOTHING IS LOST ACROSS A CHANNEL SWITCH (max review, #99 and #95). On a channel that
    /// carries images it is staged; on one that cannot (the operator switched while it
    /// uploaded) it is held, with the held sentence, and comes back on SMS.
    ///
    /// ⛔ AND NOT WHILE THE THREAD IS RE-READ EITHER: with no content on screen it goes to
    /// ``ThreadModel/composerMedia``, which the re-read puts back.
    func land(_ url: String) {
        var media = current.map {
            ComposerMedia(attachments: $0.attachments, held: $0.heldAttachments, note: $0.channelNote)
        } ?? composerMedia
        // ⛔ THE CAP IS CHECKED AGAIN ON LANDING (Seer, #99, 4489456427): a draft restored while
        // this uploaded can have filled the five, so the image is dropped and the limit said,
        // in the same words as a sixth pick. With no content on screen there is nowhere to say it.
        guard media.attachments.count + media.held.count < Self.maximumAttachments else {
            refuseAttachment(Self.tooManyAttachments)
            return
        }
        if canAttach {
            media.attachments.append(url)
        } else {
            media.held.append(url)
            media.note = heldNote(media.held)
        }
        guard var latest = current else {
            composerMedia = media
            return
        }
        latest.attaching = false
        latest.attachments = media.attachments
        latest.heldAttachments = media.held
        latest.channelNote = media.note
        setContent(latest)
    }

    /// Drop an attachment before it is sent.
    ///
    /// ⚠️ THE UPLOADED ROW IS NOT DELETED SERVER-SIDE, AND THERE IS NO ROUTE THAT
    /// WOULD. It becomes an orphan `MessageMedia` row that nothing references:
    /// bounded at 5MB, invisible, and cheaper than inventing a delete endpoint whose
    /// only caller would be this button.
    ///
    /// ⛔ A HELD IMAGE IS REMOVED THE SAME WAY (max review, #99 and #95): its chip is dimmed,
    /// with its own Remove, and the held sentence counts what is left. ⚠️ The autosave is
    /// armed so the stored draft follows; without it the image came back on the next open.
    func removeAttachment(_ url: String) {
        guard var content = current else { return }
        content.attachments.removeAll { $0 == url }
        content.heldAttachments.removeAll { $0 == url }
        content.channelNote = heldNote(content.heldAttachments)
        setContent(content)
        armAutosave(composerText)
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

    static var tooManyAttachments: String {
        InboxCopy.canAttachUp5
    }

    static var unsupportedAttachment: String {
        InboxCopy.onlyJpegPngGif
    }

    static var unreadableAttachment: String {
        InboxCopy.imageCouldNotRead
    }
}
