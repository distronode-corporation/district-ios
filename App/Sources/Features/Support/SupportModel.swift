import DistrictData
import DistrictModel
import Foundation
import Observation

/// The support request list, and the form that raises a new one.
///
/// ⛔ "SUPPORT" IS THE TENANT'S TICKETS **WITH DISTRONODE**. Its mirror image is the
/// desk, which is their own customers' tickets with them. Nothing on this model may
/// be reworded so that it could describe either.
///
/// ⛔ THE IDEMPOTENCY KEY IS MINTED ONCE PER COMPOSED DRAFT AND SURVIVES A FAILED
/// SUBMIT, WHICH IS THE WHOLE REASON THIS WRITE IS REPEATABLE AT ALL. The server
/// claims the key before it calls Atlassian and answers a re-used one with
/// `deduplicated: true`, so a retry carrying the SAME key collapses onto the first
/// request — while a retry that minted a fresh one would put a second ticket in a
/// human's queue. ⚠️ The web mints it per SUBMIT, which is correct there because its
/// form has no retry affordance; here the button comes back after a failure, so the
/// key has to outlive the attempt. It is cleared when a draft is abandoned or
/// succeeds, never between attempts at the same draft.
///
/// ⛔ EVERY ROUTE BEHIND THIS SCREEN EXCLUDES `viewer`, THE READS INCLUDED, which is
/// the opposite split from knowledge and messaging. So there is no read-only mode
/// here: ``RouteGate`` hides the destination outright and this model still re-checks
/// ``canWrite`` at each call site, because a control that was not drawn is not a
/// boundary and the server's `requireWorkspaceRole` is.
///
/// ⚠️ NO CACHE AND NO POLLING. The list is opened to find out whether somebody has
/// answered, which is the one question a stale copy is worst at.
@MainActor
@Observable
final class SupportModel {
    private(set) var list: SupportListState = .loading

    /// Whether the compose form is on screen.
    private(set) var composing = false

    private(set) var draftKind: SupportRequestKind = .problem
    private(set) var draftSubject = ""
    private(set) var draftMessage = ""

    /// ⚠️ True when the last submit was refused locally for a blank field. Retired by
    /// the next keystroke: leaving "a subject and a description are both needed" up
    /// while somebody types the subject is a complaint about state that has gone.
    private(set) var draftRejected = false

    private(set) var create: SupportWriteState = .idle

    /// ⛔ False for `viewer` and for a role that did not parse. ``RouteGate`` should
    /// already have hidden the destination, so this is the belt to that braces.
    let canWrite: Bool

    /// The one key this draft will be submitted under, for as long as it exists.
    /// See the ⛔ on the type.
    private var idempotencyKey: String?

    private let support: SupportRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        support = container.support
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    var requests: [SupportRequestSummary] {
        guard case let .ready(rows) = list else { return [] }
        return rows
    }

    /// ⛔ BOTH FIELDS ARE REQUIRED, WHICH IS THE ROUTE'S OWN RULE rather than a
    /// client invention: it answers 400 for a blank either. Checked here so nobody
    /// is charged a round trip to be told.
    var canSubmit: Bool {
        canWrite && !create.isSending && create.isArmed
            && !trimmed(draftSubject).isEmpty && !trimmed(draftMessage).isEmpty
    }

    /// Every request this workspace has raised.
    ///
    /// ⛔ A FAILED READ IS ITS OWN STATE AND NEVER AN EMPTY LIST. See
    /// ``SupportListState``.
    ///
    /// ⚠️ IT RETIRES THE SUBMIT NOTICE, AND ONLY ON A SUCCESSFUL READ. On a failed
    /// one that notice may be the only record that a request was filed at all.
    func load() async {
        list = .loading
        switch await support.requests(workspaceId: workspaceId) {
        case let .success(rows):
            list = .ready(rows)
            create = .idle
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
    }

    // MARK: - Composing

    /// ⛔ MINTS THE KEY. One draft, one key, however many attempts it takes.
    func beginCompose() {
        guard canWrite else { return }
        composing = true
        create = .idle
        draftRejected = false
        idempotencyKey = Self.newIdempotencyKey()
    }

    /// ⛔ DISCARDS THE KEY WITH THE DRAFT. A key kept past the text it was minted for
    /// would make the NEXT, different request deduplicate against the previous one
    /// and never reach the queue.
    func cancelCompose() {
        guard !create.isSending else { return }
        composing = false
        draftSubject = ""
        draftMessage = ""
        draftKind = .problem
        draftRejected = false
        idempotencyKey = nil
        create = .idle
    }

    /// ⚠️ WRITTEN THROUGH METHODS RATHER THAN BOUND DIRECTLY, and not only so a
    /// keystroke can clear the rejection notice: `didSet` on a stored property of an
    /// `@Observable` type is not expressible, because the macro rewrites it into a
    /// computed property and Swift does not allow observers on one.
    func editSubject(_ value: String) {
        draftSubject = value
        draftRejected = false
    }

    func editMessage(_ value: String) {
        draftMessage = value
        draftRejected = false
    }

    func selectKind(_ kind: SupportRequestKind) {
        draftKind = kind
        draftRejected = false
    }

    /// Raise the request.
    ///
    /// ⛔ ALL THREE 200 BRANCHES ARE SUCCESSES AND EACH GETS ITS OWN SENTENCE. In
    /// particular `deduplicated` closes the form and reads as "already open" rather
    /// than as an error, because it means the key did its job.
    ///
    /// ⛔ THE DRAFT SURVIVES A FAILURE, AND SO DOES THE KEY. Losing typed text
    /// because a request failed would be two losses for one fault, and re-arming the
    /// button under a NEW key would file a duplicate.
    func submit() async {
        guard canWrite, !create.isSending, create.isArmed else { return }
        guard canSubmit else {
            draftRejected = true
            return
        }
        create = .sending
        let result = await support.create(
            workspaceId: workspaceId,
            kind: draftKind,
            subject: trimmed(draftSubject),
            message: trimmed(draftMessage),
            idempotencyKey: idempotencyKey
        )
        switch result {
        case let .success(filing):
            composing = false
            draftSubject = ""
            draftMessage = ""
            draftKind = .problem
            idempotencyKey = nil
            create = .done(SupportFilingCopy.notice(for: filing))
            await reload()
        case let .failure(error):
            // ⚠️ `.idempotent` BECAUSE THE KEY IS STILL IN HAND. This is the one
            // write on the surface where a repeat is honest whatever failed, and it
            // is honest only because `idempotencyKey` was not cleared above.
            create = .failed(FailureText.from(error), .after(error, .idempotent))
        }
    }

    /// ⚠️ Retires the notice without a re-read.
    func dismissNotice() {
        guard !create.isSending else { return }
        create = .idle
    }

    // MARK: - Internals

    /// ⚠️ THE LIST ONLY, AND A FAILED RE-READ DOES NOT OVERWRITE THE SUBMIT NOTICE.
    /// That notice is the only record that the request was filed; replacing it with
    /// a read failure would tell somebody their request did not go through.
    private func reload() async {
        switch await support.requests(workspaceId: workspaceId) {
        case let .success(rows):
            list = .ready(rows)
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
    }

    /// ⛔ LOWERCASED, DELIBERATELY. `Foundation`'s `UUID.uuidString` is UPPERCASE and
    /// the route validates with `z.string().uuid()`; whether that validator is
    /// case-insensitive is not something this client should depend on, and a lowercase
    /// v4 uuid satisfies every spelling of that rule either way. ⚠️ The failure it
    /// avoids is a **400** on the one field whose whole job is to stop a duplicate ticket.
    private static func newIdempotencyKey() -> String {
        UUID().uuidString.lowercased()
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
