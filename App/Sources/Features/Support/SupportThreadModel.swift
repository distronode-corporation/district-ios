import DistrictData
import DistrictModel
import Foundation
import Observation

/// One support request: its conversation, a reply, and the close.
///
/// ⛔ THE THREAD IS SHOWN IN FULL, AND THE RULE THAT SAYS OTHERWISE BELONGS TO A
/// DIFFERENT SURFACE. `/api/internal/support-lookup` — the VOICE path — returns
/// status and never a body, because a phone call is authenticated by spoofable
/// caller ID. This screen runs under the operator's own session bearer inside an
/// authenticated app, so withholding the conversation would make it useless without
/// protecting anything.
///
/// ⛔ NEITHER WRITE IS RETRIED AND NEITHER RE-ARMS ITSELF AFTER AN AMBIGUOUS
/// FAILURE. Both post a PUBLIC comment: the reply posts the customer's own text
/// always, and the close posts an audit note naming who asked between resolving the
/// transition and applying it, so a repeat that still finds one leaves a second
/// visible message in a thread the customer reads. ``SupportResubmit`` holds the
/// rule; this model applies it at both call sites.
@MainActor
@Observable
final class SupportThreadModel {
    private(set) var thread: SupportThreadState = .loading

    private(set) var draftReply = ""

    private(set) var reply: SupportWriteState = .idle
    private(set) var close: SupportWriteState = .idle

    /// Replies posted during this visit, appended to what the read returned.
    ///
    /// ⛔ THE ECHOED MESSAGE IS APPENDED RATHER THAN THE TYPED TEXT. It carries
    /// Atlassian's own comment id and the server's timestamp, so the thread on screen
    /// agrees with the next read; one built from the local draft does not. ⚠️ Cleared
    /// only by ``load()``, which is safe because the detail route syncs the mirror
    /// before it reads, so a fresh answer already contains them.
    private(set) var postedReplies: [SupportMessage] = []

    /// The resolved status this workspace closed the request to, once it has.
    ///
    /// ⛔ A LOCAL OVERRIDE RATHER THAN A REBUILT DETAIL, because
    /// ``SupportRequestDetail`` is an all-`let` wire type this target cannot
    /// construct — and inventing one would mean a client asserting a shape the server
    /// did not send. ⚠️ IT IS NEVER CLEARED BY A LATER READ. The close writes our own
    /// row synchronously and then the detail route re-reads Atlassian, so a read that
    /// raced the vendor could answer the pre-close status and put the button back on a
    /// request that is already closed. Only the server told us this, and only once.
    private(set) var closedStatusName: String?

    /// ⛔ False for `viewer` and a role that did not parse. ``RouteGate`` hides this
    /// destination from them outright; this is the belt to that braces, because a
    /// control that was not drawn is not a boundary.
    let canWrite: Bool

    private let support: SupportRepository
    private let workspaceId: String
    private let key: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, key: String) {
        support = container.support
        self.workspaceId = workspaceId
        self.key = key
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    var detail: SupportRequestDetail? {
        guard case let .ready(value) = thread else { return nil }
        return value
    }

    /// The conversation as it stands: what the server returned, plus anything posted
    /// since.
    var messages: [SupportMessage] {
        (detail?.messages ?? []) + postedReplies
    }

    /// The status to show, preferring what the close told us. See
    /// ``closedStatusName``.
    var statusName: String {
        closedStatusName ?? detail?.statusName ?? SupportCopy.unfiledStatus
    }

    /// ⛔ WHETHER THIS REQUEST IS FINISHED, ANSWERED THROUGH THE HELPER AND NEVER BY
    /// AN `==`. The category column carries two spellings at once server-side and a
    /// literal comparison is silently wrong for half the corpus.
    var isResolved: Bool {
        closedStatusName != nil || detail?.isResolved == true
    }

    /// ⛔ THE SERVER'S `closeable` IS ADOPTED RATHER THAN RE-DERIVED. The obvious
    /// derivation, `!== "done"`, is true for every resolved request and would offer
    /// Close on tickets that are already closed, forever. A client that recomputed it
    /// would be free to make that mistake.
    var canClose: Bool {
        canWrite && closedStatusName == nil && detail?.closeable == true && close.isArmed
    }

    /// ⛔ GATED ON `filed`, NOT ON THE KEY ALONE. A request between its local claim
    /// and the Atlassian call has no thread to post into, and the route answers 409
    /// rather than accepting a message it would then drop.
    var canReply: Bool {
        canWrite && detail?.filed == true && reply.isArmed && !trimmed(draftReply).isEmpty
    }

    /// The request and its conversation.
    ///
    /// ⛔ IT CLEARS THE POSTED REPLIES ONLY ON A SUCCESSFUL READ, because on a failed
    /// one they are the only copy of messages this person has already sent.
    func load() async {
        thread = .loading
        switch await support.request(workspaceId: workspaceId, key: key) {
        case let .success(detail):
            thread = .ready(detail)
            postedReplies = []
            reply = .idle
        case let .failure(error):
            thread = .failed(FailureText.from(error))
        }
    }

    func editReply(_ value: String) {
        draftReply = value
    }

    /// Post a reply.
    ///
    /// ⛔ NOT IDEMPOTENT: a repeat is a second copy in the customer's own thread and
    /// a second notification to the agent. The failure is therefore classified with
    /// ``SupportWriteRepeat/once``, so only a 4xx re-arms the button.
    ///
    /// ⛔ THE DRAFT SURVIVES A FAILURE. If nothing was posted the text is still
    /// needed; if something was, the operator can read it against the thread before
    /// deciding. Clearing it would destroy the only copy either way.
    func sendReply() async {
        guard canWrite, canReply else { return }
        let text = trimmed(draftReply)
        reply = .sending
        switch await support.reply(workspaceId: workspaceId, key: key, body: text) {
        case let .success(message):
            postedReplies.append(message)
            draftReply = ""
            reply = .idle
        case let .failure(error):
            reply = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    /// Close the request.
    ///
    /// ⛔ NOT IDEMPOTENT IN THE ONLY WAY THAT MATTERS TO A CUSTOMER. The transition
    /// converges, but the server posts a public "Closed at the requester's request
    /// by …" note between resolving that transition and applying it, so a repeat that
    /// still finds one leaves a second note in a thread they read.
    /// ``SupportWriteRepeat/once``.
    ///
    /// ⛔ THE SERVER'S `statusName` IS ADOPTED AND THE SCREEN IS NOT RE-READ. The
    /// close already told us the outcome, and a re-read could race Atlassian and
    /// answer the pre-close status, which would put the button back on a request that
    /// is closed. See ``closedStatusName``.
    func closeRequest() async {
        guard canWrite, canClose else { return }
        close = .sending
        switch await support.close(workspaceId: workspaceId, key: key) {
        case let .success(statusName):
            closedStatusName = statusName
            close = .done(SupportCopy.closed(statusName))
        case let .failure(error):
            close = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    /// ⚠️ Retires both notices without a re-read. A write in flight keeps its own.
    func dismissNotices() {
        if !reply.isSending {
            reply = .idle
        }
        if !close.isSending, !close.refusedRepeat {
            close = .idle
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
