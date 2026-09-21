import DistrictData
import DistrictModel
import Foundation
import Observation

/// One ticket's load state.
enum DeskThreadState {
    case loading
    case ready(DeskTicketDetail)
    case failed(FailureText)
}

/// One ticket: its thread, a reply, and the status control.
///
/// ⛔ THE COMPOSER APPENDS ONLY WHAT THE SERVER SAYS IT WROTE. Showing the draft
/// optimistically would tell an operator their customer had been answered when the
/// message may never have been stored — the worst failure this screen can produce,
/// because the customer is waiting. ``DeskReplyOutcome`` makes the two cases explicit:
/// a posted reply carries the row, and a deduplicated one with no body means the reply
/// is safe and this response cannot show it, so the thread is REFETCHED rather than
/// left looking as though nothing was sent.
///
/// ⛔ THE ECHOED TICKET IS ADOPTED AFTER EVERY WRITE, never the value that was asked
/// for. A team reply auto-sets `waiting` unless the ticket is resolved, and resolving
/// stamps `resolvedAt` while reopening clears it — all server-side, so the row that
/// comes back carries facts the request did not.
///
/// ⛔ NOTHING HERE IS RETRIED. A resent reply appends a second message to a customer's
/// thread; the idempotency key is minted per submit and is the only protection, and it
/// is fail-open server-side.
@MainActor
@Observable
final class DeskTicketModel {
    private(set) var thread: DeskThreadState = .loading

    /// ⚠️ WRITTEN THROUGH ``editDraft(_:)`` rather than bound directly: `didSet` on a
    /// stored property of an `@Observable` type is not expressible, because the macro
    /// rewrites it into a computed property. Same shape ``KnowledgeModel`` uses.
    private(set) var draft = ""

    private(set) var busy = false
    private(set) var notice: String?

    /// ⛔ False for `viewer` and for a role that did not parse.
    let canWrite: Bool

    let ticketId: String

    private let desk: DeskRepository
    private let workspaceId: String

    /// ⛔ THE CONTAINER'S ONE REPOSITORY. See the ⛔ on
    /// ``DeskModel/init(container:workspaceId:role:)``.
    init(container: AppContainer, workspaceId: String, ticketId: String, role: WorkspaceRole?) {
        desk = container.desk
        self.workspaceId = workspaceId
        self.ticketId = ticketId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    var ticket: DeskTicketDetail? {
        guard case let .ready(detail) = thread else { return nil }
        return detail
    }

    var canSend: Bool {
        canWrite && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⚠️ A KEYSTROKE RETIRES THE NOTICE. Leaving "we could not post your reply" up
    /// while someone retypes it is a complaint about a state that no longer exists.
    func editDraft(_ value: String) {
        draft = value
        notice = nil
    }

    func dismissNotice() {
        notice = nil
    }

    func load() async {
        thread = .loading
        await reload()
    }

    /// Post a reply.
    ///
    /// ⛔ THE APPEND HAPPENS ONLY ON ``DeskReplyOutcome/posted(_:)`` AND ONLY FROM THE
    /// SERVER'S ROW. `createdAt` is a database default, so the only authoritative copy
    /// is the one the write returned; reconstructing it client-side is how two
    /// slightly different timestamps end up on one screen.
    ///
    /// ⛔ THE OTHER OUTCOME REFETCHES AND SAYS SO. The reply is safe and unduplicated
    /// and this response cannot show it, which is neither a success to stay silent
    /// about nor a failure to report.
    func sendReply() async {
        guard canSend else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        notice = nil
        let result = await desk.reply(
            workspaceId: workspaceId,
            ticketId: ticketId,
            message: body,
            // ⛔ PER SUBMIT. A key held across submits swallows the second reply.
            idempotencyKey: UUID().uuidString
        )
        switch result {
        case let .success(.posted(reply)):
            append(reply)
            draft = ""
        case .success(.deduplicatedWithoutBody):
            notice = DeskCopy.replySentNotShown
            draft = ""
            await reload()
        case let .failure(error):
            // ⚠️ THE DRAFT SURVIVES A FAILURE. Losing a typed reply because the request
            // failed would be two losses for one fault.
            notice = FailureText.from(error).message
        }
        busy = false
    }

    /// Move the ticket.
    ///
    /// ⛔ THE ECHOED STATUS IS ADOPTED, never the requested one. See the ⛔ on the type.
    func setStatus(_ status: DeskTicketStatus) async {
        guard canWrite, !busy, ticket?.status != status.rawValue else { return }
        busy = true
        notice = nil
        switch await desk.setStatus(workspaceId: workspaceId, ticketId: ticketId, status: status) {
        case let .success(summary):
            adopt(summary)
        case let .failure(error):
            notice = FailureText.from(error).message
        }
        busy = false
    }

    // MARK: - Internals

    private func reload() async {
        switch await desk.ticket(workspaceId: workspaceId, ticketId: ticketId) {
        case let .success(detail):
            thread = .ready(detail)
        case let .failure(error):
            thread = .failed(FailureText.from(error))
        }
    }

    /// ⛔ THE MERGE ITSELF LIVES IN `DistrictModel`, NOT HERE. `App/` has no test lane
    /// at all, and the field most likely to be dropped in a hand-rolled rebuild is the
    /// status — which is the one that decides whether the ticket still reads as
    /// waiting on the team. See ``DeskTicketDetail/appending(_:adopting:)``.
    ///
    /// ⚠️ NOTHING LOADED MEANS NOTHING TO APPEND TO, and a screen with no thread on it
    /// is not showing a reply anyway. Assembling half a ticket here would be the only
    /// way to make that case visible, and it would be a ticket the server never sent.
    private func append(_ reply: DeskReply) {
        guard let current = ticket else { return }
        thread = .ready(current.appending(reply.message, adopting: reply.ticket))
    }

    private func adopt(_ summary: DeskTicketSummary) {
        guard let current = ticket else { return }
        thread = .ready(current.adopting(summary))
    }
}
