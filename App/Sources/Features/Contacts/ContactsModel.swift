import DistrictData
import DistrictModel
import Foundation
import Observation

/// What the contact list is showing.
///
/// ⛔ `empty` IS REACHABLE ONLY AFTER A SUCCESSFUL FIRST PAGE, exactly as in
/// ``CallLogState``. "We could not look" and "there is nothing" read to a paying
/// operator as data loss when confused, and an empty CRM is what a brand new
/// workspace legitimately has on day one — so the two states must never share a
/// screen.
///
/// ⛔ AN APPEND FAILURE STAYS INSIDE `content`. A failed extra page must never
/// replace rows the user is already reading.
enum ContactsState {
    /// - Parameters:
    ///   - isEnd: the feed has reported its end, so there is no footer to draw.
    ///   - appending: a further window is in flight.
    ///   - appendFailure: the last append failed. Rows above it are still valid.
    case loading
    case content(rows: [Contact], isEnd: Bool, appending: Bool, appendFailure: FailureText?)
    case empty
    case failed(FailureText)
}

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
    /// ⚠️ Under 100, which the server clamps to, and well over its default of 10.
    /// See ``OffsetPager/loadNext(limit:)``.
    static let pageSize = 30

    /// ⚠️ A CEILING ON CONSECUTIVE FULLY-DEDUPLICATED WINDOWS, not a page limit.
    private static let maxEmptyWindows = 4

    private(set) var state: ContactsState = .loading
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
    private let pager: OffsetPager<Contact>
    private var rows: [Contact] = []

    /// ⚠️ BUILT FROM THE CONTAINER'S ONE REPOSITORY. A second `ContactsRepository`
    /// would carry a second `ApiClient` and reach a second
    /// `TokenRefreshCoordinator`; see the ⛔ on ``AppContainer``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        canMutate = WorkspaceRole.allowsMutation(role)
        contacts = container.contacts
        pager = container.contacts.pager(workspaceId: workspaceId)
    }

    // MARK: - The list

    /// The first page, from a clean pager.
    ///
    /// ⚠️ RESETS BEFORE FETCHING so it is idempotent: a retry, or a re-appearance
    /// of the view, starts from offset 0 with an empty dedup set.
    func loadFirst() async {
        state = .loading
        await restart()
    }

    /// Pull to refresh.
    ///
    /// ⚠️ DOES NOT SET `loading`, so the rows stay on screen while the request
    /// runs. Replacing a populated list with a spinner throws away what the user
    /// was reading.
    func refresh() async {
        await restart()
    }

    /// One more window, appended.
    func loadMore() async {
        guard case let .content(rows, isEnd, appending, _) = state else { return }
        guard !isEnd, !appending else { return }
        state = .content(rows: rows, isEnd: isEnd, appending: true, appendFailure: nil)

        switch await loadWindow() {
        case let .success(slice):
            self.rows.append(contentsOf: slice.items)
            state = .content(rows: self.rows, isEnd: slice.isEnd, appending: false, appendFailure: nil)
        case let .failure(error):
            // ⛔ THE ROWS SURVIVE. Only the footer reports this.
            state = .content(
                rows: self.rows,
                isEnd: isEnd,
                appending: false,
                appendFailure: FailureText.from(error)
            )
        }
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
            await restart()
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

    // MARK: - Internals

    private func restart() async {
        await pager.reset()
        switch await loadWindow() {
        case let .success(slice):
            rows = slice.items
            state = rows.isEmpty
                ? .empty
                : .content(rows: rows, isEnd: slice.isEnd, appending: false, appendFailure: nil)
        case let .failure(error):
            // ⛔ THE ROWS ARE DROPPED ON PURPOSE. The pager has just been reset, so
            // keeping them would leave the accumulator and the pager's offsets
            // describing different feeds, and the next append would duplicate.
            rows = []
            state = .failed(FailureText.from(error))
        }
    }

    /// One window that either carries NEW rows or reaches the end.
    ///
    /// ⛔ AN EMPTY SLICE WITH `isEnd` FALSE IS NOT THE END. ``OffsetSlice`` is
    /// deduplicated, so a window whose every row had already been seen comes back
    /// empty while more rows remain; the list's trigger is the LAST ROW APPEARING,
    /// and an empty slice adds no new last row, so nothing would ever ask again.
    ///
    /// ⚠️ BOUNDED, because "keep going until something new arrives" against a feed
    /// that is churning is an unbounded request loop.
    private func loadWindow() async -> Result<ContactWindow, ApiError> {
        var isEnd = false
        for _ in 0 ..< Self.maxEmptyWindows {
            switch await pager.loadNext(limit: Self.pageSize) {
            case let .success(slice):
                isEnd = slice.isEnd
                guard slice.items.isEmpty, !slice.isEnd else {
                    return .success(ContactWindow(items: slice.items, isEnd: slice.isEnd))
                }
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(ContactWindow(items: [], isEnd: isEnd))
    }
}

/// What ``ContactsModel/loadWindow()`` resolved to.
///
/// ⚠️ ITS OWN TYPE RATHER THAN ``OffsetSlice``, which cannot be built here: that
/// type declares no explicit initialiser, so its synthesised memberwise one is
/// internal to `DistrictData`. Same reason as ``CallLogModel``'s.
private struct ContactWindow {
    let items: [Contact]
    let isEnd: Bool
}
