import DistrictData
import DistrictModel
import Foundation
import Observation

/// A loaded contact and whatever a mutation has to say about itself.
///
/// ⚠️ THE MUTATION FAILURE IS KEPT SEPARATE FROM THE CONTACT, DELIBERATELY. A
/// failed rename does not invalidate the contact on screen; blanking it would
/// lose what the operator was reading in order to report that an edit did not
/// land. Same reasoning as Android's `ContactDetailUiState.Content`.
struct LoadedContact {
    /// ⚠️ `var` SO THE POLL CAN REPLACE JUST THIS FIELD. A background tick must
    /// leave ``saving`` and ``mutationFailure`` alone; see
    /// ``ContactDetailModel/pollWhileEnriching()``.
    var contact: Contact
    /// A mutation is in flight; controls disable rather than re-firing.
    ///
    /// ⚠️ ONE FLAG FOR EVERY MUTATION ON THE SCREEN. A rename, a delete, an
    /// enrich and a clear all end in a re-read of the same contact, so allowing a
    /// second while the first is in flight would race two writes against one read.
    var saving = false
    var mutationFailure: FailureText?
}

/// One contact, fetched by id.
enum ContactDetailState {
    case loading
    case content(LoadedContact)
    case failed(FailureText)
}

/// One contact in full: the row, its four mutations, and the dossier poll.
///
/// ⚠️ IT FETCHES BY ID RATHER THAN RECEIVING THE ROW, which is what makes the
/// screen survive process death and be openable from a push notification, where
/// an id is all the app has.
///
/// ⛔ THE POLL IS THE ONLY WAY A FINISHED DOSSIER EVER REACHES THIS SCREEN.
/// `contacts/enrich` answers immediately with `status: "pending"`; the crawl and
/// the LLM synthesis happen on a Pub/Sub subscriber and there is no push, no
/// webhook and no completion endpoint. Polling is the contract, not a shortcut.
@MainActor
@Observable
final class ContactDetailModel {
    /// ⚠️ 2.5s, MATCHING THE WEB CONSOLE'S OWN DGI POLL. Not tuned independently:
    /// the two surfaces poll the same route against the same database, and a
    /// shorter interval here would put a load on it that nothing server-side was
    /// sized for.
    private static let pollInterval = Duration.milliseconds(2500)

    private(set) var state: ContactDetailState = .loading

    /// ⛔ THE POLL'S RESTART TOKEN, AND IT IS WHAT KEEPS THE LOOP STRUCTURED.
    /// ``ContactDetailView`` attaches `.task(id: model.pollGeneration)`, so SwiftUI
    /// owns exactly one poll task, cancels it when the view disappears, and starts
    /// a fresh one when this changes. The alternative — an unstructured `Task`
    /// stored here — would need its own cancellation on disappear and would be one
    /// forgotten `cancel()` away from re-reading a contact nobody is looking at,
    /// on a route that fans out to a regional database.
    ///
    /// ⛔ IT IS BUMPED ONLY ON THE TRANSITION *INTO* AN IN-FLIGHT STATUS, NEVER ON
    /// EVERY PUBLISH. Bumping on every publish would have the poll's own re-read
    /// cancel the poll that issued it, on its first tick, forever.
    private(set) var pollGeneration = 0

    /// Whether to OFFER rename, delete, enrich and clear. All four exclude
    /// `viewer` server-side; the gate is an affordance and errs low.
    let canMutate: Bool

    private let contacts: ContactsRepository
    private let workspaceId: String
    private let contactId: String

    init(container: AppContainer, workspaceId: String, contactId: String, role: WorkspaceRole?) {
        contacts = container.contacts
        self.workspaceId = workspaceId
        self.contactId = contactId
        canMutate = WorkspaceRole.allowsMutation(role)
    }

    /// Whether a dossier is genuinely being built right now.
    ///
    /// ⛔ ALL THREE IN-FLIGHT STATUSES, NOT JUST "pending". The pipeline advances
    /// pending → crawling → synthesizing, so a check against "pending" alone
    /// reports a running enrichment as finished the moment the crawler starts.
    /// ⚠️ AND NULL IS NOT IN FLIGHT: after `clear-intel` the status is null with
    /// nothing queued. See ``DgiStatus/isInProgress(_:)``.
    var isEnriching: Bool {
        guard case let .content(loaded) = state else { return false }
        return DgiStatus.isInProgress(loaded.contact.dgiStatus)
    }

    /// Whether to offer enrichment: nothing stored and nothing running.
    ///
    /// ⛔ ONE TAP IS ONE EXTERNAL CRAWL AND ONE LLM RUN, so offering it while a
    /// crawl is running is a second billable pipeline for a contact already being
    /// enriched. The server's own rate limit is Redis-backed and FAIL-OPEN and is
    /// not a backstop for this.
    var isEnrichable: Bool {
        guard case let .content(loaded) = state else { return false }
        let status = loaded.contact.dgiStatus
        return status == nil || status == DgiStatus.failed
    }

    /// Whether there is anything to clear. ⚠️ INCLUDING A FAILED RUN: clearing is
    /// how a failed dossier's error is dismissed and the contact returned to an
    /// enrichable state.
    var isClearable: Bool {
        guard case let .content(loaded) = state else { return false }
        return loaded.contact.intelligence != nil
            || loaded.contact.company != nil
            || loaded.contact.dgiStatus != nil
    }

    // MARK: - Reads

    func load() async {
        state = .loading
        switch await contacts.detail(workspaceId: workspaceId, contactId: contactId) {
        case let .success(contact):
            publish(contact)
        case let .failure(error):
            state = .failed(Self.detailFailure(error))
        }
    }

    /// Re-read the contact on an interval until its enrichment settles.
    ///
    /// ⛔ IT WAITS BEFORE THE FIRST READ, NEVER AFTER. Whatever started this has
    /// just read the contact — that is how it knows an enrichment is in flight —
    /// so a leading request would be a duplicate answering a question already
    /// answered.
    ///
    /// ⛔ AND IT STOPS ON A FAILURE AS WELL AS ON A TERMINAL STATUS. A loop that
    /// retried through a dead session would hammer the API every few seconds from
    /// a screen the user cannot fix by waiting. The failing tick is SILENT — it is
    /// a read the operator did not ask for — so what they see is a badge that
    /// stops updating, and the reload is one tap away on the screen they already
    /// have.
    func pollWhileEnriching() async {
        while isEnriching {
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                // Cancelled: the view went away, or a newer generation replaced
                // this task. Either way nothing here should keep reading.
                return
            }
            guard await pollRead() else { return }
        }
    }

    // MARK: - Mutations

    /// Rename the contact.
    ///
    /// ⛔ THE WHOLE LOADED CONTACT GOES WITH IT, AND THAT IS NOT BELT AND
    /// BRACES: IT IS THE MINIMUM `contacts/update` ACCEPTS. The route replaces every
    /// column it knows about on every call, so a body carrying only a name clears
    /// both addresses (trips its own "a contact needs a phone number or an email
    /// address" check: **400**, before any row is touched) and blanks Budget,
    /// Timeline, Website and the LinkedIn handle. See the ⛔ on
    /// ``ContactsRepository/rename(workspaceId:contact:name:)``.
    ///
    /// ⚠️ `loaded.contact` IS THE COPY ``beginMutation()`` CLAIMED, not a re-read
    /// of `state`, so a poll tick landing mid-rename cannot swap the values this
    /// request is about to write back.
    ///
    /// ⚠️ REFUSES A BLANK OR UNCHANGED NAME LOCALLY. Neither is an edit, and the
    /// server would answer the first as a validation error.
    ///
    /// ⚠️ RE-READS RATHER THAN PATCHING THE LOCAL COPY, because the server
    /// normalises what it stores and a stale local edit that disagrees with the
    /// list is worse than a round trip.
    func rename(to name: String) async {
        // ⚠️ VALIDATED BEFORE THE SCREEN IS CLAIMED, not after. Claiming first and
        // bailing out would leave `saving` true with no request in flight, which
        // disables every control on the screen until the next successful read.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .content(current) = state else { return }
        guard !trimmed.isEmpty, trimmed != current.contact.name else { return }
        guard let loaded = beginMutation() else { return }

        let outcome = await contacts.rename(
            workspaceId: workspaceId,
            contact: loaded.contact,
            name: trimmed
        )
        await settle(outcome)
    }

    /// Queue a District Global Intelligence dossier.
    ///
    /// ⛔ ONE TAP IS ONE CRAWL AND ONE LLM RUN, AND THERE IS NO RETRY. Three
    /// guards stand in front of it and all three are deliberate: the role, the
    /// `saving` flag (so a double tap cannot buy two) and ``isEnrichable`` (so a
    /// crawl already running cannot be started again). An enrichment that timed
    /// out may well have been queued; re-sending spends a second model run.
    ///
    /// ⚠️ RE-READS RATHER THAN OPTIMISTICALLY STAMPING "pending" LOCALLY. The
    /// server has already written the status, and inventing it here would show a
    /// queued job even where the write did not land.
    func enrich() async {
        guard isEnrichable else { return }
        guard beginMutation() != nil else { return }
        // ⚠️ THE RESPONSE IS DISCARDED ON PURPOSE. It says `status: "pending"` and
        // nothing else; the authoritative status is the one the re-read below
        // pulls off the CONTACT row. The empty tuple is written out rather than
        // left to inference, so the `Result<EnrichResponse, _>` → `Result<Void, _>`
        // map is unambiguous.
        let outcome = await contacts.enrich(workspaceId: workspaceId, contactId: contactId)
        await settle(outcome.map { _ in () })
    }

    /// Clear the dossier, keeping the contact.
    ///
    /// ⛔ THE CONFIRMATION LIVES IN THE VIEW AND THIS ASSUMES IT HAPPENED. A model
    /// that owned the dialog state would make "was this confirmed" a question
    /// about two objects.
    ///
    /// ⚠️ Afterwards `dgiStatus` is NULL and nothing is queued, so the re-read
    /// both clears the badge and re-offers enrichment, and the poll stops on its
    /// own because the refreshed contact is not in flight.
    func clearIntel() async {
        guard beginMutation() != nil else { return }
        let outcome = await contacts.clearIntel(workspaceId: workspaceId, contactId: contactId)
        await settle(outcome)
    }

    /// Delete the contact. Answers true once it is gone, so the caller can pop.
    ///
    /// ⚠️ A 404 COUNTS AS SUCCESS — the repository maps it — because for a delete
    /// "it was already gone" is the outcome the user asked for, not a failure they
    /// can act on.
    ///
    /// ⛔ NO RE-READ ON SUCCESS. The row it would read no longer exists, so the
    /// read would 404 and replace a successful delete with a failure sentence.
    func delete() async -> Bool {
        guard beginMutation() != nil else { return false }
        switch await contacts.delete(workspaceId: workspaceId, contactId: contactId) {
        case .success:
            return true
        case let .failure(error):
            report(error)
            return false
        }
    }

    /// Dismiss a mutation error without reloading.
    func clearMutationFailure() {
        guard case var .content(loaded) = state else { return }
        loaded.mutationFailure = nil
        state = .content(loaded)
    }

    // MARK: - Internals

    /// Claim the screen for one mutation, or refuse.
    ///
    /// ⚠️ RETURNS THE CONTACT IT CLAIMED, so a caller cannot end up reading a
    /// second, possibly newer, copy out of `state` between the guard and the call.
    private func beginMutation() -> LoadedContact? {
        guard canMutate, case var .content(loaded) = state, !loaded.saving else { return nil }
        loaded.saving = true
        loaded.mutationFailure = nil
        state = .content(loaded)
        return loaded
    }

    /// Every mutation ends in a read, which is what clears `saving`: the flag
    /// means "a write is in flight", and a write is done exactly when its result
    /// has been read back.
    private func settle(_ outcome: Result<Void, ApiError>) async {
        switch outcome {
        case .success:
            await reread()
        case let .failure(error):
            report(error)
        }
    }

    /// Re-read WITHOUT blanking the screen.
    ///
    /// ⚠️ UNLIKE ``load()``, A FAILURE HERE DOES NOT REPLACE THE CONTACT WITH A
    /// FAILURE STATE. The contact on screen is still perfectly good and the
    /// operator has just performed an action, so the failure belongs beside it.
    private func reread() async {
        switch await contacts.detail(workspaceId: workspaceId, contactId: contactId) {
        case let .success(contact):
            publish(contact)
        case let .failure(error):
            report(error)
        }
    }

    /// One poll tick. Answers false when the loop should stop.
    ///
    /// ⛔ ONLY THE CONTACT IS REPLACED. A tick landing while a rename is in flight
    /// must not clear `saving` or a pending failure message — it is a background
    /// read, not the outcome of anything the operator did.
    private func pollRead() async -> Bool {
        switch await contacts.detail(workspaceId: workspaceId, contactId: contactId) {
        case let .success(contact):
            // ⚠️ RE-READ FROM `state` AFTER THE AWAIT, not from a copy taken
            // before it: a mutation may have published a newer `saving` or
            // failure while this request was in flight, and reinstating the old
            // one would undo it.
            guard case var .content(current) = state else { return false }
            current.contact = contact
            state = .content(current)
            return true
        case .failure:
            // ⛔ SILENT AND TERMINAL. This is a background read the operator did
            // not ask for, so it gets no failure sentence; what it must not do is
            // keep retrying against a screen whose session is dead.
            return false
        }
    }

    /// Show a contact, and open the poll's gate if this is the transition into an
    /// in-flight status.
    private func publish(_ contact: Contact) {
        let wasEnriching = isEnriching
        state = .content(LoadedContact(contact: contact))
        if !wasEnriching, isEnriching {
            pollGeneration += 1
        }
    }

    private func report(_ error: ApiError) {
        guard case var .content(loaded) = state else { return }
        loaded.saving = false
        loaded.mutationFailure = FailureText.from(error)
        state = .content(loaded)
    }

    /// ⛔ A 404 HERE DOES NOT IMPLY A MALFORMED ID. The route reads by id inside
    /// the workspace context, so another tenant's contact id is indistinguishable
    /// from one that never existed. Nothing to retry, so nothing is offered.
    private static func detailFailure(_ error: ApiError) -> FailureText {
        guard error.httpStatus == 404 else { return FailureText.from(error) }
        return FailureText(message: "This contact is not available.", action: .none)
    }
}
