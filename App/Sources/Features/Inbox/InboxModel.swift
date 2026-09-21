import DistrictData
import DistrictModel
import Foundation
import Observation

/// What the Inbox is showing.
///
/// ⛔ `empty` IS REACHABLE ONLY AFTER A SUCCESSFUL READ, and that ordering is the
/// point of having it as a separate case. "We could not look" and "there is nothing"
/// read to a paying operator as data loss when confused; see the ⛔ on ``FailureText``.
///
/// ⛔ NOT PAGED, AND THAT IS A SERVER PROPERTY RATHER THAN AN OMISSION. The
/// conversations route scans a bounded window of recent messages and GROUPS them into
/// threads, so there is no stable offset to page on. `isPartial` is a CAPTION, not a
/// pager: it says the window was full, which means older quiet threads exist that this
/// response could not see. There is nothing to fetch and nothing is broken. See the ⛔
/// on ``ConversationList``.
enum InboxState {
    case loading

    /// - Parameters:
    ///   - isPartial: the scan window was exhausted, so the list is honest but short.
    ///   - draftKeys: thread keys this author has an unsent draft on. ⛔ KEYS ONLY,
    ///     never the bodies: a draft is half-finished thought, and pulling it into a
    ///     list screen so a chip can be drawn would put it in every screenshot of the
    ///     Inbox.
    ///   - refreshing: a re-read is in flight and the rows stay on screen for it.
    case content(conversations: [ConversationSummary], isPartial: Bool, draftKeys: Set<String>, refreshing: Bool)

    case empty
    case failed(FailureText)
}

/// What the search field is showing, which REPLACES the conversation list rather
/// than filtering it.
///
/// ⛔ `empty` AND `failed` ARE SEPARATE CASES AND THIS IS THE SCREEN WHERE IT
/// MATTERS MOST. Everywhere else an empty result is unusual; here it is a
/// perfectly ordinary answer, so "nothing matched" and "we could not look" are
/// indistinguishable to a reader unless the app says which one it means. Merging
/// them would tell an operator their customer never mentioned the survey, on the
/// strength of a request that 500'd.
///
/// ⛔ `belowFloor` IS NOT `empty` EITHER. `messages/search` refuses a query under
/// two characters by answering `{success, results: []}`, so a client that fired
/// anyway would render "no matches" for a search the server never ran — a false
/// negative it invented itself. This app does not fire, and says why.
///
/// ⚠️ `searching` DISCARDS THE PREVIOUS RESULTS, unlike ``InboxState/content``'s
/// `refreshing`. A refresh asks the same question again and the old answer is
/// still the best one available; a keystroke asks a DIFFERENT question, and
/// leaving the previous hits up would attribute them to a query that never
/// returned them.
enum InboxSearchState {
    /// Not searching. The conversation list is on screen.
    case idle
    case belowFloor
    case searching
    /// - Parameter capped: the server hit its 30-result ceiling, so older matches
    ///   exist and are not here. There is nothing to fetch; see
    ///   ``MessageSearchResults/isCapped``.
    case results(hits: [MessageSearchHit], capped: Bool)
    case empty
    case failed(FailureText)
}

/// The Inbox list for ONE workspace, read with ONE role.
///
/// ⚠️ BOTH ARE FIXED FOR THE LIFETIME OF THIS MODEL, so switching either must build a
/// new one rather than mutate this. ``InboxView`` enforces the workspace half with
/// `.id(workspaceId)`.
///
/// ⚠️ REFRESHES ON DEMAND RATHER THAN POLLING. The web sidebar polls the unread count;
/// this app does not, because a foreground poll on a phone spends battery to shorten a
/// latency the user resolves by pulling to refresh. A push channel is the right answer;
/// see ``refreshFromPush()``.
@MainActor
@Observable
final class InboxModel {
    /// ⚠️ 350ms, CHOSEN AGAINST TYPING SPEED RATHER THAN AGAINST A SERVER CAP.
    /// `messages/search` publishes no rate limit of its own, so the thing being
    /// bounded is a request per keystroke over a cellular link — which spends
    /// battery and radio to answer a query the user has already replaced. Long
    /// enough that a normal typist sends one request per word, short enough that a
    /// deliberate pause feels immediate. ⚠️ NOT the composer's two seconds: that one
    /// is sized against a workspace-wide 60 writes/min budget shared with
    /// colleagues, and copying it here would make search feel broken.
    static let searchDebounce: Duration = .milliseconds(350)

    /// The server's `SEARCH_MIN_QUERY_LENGTH`.
    ///
    /// ⛔ MIRRORED SO THE APP DOES NOT SPEND A ROUND TRIP TO BE TOLD NOTHING, and
    /// the mirror is honest about which side is authoritative: the route decides,
    /// this only avoids asking. ⚠️ MEASURED IN UTF-16 UNITS, WHICH IS WHAT
    /// JavaScript's `String.length` COUNTS. A single emoji is one `Character` and
    /// TWO utf16 units, so a `.count` floor would refuse a one-emoji query the
    /// server would happily run. ⚠️ This is a COUNT and never a slice — see the ⛔
    /// on ``MessagePreview`` for what utf16 does to an emoji when it cuts.
    static let minimumSearchLength = 2

    private(set) var state: InboxState = .loading

    private(set) var searchState: InboxSearchState = .idle

    let workspaceId: String

    /// ⛔ `messages/mark-read` AND `messages/drafts` BOTH EXCLUDE `viewer`
    /// SERVER-SIDE, so this gates two calls rather than one control. Without it a
    /// read-only seat gets a permanent unread badge plus a known 403 on every tap.
    ///
    /// ⚠️ CAN UNDERSTATE ACCESS: the server can grant `agency` for support access
    /// without a membership row, and this reads the MEMBERSHIP role from the workspace list.
    /// Erring low is correct here, because the only thing it costs is a badge that
    /// stays until the next load.
    let canReply: Bool

    /// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY. Every repository is a `let` on the
    /// container built from the one ``ApiClient``; one constructed here would reach a
    /// second ``TokenRefreshCoordinator``.
    private let container: AppContainer

    /// The pending debounced search. Cancelled and replaced on every keystroke.
    private var searchTask: Task<Void, Never>?

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.container = container
        self.workspaceId = workspaceId
        // ⚠️ `allowsMutation` rather than `role != .viewer`, so an UNPARSED role also
        // reads as read-only: `fromWire` fails closed and nil means no privileges.
        canReply = WorkspaceRole.allowsMutation(role)
    }

    /// The workspace's unread total, for a nav badge.
    ///
    /// ⚠️ DERIVED FROM THE LIST RATHER THAN FETCHED AGAIN. `messages/unread-count`
    /// exists and this screen must not call it: the list already carries a per-thread
    /// count, so a second round trip would spend a request to learn something already
    /// in hand and could disagree with the rows the user is looking at.
    var unreadTotal: Int {
        guard case let .content(conversations, _, _, _) = state else { return 0 }
        return conversations.reduce(0) { $0 + unreadCount(for: $1) }
    }

    /// The badge count for one row.
    ///
    /// ⚠️ THE SERVER'S NUMBER, WITH NO LOCAL OVERLAY. The read is recorded by the
    /// thread that opened (``ThreadModel/recordRead()``), and the list re-reads itself
    /// when that thread pops, so the badge follows the server rather than a guess this
    /// client made on the way in. The row carries no tap gesture to feed an overlay;
    /// see the ⛔ on ``InboxScreen/list(conversations:isPartial:draftKeys:)``.
    func unreadCount(for conversation: ConversationSummary) -> Int {
        conversation.unreadCount
    }

    /// Read the conversation list, then badge it.
    ///
    /// - Parameter refreshing: keep the current list on screen while re-reading.
    ///   ⚠️ Replacing it with a spinner on a pull-to-refresh throws away what the user
    ///   is looking at in order to show them less.
    func load(refreshing: Bool = false) async {
        state = Self.pending(from: state, refreshing: refreshing)
        switch await container.inbox.conversations(workspaceId: workspaceId) {
        case let .success(list):
            guard !list.conversations.isEmpty else {
                state = .empty
                // ⚠️ A SUCCESSFUL READ THAT FOUND NOTHING IS A KNOWN ZERO, which is
                // the one case where clearing the icon is a statement rather than a
                // guess. See the ⛔ on ``UnreadBadge``.
                UnreadBadge.set(0)
                return
            }
            state = .content(
                conversations: list.conversations,
                isPartial: list.isPartial,
                draftKeys: [],
                refreshing: false
            )
            // ⛔ AFTER THE ASSIGNMENT, BECAUSE ``unreadTotal`` READS ``state``.
            // ⚠️ AND IT CAN UNDERSTATE ON A PARTIAL LIST, which is accepted rather
            // than fixed here: the scan window is bounded, so an older quiet thread
            // the response could not see is not counted. `messages/unread-count` is
            // the accurate number and this screen must not call it, for the reason on
            // ``unreadTotal``; the background wake reads it instead
            // (``PushRegistrar/handleSilentPush()``). An occasionally low badge is
            // worth more than no ambient signal at all.
            UnreadBadge.set(unreadTotal)
            await loadDraftBadges()
        case let .failure(error):
            // ⛔ THE BADGE IS LEFT EXACTLY AS IT WAS, AND IS NOT ZEROED. Zero means
            // "nothing unread", never "we could not ask".
            state = .failed(FailureText.from(error))
        }
    }

    /// Mark every unread message in the workspace read.
    ///
    /// ⛔ WORKSPACE-WIDE SHARED STATE, WHICH IS WHY IT IS A DELIBERATE CONTROL AND
    /// NEVER A SIDE EFFECT. `readAt` on a `Message` row means "someone on the team has
    /// seen this", so this clears every colleague's badge too. It must not be reached
    /// from a refresh, from this view's appearance, or from a retry helper.
    ///
    /// ⛔ AND IT IS AWAITED RATHER THAN FIRE-AND-FORGET, UNLIKE ``markRead(_:)``. That
    /// one is bookkeeping behind a navigation the operator is already watching; this
    /// one IS the operation, so the list is re-read afterwards and the counts come from
    /// the server rather than from an overlay this client invented. ⚠️ A failure
    /// therefore leaves the badges exactly as they were and says nothing — the numbers
    /// on screen are still the server's own, which is the honest outcome.
    ///
    /// ⚠️ REFUSES LOCALLY FOR A ROLE THE SERVER WOULD REJECT, so the app never fires a
    /// known 403; the control is hidden for the same role.
    ///
    /// ⚠️ AND IT REFUSES WHEN THERE IS NOTHING TO CLEAR. Zero unread means the request
    /// would mark zero rows, and spending a write on the workspace's shared budget to
    /// change nothing is worse than a control that does nothing visible.
    func markAllRead() async {
        guard canReply, unreadTotal > 0 else { return }
        guard case .content = state else { return }
        // ⚠️ HOISTED INTO LOCALS BEFORE THE AWAIT, as ``markRead(_:)`` does: the
        // repository is a `Sendable` struct, so nothing non-`Sendable` has to cross,
        // and ``AppContainer`` is `@MainActor` and would.
        let repository = container.inbox
        let id = workspaceId
        guard case .success = await repository.markAllRead(workspaceId: id) else { return }
        // ⛔ RE-READ RATHER THAN OVERLAID. The server has just changed what every other
        // operator in the workspace sees, so the list's own counts are the truth and a
        // local overlay would be this client's guess about a shared write.
        await load(refreshing: true)
    }

    /// A message push arrived for this workspace: re-read the list.
    ///
    /// ⛔ A PUSH, NEVER A TIMER, AND THIS DOES NOT OPEN A POLLING DOOR. The ⚠️ at the
    /// top of this type argues against polling — "a foreground poll on a phone spends
    /// battery to shorten a latency the user resolves by pulling to refresh. A push
    /// channel is the right answer" — and this is that push channel arriving. The
    /// argument still stands: nothing here schedules anything, and adding a timer
    /// beside it would reintroduce exactly what that note refuses.
    ///
    /// ⛔ IT IS THE REFRESHING FORM, SO THE ROWS STAY ON SCREEN. A message landing while
    /// the operator is reading the list must not replace what they are looking at with a
    /// skeleton; that is the same reasoning pull-to-refresh uses, and here it matters
    /// more because nobody asked for this read.
    ///
    /// ⚠️ IT DOES NOT TOUCH THE SEARCH STATE. A push arriving while a search is on
    /// screen refreshes the list UNDERNEATH it — ``content`` consults
    /// ``searchState`` first, so the operator's results stay put and the fresher list is
    /// there when they clear the field. Clearing their search on the strength of an
    /// inbound message would be the app taking the screen away.
    ///
    /// ⚠️ SAFE TO CALL WHEN THE LIST HAS NEVER LOADED: `load(refreshing:)` treats a
    /// refresh with nothing to keep as a cold load.
    func refreshFromPush() async {
        await load(refreshing: true)
    }

    // MARK: - Search

    /// Record what is in the search field and (re)arm the debounced search.
    ///
    /// ⚠️ THE DEBOUNCE IS RESTARTED, NOT EXTENDED FROM THE FIRST KEYSTROKE, exactly
    /// as ``ThreadModel/composerTextChanged(_:)`` does it. Extending would mean a
    /// sustained typist never searches at all.
    ///
    /// ⛔ NO ROLE GATE, AND THAT IS THE SERVER'S CALL RATHER THAN AN OVERSIGHT.
    /// `messages/search` admits agency, client AND viewer — it is a read, and the
    /// only Inbox reads this app gates are the ones the route itself excludes
    /// viewers from (`mark-read`, `drafts`). Gating a search on ``canReply`` would
    /// hide a permitted capability from a read-only seat.
    ///
    /// ⚠️ TRIMMED ONCE, HERE, AND THE TRIMMED VALUE IS WHAT TRAVELS. The route
    /// trims before it measures, so measuring the raw text would fire a request for
    /// `"  a"` that the server answers empty.
    func searchQueryChanged(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }
        guard trimmed.utf16.count >= Self.minimumSearchLength else {
            searchState = .belowFloor
            return
        }
        searchState = .searching
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            await self?.runSearch(trimmed)
        }
    }

    /// The loaded conversation row for a thread key, if the list holds one.
    ///
    /// ⛔ THE ONLY HONEST SOURCE OF A REPLY TARGET FOR A SEARCH HIT. A hit carries no
    /// `canSms`/`canEmail`, and those are SERVER-DECIDED: deriving a channel from
    /// the hit's `kind` would reintroduce the bug where a customer who had only
    /// ever emailed could not be sent an SMS. So the answer comes from the row the
    /// conversation list already holds, or from nowhere.
    ///
    /// ⚠️ nil IS COMMON AND CORRECT. Search reaches threads outside the list's
    /// 500-message scan window, and a thread that is not on screen has no
    /// server-decided flags in hand. The thread screen then opens read-only, which
    /// is the truthful outcome: this app does not know whether that thread can be
    /// replied to, and guessing would offer a box whose send is refused.
    func conversation(forThreadKey key: String) -> ConversationSummary? {
        guard case let .content(conversations, _, _, _) = state else { return nil }
        return conversations.first { $0.threadKey == key }
    }

    // MARK: - Internals

    /// Run one search and adopt its answer.
    ///
    /// ⛔ THE CANCELLATION CHECK AFTER THE AWAIT IS THE ONE THAT MATTERS. Cancelling
    /// the task does not stop a request already in flight, so without it a slow
    /// response for "sur" can land after a fast one for "survey" and overwrite the
    /// newer answer with the older one — results that are correct for a query the
    /// field no longer holds, which is indistinguishable from a broken search.
    private func runSearch(_ query: String) async {
        let outcome = await container.inbox.search(workspaceId: workspaceId, query: query)
        guard !Task.isCancelled else { return }
        switch outcome {
        case let .success(results):
            // ⛔ REACHABLE ONLY AFTER A SUCCESSFUL READ, which is what makes an
            // empty state honest here rather than a failure wearing the wrong copy.
            guard !results.hits.isEmpty else {
                searchState = .empty
                return
            }
            searchState = .results(hits: results.hits, capped: results.isCapped)
        case let .failure(error):
            searchState = .failed(FailureText.from(error))
        }
    }

    /// Fetch which threads carry an unsent draft.
    ///
    /// ⛔ AFTER THE LIST IS ALREADY ON SCREEN, AND FAIL-SOFT. The conversations render
    /// first and the badges arrive when they arrive. An Inbox that refused to load
    /// because a decorative chip's endpoint was down would be strictly worse than an
    /// Inbox with no chips, so a failure leaves the list exactly as it is and says
    /// nothing.
    ///
    /// ⚠️ ONE REQUEST FOR THE WHOLE LIST, not one per row. The route answers every
    /// draft this author holds open (capped at 100) in a single indexed query; asking
    /// per thread would be a request per visible conversation, for a badge.
    ///
    /// ⚠️ AND ONLY WHEN THIS ROLE CAN COMPOSE. The drafts route excludes `viewer`, so
    /// calling it for one would be a known 403.
    ///
    /// ⚠️ THE STATE IS RE-READ AFTER THE AWAIT rather than closed over from before it.
    /// A refresh or a failure can land while this request is in flight, and writing a
    /// captured list back would resurrect rows the newer read had already replaced.
    private func loadDraftBadges() async {
        guard canReply else { return }
        guard case let .success(drafts) = await container.inbox.drafts(workspaceId: workspaceId) else { return }
        guard case let .content(conversations, isPartial, _, refreshing) = state else { return }
        state = .content(
            conversations: conversations,
            isPartial: isPartial,
            draftKeys: Set(drafts.map(\.threadKey)),
            refreshing: refreshing
        )
    }

    /// ⚠️ A REFRESH WITH NOTHING TO KEEP IS A COLD LOAD. Asking to refresh out of a
    /// failed or empty state has no content to preserve, so it shows the skeleton
    /// rather than nothing at all.
    private static func pending(from current: InboxState, refreshing: Bool) -> InboxState {
        guard refreshing else { return .loading }
        guard case let .content(conversations, isPartial, draftKeys, _) = current else { return .loading }
        return .content(conversations: conversations, isPartial: isPartial, draftKeys: draftKeys, refreshing: true)
    }
}
