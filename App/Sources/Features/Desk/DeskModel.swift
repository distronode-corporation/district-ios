import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// Whether this workspace runs a desk at all.
///
/// ⛔ THREE CASES, AND COLLAPSING ANY TWO OF THEM IS THE MISTAKE THIS TYPE EXISTS TO
/// MAKE UNWRITABLE. `off` means the queue is empty BY CONSTRUCTION and nothing is
/// being recorded; `unknown` means the settings read FAILED. Rendering `unknown` as
/// `off` sends an operator to switch on something that may already be on; rendering
/// either as an empty ticket list says "no customer has ever contacted you", which is
/// untrue in both. This client's rule is that a failure is never rendered as an
/// absence.
///
/// ⚠️ MODELLED HERE RATHER THAN AS A `Bool?` ON THE DTO. The wire always carries a
/// boolean — a workspace with no row gets the server's defaults — so the third state
/// is a property of the REQUEST's outcome, and putting it in the DTO would invent a
/// shape no response can produce.
/// ⚠️ NOT `Equatable`, DELIBERATELY. ``FailureText`` declares no conformance, so
/// synthesis would fail here and adding one to a type six other features share is a
/// wider change than this needs. ``isOff`` is the only comparison anything makes.
enum DeskAvailability {
    case checking
    case on
    case off
    /// ⛔ The read failed. Not the same as `off`. See the ⛔ on the type.
    case unknown(FailureText)

    /// ⛔ THE ONE TEST THAT DECIDES WHETHER TO SKIP THE QUEUE READ, and it must stay
    /// this narrow: `checking` and `unknown` both fall through to loading the queue,
    /// because neither of them is evidence that there are no tickets.
    var isOff: Bool {
        if case .off = self {
            return true
        }
        return false
    }
}

/// The queue's own load state.
///
/// ⚠️ SEPARATE FROM ``DeskAvailability`` BECAUSE THEY FAIL INDEPENDENTLY AND MEAN
/// DIFFERENT THINGS. A workspace whose desk is demonstrably ON can still have a
/// queue read that failed, and that is a retry rather than a settings problem.
enum DeskQueueState {
    case loading
    /// ⛔ AN EMPTY ARRAY IS A REAL ANSWER. It is a workspace whose customers have not
    /// written in, which is where every workspace with a desk starts.
    case ready([DeskTicketSummary])
    case failed(FailureText)
}

/// District Desk: the tenant's OWN customers' queue.
///
/// ⛔ NOT THE SUPPORT DESK. That surface is the tenant raising something with
/// DISTRONODE; this one is the tenant's customers raising something with the TENANT.
/// Every sentence this model hands a view comes from ``DeskCopy``, which exists to
/// keep the two apart.
///
/// ⛔ THE SETTINGS READ RUNS FIRST AND THE QUEUE IS NOT ASKED FOR WHEN THE DESK IS
/// EXPLICITLY OFF. Not an optimisation: the queue would answer an empty list, which is
/// exactly the picture that must not be shown for a desk that is switched off. On
/// `unknown` the queue IS still loaded, because a failed settings read says nothing
/// about whether tickets exist, and refusing to show a queue we can read would be the
/// same conflation pointing the other way.
///
/// ⛔ EVERY ROUTE BEHIND THIS SCREEN EXCLUDES `viewer` SERVER-SIDE, THE READS
/// INCLUDED, which is why ``RouteGate`` hides the destination outright rather than
/// disabling its controls. ``canWrite`` is still re-checked at each write's call site:
/// a control that was not drawn is not a boundary, and the server's
/// `requireWorkspaceRole` is.
///
/// ⚠️ THE WHOLE QUEUE IS READ AND FILTERED LOCALLY. The route accepts a `status`
/// parameter, but the chips carry counts, so a server-side filter would mean one
/// request per chip and the counts could disagree with each other between responses.
@MainActor
@Observable
final class DeskModel {
    private(set) var availability: DeskAvailability = .checking
    private(set) var queue: DeskQueueState = .loading

    /// ⚠️ nil is "all". A `DeskTicketStatus?` rather than a widened enum with an `all`
    /// case, so the filter and the wire vocabulary cannot drift.
    private(set) var filter: DeskTicketStatus?

    private(set) var notice: String?

    /// ⛔ False for `viewer` and for a role that did not parse. See the ⛔ on the type.
    let canWrite: Bool

    let workspaceId: String

    private let desk: DeskRepository

    /// ⛔ THE CONTAINER'S ONE REPOSITORY, NEVER ONE CONSTRUCTED HERE. It wraps the
    /// container's ONE ``ApiClient``, so it reaches the one `TokenRefreshCoordinator`
    /// and the one credential closure; what must never happen is a `DeskRepository`
    /// built from a freshly constructed `ApiClient`. See the ⛔ on ``AppContainer``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        desk = container.desk
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    /// The rows the current filter admits.
    var visibleTickets: [DeskTicketSummary] {
        guard case let .ready(rows) = queue else { return [] }
        guard let filter else { return rows }
        return rows.filter { $0.status == filter.rawValue }
    }

    /// Every row the queue answered, filter ignored. What the chips count.
    var allTickets: [DeskTicketSummary] {
        guard case let .ready(rows) = queue else { return [] }
        return rows
    }

    /// How many tickets wear one status.
    ///
    /// ⚠️ COUNTED OVER THE WHOLE QUEUE RATHER THAN THE VISIBLE ROWS, which is the only
    /// way a chip can say how many it would reveal.
    func count(of status: DeskTicketStatus?) -> Int {
        guard let status else { return allTickets.count }
        // ⚠️ `filter { }.count` RATHER THAN `count(where:)`. The latter is newer
        // standard-library surface, and the older spelling compiles on every toolchain
        // this target might meet.
        return allTickets.filter { $0.status == status.rawValue }.count
    }

    func select(_ status: DeskTicketStatus?) {
        filter = status
    }

    func dismissNotice() {
        notice = nil
    }

    /// Read the settings, then the queue.
    ///
    /// ⛔ IN THAT ORDER, AND THE QUEUE IS SKIPPED ONLY FOR AN EXPLICIT `off`. See the
    /// ⛔ on the type: an empty list is the wrong picture for a disabled desk and the
    /// right one for an unknown state, because in the second case the tickets may
    /// genuinely be there.
    ///
    /// ⚠️ BOTH READS ARE IDEMPOTENT GETs, so replaying this is safe and it is what the
    /// pull-to-refresh and the post-write reloads call.
    func load() async {
        availability = .checking
        queue = .loading
        switch await desk.settings(workspaceId: workspaceId) {
        case let .success(settings):
            availability = settings.enabled ? .on : .off
        case let .failure(error):
            availability = .unknown(FailureText.from(error))
        }
        guard !availability.isOff else { return }
        await reloadQueue()
    }

    /// Re-read the queue alone.
    ///
    /// ⚠️ THE QUEUE ONLY. A write must not re-read the SETTINGS and quietly move the
    /// screen between its three states because of something nobody asked about.
    func reloadQueue() async {
        switch await desk.tickets(workspaceId: workspaceId) {
        case let .success(rows):
            queue = .ready(rows)
        case let .failure(error):
            queue = .failed(FailureText.from(error))
        }
    }

    /// Raise a ticket on a customer's behalf.
    ///
    /// ⛔ THE IDEMPOTENCY KEY IS MINTED HERE, PER SUBMIT, AND MUST NOT BE HOISTED INTO
    /// A STORED PROPERTY. A key held across submits swallows the SECOND ticket as a
    /// duplicate; a key minted per RENDER is no key at all. One tap, one key.
    ///
    /// ⛔ NOTHING RETRIES THIS. The server's claim is Redis-backed and fail-open, so a
    /// resend during an outage puts a second ticket in a human's queue.
    ///
    /// ⚠️ THE DRAFT IS NOT CLEARED HERE. ``DeskComposerState`` owns it and the view
    /// clears it on a confirmed success, so a failed submit leaves what was typed on
    /// screen — losing a typed ticket to a failed request would be two losses for one
    /// fault.
    func createTicket(_ draft: DeskComposerState) async -> Bool {
        guard canWrite else { return false }
        guard draft.isComplete else {
            notice = DeskCopy.createIncomplete
            return false
        }
        notice = nil
        let result = await desk.createTicket(
            workspaceId: workspaceId,
            // ⚠️ THE THREE REQUESTER BOXES GO OVER AS TYPED. The repository trims each
            // to nil, because the route permits them ABSENT and not present-and-empty
            // — an empty `requesterEmail` fails `.email()` and takes the whole request
            // down. Trimming here as well would be a second copy of that rule.
            draft: DeskTicketDraft(
                subject: draft.trimmedSubject,
                message: draft.trimmedMessage,
                requesterName: draft.requesterName,
                requesterEmail: draft.requesterEmail,
                requesterPhone: draft.requesterPhone
            ),
            idempotencyKey: UUID().uuidString
        )
        switch result {
        case let .success(creation):
            // ⚠️ A DEDUPLICATED CREATE IS A SUCCESS AND SAYS SO. The key already
            // produced a ticket, which is what the key is for; reporting it as a
            // failure would make a retried submit look broken and invite a third.
            if case .deduplicated = creation {
                notice = DeskCopy.createDeduplicated
            } else {
                notice = DeskCopy.createSucceeded
            }
            await reloadQueue()
            return true
        case let .failure(error):
            notice = FailureText.from(error).message
            return false
        }
    }
}

/// The new-ticket form's fields.
///
/// ⛔ A VALUE THE VIEW OWNS RATHER THAN STATE ON THE MODEL, so a dismissed sheet takes
/// its draft with it and a reopened one starts clean. ⚠️ It is also what keeps the
/// trim-to-nil rule in one place: the repository refuses to send an empty
/// `requesterEmail` because that fails `.email()` server-side and takes the whole
/// object down, and this type never hands it one that would.
struct DeskComposerState {
    var subject = ""
    var message = ""
    var requesterName = ""
    var requesterEmail = ""
    var requesterPhone = ""

    var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⛔ THE ROUTE'S OWN RULE: a subject of at least 3 characters and a non-empty
    /// message. Checked here so an operator is not charged a round trip to be told,
    /// and the server still decides.
    var isComplete: Bool {
        trimmedSubject.count >= 3 && !trimmedMessage.isEmpty
    }
}
