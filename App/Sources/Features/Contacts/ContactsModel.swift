import DistrictData
import DistrictModel
import Foundation
import Observation

/// The create-a-contact step, which is a separate state machine from the list.
///
/// ⚠️ SEPARATE BECAUSE A FAILED CREATE MUST NOT TOUCH THE LIST. The rows on
/// screen are still perfectly good; only the new contact failed, and the sentence
/// belongs in the sheet the operator is looking at.
enum CreateContactState {
    case idle
    case saving
    /// Carries the new id, so a caller could open the contact it just made.
    case created(String)
    case failed(FailureText)
}

/// The paged CRM for ONE workspace, plus creating a contact.
///
/// ⚠️ THE LIST IS THE ONE PAGED-FEED MACHINE, ``PagedFeedModel``, shared with the
/// call log rather than copied from it.
///
/// ⚠️ THE WORKSPACE IS FIXED FOR THE LIFETIME OF THIS MODEL, for the reason
/// ``CallLogModel`` gives: ``OffsetPager``'s offsets and its dedup set are only
/// meaningful within one tenant. ``ContactsView`` enforces it with
/// `.id(workspaceId)`.
///
/// ⛔ DEDUPLICATION MATTERS MORE HERE THAN ON THE CALL LOG. `contacts/bulk-create`
/// inserts an entire import in one statement, so a window's worth of rows can
/// shift between two page loads — and a duplicate id in a SwiftUI `ForEach` is a
/// rendering fault rather than a cosmetic repeat.
@MainActor
@Observable
final class ContactsModel {
    /// The paged list. ⚠️ Empty only after a successful first page; see
    /// ``PagedFeedState``.
    let feed: PagedFeedModel<Contact>

    private(set) var createState: CreateContactState = .idle

    let workspaceId: String

    /// Whether to OFFER create, rename, delete, enrich and clear. Every contacts
    /// mutation excludes `viewer` server-side.
    ///
    /// ⚠️ AN AFFORDANCE, NOT A SECURITY CONTROL, and it errs low: a nil role means
    /// "the role could not be established", never "assume client". See
    /// ``WorkspaceRole/allowsMutation(_:)``.
    let canMutate: Bool

    private let contacts: ContactsRepository

    /// ⚠️ BUILT FROM THE CONTAINER'S ONE REPOSITORY. A second `ContactsRepository`
    /// would carry a second `ApiClient` and reach a second
    /// `TokenRefreshCoordinator`; see the ⛔ on ``AppContainer``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        canMutate = WorkspaceRole.allowsMutation(role)
        contacts = container.contacts
        feed = PagedFeedModel(pager: container.contacts.pager(workspaceId: workspaceId))
    }

    // MARK: - Creating

    /// Create a contact and, on success, reload the list.
    ///
    /// ⚠️ A CONTACT NEEDS A NAME PLUS A PHONE **OR** AN EMAIL, NOT BOTH. Contacts
    /// are email-first and the database deliberately admits any number of
    /// phone-less rows, so demanding a number would refuse legitimate input. The
    /// local check refuses only when BOTH addresses are absent, which is exactly
    /// what the server would refuse anyway.
    ///
    /// ⚠️ REFUSES LOCALLY WHEN THE ROLE DOES NOT PERMIT IT, so the app never fires
    /// a request it knows will 403. That is an affordance, not a security control.
    ///
    /// ⚠️ THE LIST IS RELOADED RATHER THAN HAVING A ROW INSERTED LOCALLY. The
    /// server orders `createdAt desc` with an `id` tie-break; a locally inserted
    /// row would be guessing its own position. The reload is awaited INSIDE this
    /// call so the sheet stays up, showing "Adding…", until the list behind it is
    /// actually correct.
    func create(name: String, phoneNumber: String, email: String) async {
        guard canMutate else { return }
        if case .saving = createState {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !trimmedPhone.isEmpty || !trimmedEmail.isEmpty else { return }

        createState = .saving
        let outcome = await contacts.create(
            workspaceId: workspaceId,
            name: trimmedName,
            phoneNumber: trimmedPhone,
            email: trimmedEmail
        )
        switch outcome {
        case let .success(id):
            await feed.refresh()
            createState = .created(id)
        case let .failure(error):
            // ⚠️ A 409 arrives here as the route's own "already exists" sentence
            // rather than as a server fault. ``FailureText`` shows a 4xx message
            // verbatim precisely for this.
            createState = .failed(FailureText.from(error))
        }
    }

    /// Return to Idle, after the sheet closes or is dismissed.
    func clearCreateState() {
        createState = .idle
    }
}
