import DistrictData
import DistrictModel
import Foundation
import Observation

/// Who this account has blocked, shared by every screen that has to say so.
///
/// ⛔ ONE INSTANCE ON ``AppContainer``, NOT ONE PER SCREEN, AND THE REASON IS THE
/// GUIDELINE. App Store Review Guideline 1.2 asks that blocking a user remove their
/// content from view **immediately** — so the thread screen that performs the block
/// and the inbox list that must stop showing the thread have to agree without a
/// round trip, and they are different views with different models. A per-screen copy
/// would make "is this caller blocked" a question about whichever model was asked
/// last, which on a phone is whichever screen the user happens to be standing on.
///
/// ⛔ IT IS A CACHE IN FRONT OF THE SERVER, NEVER THE AUTHORITY. `conversations`
/// stops returning threads for a blocked contact server-side, so this exists for
/// immediacy and not for enforcement. ⚠️ The two can therefore disagree for one
/// refresh, in both directions: a thread blocked on another device is still in this
/// list until the next read, and a thread blocked here is gone from the UI before
/// the server's own filter has been observed. Neither is a failure and nothing may
/// report one.
///
/// ⛔ KEYED ON `contactId` AND NOT ON A PHONE NUMBER. A number has to be
/// re-normalised to be compared (bare digits server-side, and the wire carries E.164
/// with punctuation), and doing that here would be a second normaliser that could
/// disagree with the server's phone normaliser — the classic failure where two sides
/// of a comparison normalise differently and the read silently returns nothing.
/// The server answers a `contactId` for every block,
/// including one asked for by number, precisely so a client never has to.
///
/// ⚠️ THE WORKSPACE IS CARRIED WITH THE SET RATHER THAN ASSUMED. ``ContactsView``
/// and ``InboxView`` are rebuilt on a workspace switch but this object is not, so a
/// set loaded for one tenant must not be read as another's — ``isBlocked(_:in:)``
/// refuses rather than answering false, because "I do not know" and "not blocked"
/// are different and only one of them may hide a badge.
@MainActor
@Observable
final class BlockedContactsStore {
    /// The blocked contact ids for ``loadedWorkspaceId``.
    ///
    /// ⚠️ ONLY THE LIVE BLOCKS. The route may answer a row whose `blockedAt` is null
    /// (see ``ContactsRepository/blocked(workspaceId:)``, which returns rows as
    /// sent), and a set that included those would badge a caller who is not blocked.
    private(set) var blockedContactIds: Set<String> = []

    /// ⛔ nil UNTIL A READ HAS SUCCEEDED, WHICH IS WHAT MAKES THE SET SAFE TO TRUST.
    /// It is set on success only: a failed read leaves it as it was, so a transient
    /// outage does not turn every badge off.
    private(set) var loadedWorkspaceId: String?

    /// Whether a write is in flight. Controls disable rather than re-firing.
    ///
    /// ⚠️ ONE FLAG FOR THE WHOLE STORE, not one per contact. Two blocks at once is
    /// not a thing a person does on a phone, and a per-contact map would be state
    /// nothing reads.
    private(set) var busy = false

    /// What the last write had to say about itself, for the screen that asked.
    private(set) var failure: FailureText?

    private let contacts: ContactsRepository

    init(contacts: ContactsRepository) {
        self.contacts = contacts
    }

    // MARK: - Reads

    /// Whether this contact is blocked in this workspace.
    ///
    /// ⛔ FALSE FOR A WORKSPACE THIS STORE HAS NOT LOADED, AND THAT IS THE SAFE
    /// DIRECTION HERE RATHER THAN THE CAUTIOUS-LOOKING ONE. The alternative — badge
    /// on unknown — would put "Blocked" on every contact in a workspace whose read
    /// had not landed yet, which is a claim about moderation that was never made.
    /// The honest absence is no badge plus a Block control that the server will
    /// coerce correctly if it is already blocked (the route takes a STATE).
    func isBlocked(_ contactId: String, in workspaceId: String) -> Bool {
        guard loadedWorkspaceId == workspaceId else { return false }
        return blockedContactIds.contains(contactId)
    }

    /// Whether this inbox thread's counterpart is blocked.
    ///
    /// ⛔ IT ANSWERS FALSE FOR A THREAD WITH NO `contactId`, DELIBERATELY. An
    /// address-keyed thread is one whose counterpart never resolved to a `Contact`
    /// row, so there is nothing to compare — and the alternative is normalising the
    /// address here to match a number, which is the second-normaliser trap on this
    /// type's own ⛔. Such a thread can still be blocked (the write accepts a raw
    /// number and the server upserts the row); it simply is not filtered out until
    /// the next read, which is the server's filter doing the work.
    func isBlocked(conversation: ConversationSummary, in workspaceId: String) -> Bool {
        guard let contactId = conversation.contactId else { return false }
        return isBlocked(contactId, in: workspaceId)
    }

    /// Re-read the set.
    ///
    /// ⛔ SILENT ON FAILURE AND IT LEAVES THE PREVIOUS SET IN PLACE. This is a read
    /// nobody asked for — it runs when a list appears — so a sentence about it would
    /// land on a screen whose actual content loaded fine. What it must not do is
    /// clear the set, because that would take a Blocked badge off a caller who is
    /// still blocked.
    func refresh(workspaceId: String) async {
        guard case let .success(rows) = await contacts.blocked(workspaceId: workspaceId) else { return }
        blockedContactIds = Set(rows.filter(\.isBlocked).map(\.contactId))
        loadedWorkspaceId = workspaceId
    }

    // MARK: - Writes

    /// Block or unblock a caller. Answers true once the server has confirmed.
    ///
    /// ⛔ THE SET IS UPDATED FROM THE REPLY, NEVER FROM THE REQUEST. The route
    /// answers the resulting state and the `contactId` it applied to — which for a
    /// block asked for by number is a row this caller had never seen, because the
    /// server upserts it. Recording the requested value instead would leave the
    /// badge and the database free to disagree after a coerced write.
    ///
    /// ⚠️ THE CALLER DECIDES WHAT TO DO WITH `true`. The thread screen pops and the
    /// contact screen stays put, and neither belongs here: this type knows who is
    /// blocked and nothing about navigation.
    ///
    /// ⚠️ IT REFUSES A SECOND CONCURRENT WRITE rather than queueing one. The route
    /// is idempotent, so the cost of a lost second tap is nothing; the cost of two
    /// in flight is a set written by whichever answered last.
    func setBlocked(
        workspaceId: String,
        subject: BlockSubject,
        blocked: Bool
    ) async -> Bool {
        guard !busy else { return false }
        busy = true
        failure = nil

        let outcome = await contacts.setBlocked(workspaceId: workspaceId, subject: subject, blocked: blocked)
        busy = false

        switch outcome {
        case let .success(response):
            adopt(response, in: workspaceId)
            return true
        case let .failure(error):
            failure = FailureText.from(error)
            return false
        }
    }

    /// Dismiss the last write's failure without re-reading anything.
    func clearFailure() {
        failure = nil
    }

    // MARK: - Internals

    /// Fold one write's answer into the set.
    ///
    /// ⛔ IT ALSO CLAIMS `loadedWorkspaceId`, WHICH IS WHAT MAKES A BLOCK VISIBLE
    /// BEFORE ANY LIST READ HAS RUN. A thread opened from a push notification can be
    /// the first thing an operator touches, so the read that populates this store may
    /// never have happened — and without this line the badge would stay off until it
    /// did, which is precisely the "immediately" Guideline 1.2 asks about.
    /// ⚠️ Safe because the answer IS for this workspace: the request carried it.
    private func adopt(_ response: ContactBlockResponse, in workspaceId: String) {
        if loadedWorkspaceId != workspaceId {
            blockedContactIds = []
            loadedWorkspaceId = workspaceId
        }
        if response.isBlocked {
            blockedContactIds.insert(response.contactId)
        } else {
            blockedContactIds.remove(response.contactId)
        }
    }
}
