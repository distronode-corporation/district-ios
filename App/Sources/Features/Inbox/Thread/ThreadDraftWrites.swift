import DistrictData
import DistrictModel
import Foundation

/// The composer draft's writes: the debounced save, the blank-box delete and the
/// post-send delete, and what is said when one does not land.
///
/// ⚠️ A SIBLING FILE BECAUSE `ThreadModel.swift` IS AT THE 500-LINE `file_length`
/// CEILING `swiftlint --strict` ENFORCES, the reason `ThreadDraftFlush.swift` and
/// `ThreadDraftRestore.swift` exist. App is one module; nothing else calls these.
extension ThreadModel {
    /// ⛔ A BLANK BOX SENDS DELETE, NEVER A PUT WITH AN EMPTY BODY. The route answers
    /// 400 `empty_body` to the latter, deliberately, because a blank draft is the
    /// ABSENCE of one rather than an empty one — and a stored blank row would make
    /// the Inbox badge count a thread with nothing to restore. The two writes share
    /// one rate-limit bucket, so getting this wrong also burns a slot to be refused.
    ///
    /// - Returns: true when the blank case was handled and nothing else should write.
    func deleteDraftIfBlank(_ text: String) async -> Bool {
        guard Self.isBlank(text) else { return false }
        await deleteDraft()
        return true
    }

    /// The debounce's body.
    ///
    /// ⚠️ THE ATTACHMENTS AND THE SUBJECT ARE READ AT FIRE TIME, NOT AT EDIT TIME:
    /// an image attached, or a subject typed, during the debounce belongs on the
    /// draft the timer is about to write.
    ///
    /// ⚠️ INTERNAL RATHER THAN `private` FOR ``flushDraft()``; see ``autosaveTask``.
    func persistDraft(_ text: String) async {
        if await deleteDraftIfBlank(text) {
            return
        }
        await noteDraftWrite(inbox.saveDraft(
            workspaceId: target.workspaceId,
            threadKey: target.threadKey,
            body: text,
            subject: outgoingSubject,
            mediaUrls: current?.attachments ?? []
        ))
    }

    /// - Returns: whether the server draft is gone.
    @discardableResult
    func deleteDraft() async -> Bool {
        await noteDraftWrite(inbox.deleteDraft(workspaceId: target.workspaceId, threadKey: target.threadKey))
    }

    @discardableResult
    private func noteDraftWrite(_ result: Result<some Any, ApiError>) -> Bool {
        switch result {
        case .success:
            draftNotice = nil
            return true
        case .failure:
            draftNotice = Self.draftNotSaved
            return false
        }
    }

    static let draftNotSaved = "Draft not saved. It will be saved again as you type."

    static let sentDraftSurvived = "Sent. The saved draft could not be cleared, so check it before replying elsewhere."
}
