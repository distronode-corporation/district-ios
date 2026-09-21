import DistrictModel
import DistrictNetwork
import Foundation

/// The Inbox list, and how complete it is.
///
/// ⛔ THE LIST IS NOT PAGED AND IS NOT NECESSARILY COMPLETE. The server scans a
/// bounded window of recent messages (500) and GROUPS them into threads, so there
/// is no stable offset to page on. `scanned` and `scanLimit` come back precisely
/// so the client can SAY the list is partial instead of implying it is the whole
/// inbox.
public struct ConversationList: Sendable {
    public let response: ConversationsResponse

    /// The threads, in the server's order (most recent first).
    ///
    /// ⛔ KEY A LIST ON ``ConversationSummary/threadKey``, NEVER ON `key` OR ON
    /// the counterpart address. One customer's phone and their email are two
    /// different strings that fold into one thread, so an address key produces
    /// duplicate identifiers — which on a SwiftUI `List` bound to `Identifiable`
    /// is a runtime failure, not a cosmetic one.
    public var conversations: [ConversationSummary] {
        response.conversations
    }

    /// ⚠️ CAPTION THE LIST WHEN THIS IS TRUE. The window was full, so older
    /// threads exist that this response could not see. There is nothing to fetch
    /// and nothing is broken; the caption is a truthfulness signal.
    public var isPartial: Bool {
        response.scanned >= response.scanLimit
    }
}

/// The unified Inbox: the thread list, search over it, one thread's history, and
/// the composer.
public struct InboxRepository: Sendable {
    /// ⚠️ INTERNAL RATHER THAN `private`, AND ONLY BECAUSE THE MESSAGE-TO-THREAD
    /// RESOLVER AND `markAllRead` LIVE IN `InboxRepository+MessageThread.swift`.
    /// `private` is file-scoped in Swift, so an extension in a sibling file cannot
    /// see it; internal is the narrowest level that works. That file exists because
    /// THIS one is within a dozen lines of the 500 `swiftlint --strict` allows, and
    /// `DistrictData` is one module with no second reader.
    let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    // MARK: - Reads

    /// The conversation list, most recent first.
    public func conversations(workspaceId: String) async -> Result<ConversationList, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.conversations(workspaceId: workspaceId),
            as: ConversationsResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("ConversationsResponse", $0.success, $0) }
            .map { ConversationList(response: $0) }
    }

    /// One thread's history: SMS, email AND calls, interleaved, oldest first.
    ///
    /// ⛔ READ OUT OF ``JSONValue`` RATHER THAN A DTO, ON PURPOSE — see the ⛔ on
    /// ``ThreadEvent``. This is the one MVP surface whose wire shape is mid-change
    /// on the server side, and ``ThreadPageReader`` handles both versions.
    ///
    /// ⛔ EXPAND-ONLY PAGING, AND THE CURSOR IS A PAIR OR NOTHING. `beforeId`
    /// without `before` is a **400** from the route — an id alone cannot say which
    /// timestamp it breaks a tie at — so the cursor is modelled as one value that
    /// cannot hold half of itself. See ``ThreadCursor``.
    ///
    /// ⚠️ THE CURSOR VALUES ARE THE SERVER'S OWN, echoed back from a previous
    /// response's `pageInfo`. Never a timestamp this client formatted: the server
    /// compares it against what it emitted. ⛔ And on the deployed route there is
    /// no `pageInfo` at all, so ``ThreadPage/hasMore`` is false and no cursor is
    /// ever produced — which is why "load older" must be driven by that flag
    /// rather than offered unconditionally.
    public func timeline(
        workspaceId: String,
        selector: ThreadSelector,
        cursor: ThreadCursor? = nil
    ) async -> Result<ThreadPage, ApiError> {
        let descriptor = DistrictEndpoints.timeline(
            workspaceId: workspaceId,
            contactId: selector.contactId,
            address: selector.address,
            before: cursor?.before,
            beforeId: cursor?.beforeId
        )
        let outcome = await client.send(descriptor)
        return outcome
            .flatMap { ResponseEnvelope.require("TimelineResponse", $0.json) }
            .flatMap(ThreadPageReader.read)
    }

    /// Search the workspace's messages by content.
    ///
    /// ⛔ NOT A FILTER OVER ``conversations(workspaceId:)``, AND THE DIFFERENCE IS
    /// THE POINT. That list groups a bounded window of the 500 newest messages;
    /// this queries the whole table, so it finds the quiet thread from March that
    /// the window never reached. A client that "saved a round trip" by filtering the
    /// loaded rows would answer "no matches" for messages the workspace has, which
    /// is a failure wearing an absence's clothes.
    ///
    /// ⛔ THE TWO-CHARACTER FLOOR IS THE SERVER'S AND IS NOT ENFORCED HERE. A
    /// shorter `q` is answered `{success, results: []}` with no `limit` key —
    /// well-formed, cheap, and honest — so refusing it locally would be this layer
    /// inventing a validation rule. What must NOT happen is a request per keystroke
    /// to be told nothing, and that is a debounce, which belongs to the caller that
    /// owns the text field rather than to a `Sendable` struct with no state.
    ///
    /// ⚠️ RETURNS ``MessageSearchResults`` RATHER THAN A BARE ARRAY so the caller
    /// can say the list was capped. See the ⛔ on that type.
    ///
    /// ⚠️ ADMITS `viewer`, unlike every write on this repository. Do not gate it.
    public func search(workspaceId: String, query: String) async -> Result<MessageSearchResults, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.searchMessages(workspaceId: workspaceId, query: query),
            as: MessageSearchResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MessageSearchResponse", $0.success, $0) }
            .map { MessageSearchResults(response: $0) }
    }

    /// The workspace's unread count.
    ///
    /// ⚠️ A SEPARATE CALL FROM ``conversations(workspaceId:)`` on purpose: the nav
    /// badge needs this number without paying for the 500-message scan the list
    /// costs.
    ///
    /// ⛔ THE ENVELOPE IS AFFIRMED HERE LIKE ON EVERY OTHER READ ON THIS TYPE, AND
    /// IT IS THE EASIEST ONE TO OMIT. A non-optional `count` does
    /// reject `{}`, which is what made the omission look harmless, but it does not
    /// reject a well-formed `{"success":false,"count":7}`, and
    /// ``ResponseEnvelope/affirm(_:_:_:)`` records that this surface answers exactly
    /// that with a **200** whenever a handler falls into its own error branch after
    /// the headers are written. Without this the badge paints a number nobody
    /// counted, which is the failure that type states in full: "we could not look"
    /// rendered as a fact.
    public func unreadCount(workspaceId: String) async -> Result<UnreadCountResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.unreadCount(workspaceId: workspaceId),
            as: UnreadCountResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("UnreadCountResponse", $0.success, $0) }
    }

    // MARK: - Drafts (persistence — cheap, idempotent, author-scoped)

    /// One thread's saved draft, or nil when there is none.
    ///
    /// ⛔ nil IS THE ORDINARY ANSWER AND NOT A FAILURE. Almost every thread has no
    /// draft; the server answers `{success, draft: null}` rather than 404 exactly
    /// so the composer's normal open path is not an error in every log. A client
    /// that treated it as one would show an error on the common case.
    public func draft(workspaceId: String, threadKey: String) async -> Result<MessageDraft?, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.draft(workspaceId: workspaceId, threadKey: threadKey),
            as: DraftResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DraftResponse", $0.success, $0) }
            .map(\.draft)
    }

    /// Every draft this author holds in the workspace, most recently updated
    /// first.
    ///
    /// ⚠️ READ ONCE PER INBOX LOAD TO BADGE THE LIST, NOT PER ROW. It is one
    /// indexed query capped at 100 rows; a per-thread call would be one request
    /// per visible conversation.
    ///
    /// ⚠️ AUTHOR-SCOPED, unlike read state. A colleague's unfinished thought is
    /// not in this list and must not be — the server keys the row by
    /// `authorEmail` and this client never sends one.
    public func drafts(workspaceId: String) async -> Result<[MessageDraft], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.drafts(workspaceId: workspaceId),
            as: MessageDraftsResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MessageDraftsResponse", $0.success, $0) }
            .map(\.drafts)
    }

    /// Upsert a draft.
    ///
    /// ⛔ NEVER WITH A BLANK BODY, AND THIS METHOD REFUSES ONE LOCALLY RATHER THAN
    /// SPENDING THE ROUND TRIP TO BE TOLD. The route answers 400 `empty_body` and
    /// means "send DELETE instead"; a blank draft is the ABSENCE of one. Doing the
    /// substitution silently here would hide the bug until an offline queue
    /// replayed the two writes out of order.
    ///
    /// ⚠️ Rate limited at 60 writes/min per WORKSPACE, shared with
    /// ``deleteDraft(workspaceId:threadKey:)``. An autosave debounce tighter than
    /// a second reaches it with two operators in one workspace.
    public func saveDraft(
        workspaceId: String,
        threadKey: String,
        body: String,
        subject: String? = nil,
        mediaUrls: [String] = []
    ) async -> Result<MessageDraft?, ApiError> {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.http(status: 400, message: "A draft cannot be blank. Delete it instead."))
        }
        let outcome = await client.send(
            DistrictEndpoints.saveDraft(
                workspaceId: workspaceId,
                threadKey: threadKey,
                body: body,
                subject: subject,
                mediaUrls: mediaUrls
            ),
            as: DraftResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DraftResponse", $0.success, $0) }
            .map(\.draft)
    }

    /// Delete a draft. Idempotent: deleting one that is not there succeeds,
    /// because the goal state is met.
    ///
    /// ⚠️ THE RESPONSE IS DISCARDED DELIBERATELY. It carries no DTO worth modelling
    /// and nothing acts on its contents; what matters is whether the write landed.
    public func deleteDraft(workspaceId: String, threadKey: String) async -> Result<Void, ApiError> {
        await client.send(DistrictEndpoints.deleteDraft(workspaceId: workspaceId, threadKey: threadKey))
            .map { _ in () }
    }

    // MARK: - Writes that cost money or change what the team sees

    /// Generate a reply with the model.
    ///
    /// ⛔ **BILLED, NON-IDEMPOTENT, AND ONE LETTER FROM
    /// ``saveDraft(workspaceId:threadKey:body:subject:mediaUrls:)``.** Every call
    /// is one Vertex generation, capped at 20/min per workspace with no
    /// entitlement check in front of it. ⛔ It must never be fired from a timer, a
    /// retry helper, an autosave debounce or a view's appearance — only from an
    /// explicit press. `ApiClient` retries nothing, which is the other half of
    /// that guarantee.
    ///
    /// ⚠️ AN EMPTY RESULT IS A LEGITIMATE ANSWER: the model occasionally returns
    /// nothing and the route sends `""` rather than failing. ⛔ An empty generation
    /// must not blank a composer the operator has already typed in.
    public func generateDraft(
        workspaceId: String,
        selector: ThreadSelector
    ) async -> Result<String, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.generateDraft(
                workspaceId: workspaceId,
                contactId: selector.contactId,
                phoneNumber: selector.address
            ),
            as: AiDraftResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("AiDraftResponse", $0.success, $0) }
            .map(\.draft)
    }

    /// Send a reply.
    ///
    /// ⛔ METERED AND NON-IDEMPOTENT. Every 2xx is a carrier segment or a Postmark
    /// send that has already been paid for, capped at 30/min per WORKSPACE. ⛔ A
    /// failure here is NOT retryable by this client under any circumstances: a
    /// timeout means the send may well have landed, and the second attempt is a
    /// second charge and a duplicate message to a customer.
    ///
    /// ⛔ THE RECIPIENT IS AN ADDRESS, NEVER A THREAD IDENTITY. The route hands
    /// `to` straight to the carrier or to Postmark; it does not resolve a Contact
    /// id. Sending `contact:<id>` dispatches an SMS to a cuid, which fails at the
    /// provider as a raw 500 — and since the server folds every contact-resolved
    /// counterpart into that form, that is MOST threads.
    /// ``ConversationSummary/replyTarget`` is what resolves the pair correctly.
    ///
    /// ⚠️ THE SERVER'S REFUSALS REACH THE CALLER VERBATIM — unverified sender,
    /// exhausted A2P registration, the per-workspace cap. "Could not send" throws
    /// all of that away, and each of those needs a different action from the
    /// operator.
    public func send(
        workspaceId: String,
        target: ReplyTarget,
        body: String,
        subject: String? = nil,
        mediaUrls: [String] = []
    ) async -> Result<SentMessage, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.sendMessage(
                workspaceId: workspaceId,
                to: target.to,
                body: body,
                channel: target.channel,
                subject: subject,
                mediaUrls: mediaUrls
            ),
            as: SendMessageResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SendMessageResponse", $0.success, $0) }
            .map(\.message)
    }

    /// Mark a thread read.
    ///
    /// ⛔ THE ROUTE EXCLUDES `viewer`, SO GATE THE CALL ON
    /// ``WorkspaceRole/canMutate`` BEFORE MAKING IT. A viewer can list the inbox
    /// and 403s here, which without a UI gate is a permanent unread badge plus an
    /// error dialog on every tap.
    ///
    /// ⚠️ THE RESULT IS A COUNT AND ZERO IS A SUCCESS: a thread another agent
    /// already opened marks nothing. Both outcomes resolve to the same action —
    /// redraw from the list.
    public func markRead(workspaceId: String, selector: ThreadSelector) async -> Result<Int, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.markRead(
                workspaceId: workspaceId,
                contactId: selector.contactId,
                counterpart: selector.address
            ),
            as: MarkReadResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MarkReadResponse", $0.success, $0) }
            .map(\.marked)
    }

    /// Upload one image and get back the URL ``send(workspaceId:target:body:subject:mediaUrls:)``
    /// accepts as a `mediaUrl`.
    ///
    /// ⚠️ THE SERVER'S LIMITS ARE MIRRORED CLIENT-SIDE RATHER THAN TRUSTED TO THE
    /// ROUND TRIP: JPEG, PNG, GIF or WebP only, 1 byte to 5MB. Pre-checking is the
    /// difference between an instant "that file is too large" and five megabytes
    /// spent on a metered connection to be told the same thing.
    ///
    /// ⛔ THE URL IT RETURNS IS AN ANONYMOUS CAPABILITY URL. Load it back WITHOUT
    /// this client's bearer token: `/api/media/<uuid>` answers to anyone by
    /// design, because a carrier's MMS fetcher has no session either, and
    /// attaching an access token to it would send a credential to a route that
    /// does not need one.
    public func uploadMedia(
        workspaceId: String,
        fileName: String,
        mimeType: String,
        bytes: Data
    ) async -> Result<UploadedMedia, ApiError> {
        if let refusal = MediaUploadLimits.refusal(mimeType: mimeType, byteCount: bytes.count) {
            return .failure(refusal)
        }
        let outcome = await client.send(
            DistrictEndpoints.uploadMedia(
                workspaceId: workspaceId,
                fileName: fileName,
                mimeType: mimeType,
                bytes: bytes
            ),
            as: MediaUploadResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MediaUploadResponse", $0.success, $0) }
            .map(\.media)
    }
}

/// What the media route accepts, mirrored so an oversized upload is refused
/// before it is sent.
///
/// ⚠️ A MIRROR, NOT THE AUTHORITY. The server enforces these and its answer wins;
/// duplicating them here buys latency and a metered connection, not safety. If
/// the two ever disagree the server is right, and this constant is the one to fix.
public enum MediaUploadLimits {
    /// The four types the route allows. Anything else is a 400 naming the rule.
    public static let allowedMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    ]

    /// 5 MB, as the route counts it.
    public static let maximumByteCount = 5 * 1024 * 1024

    /// The refusal to return without sending anything, or nil when the file is
    /// acceptable.
    ///
    /// ⚠️ SHAPED AS AN ``ApiError/http(status:message:)`` WITH THE ROUTE'S OWN
    /// STATUS so a caller has one failure path rather than two. The message is
    /// this client's, because the server never saw the request.
    public static func refusal(mimeType: String, byteCount: Int) -> ApiError? {
        guard allowedMimeTypes.contains(mimeType) else {
            return .http(status: 400, message: "Attachments must be a JPEG, PNG, GIF or WebP image.")
        }
        guard byteCount > 0 else {
            return .http(status: 400, message: "That file is empty.")
        }
        guard byteCount <= maximumByteCount else {
            return .http(status: 400, message: "Attachments must be 5 MB or smaller.")
        }
        return nil
    }
}

/// Which thread to read.
///
/// ⛔ EXACTLY ONE OF THE TWO, AND A TYPE IS WHAT ENFORCES IT. The route takes
/// `contactId` when the thread resolved to a Contact and the address parameter
/// when it did not; sending both, or neither, is not a case the server defines.
///
/// ⚠️ THE ADDRESS PARAMETER IS STILL SPELLED `phoneNumber` ON THE WIRE and now
/// carries an email too. That name is historical and renaming it would 400 — see
/// ``DistrictEndpoints/timeline(workspaceId:contactId:address:before:beforeId:)``.
public enum ThreadSelector: Sendable, Equatable {
    case contact(String)
    case address(String)

    var contactId: String? {
        guard case let .contact(id) = self else { return nil }
        return id
    }

    var address: String? {
        guard case let .address(value) = self else { return nil }
        return value
    }
}

public extension ThreadSelector {
    /// The selector for one Inbox row.
    ///
    /// ⛔ PREFER THE CONTACT ID WHENEVER THERE IS ONE. It is exact, it survives an
    /// address changing, and it is the only thing that matches a message row whose
    /// counterpart string was never normalizable — the address path is the
    /// fallback for a thread that resolved to no Contact at all.
    ///
    /// ⛔ AND THE FALLBACK IS ``ConversationSummary/counterpart``, NEVER
    /// ``ConversationSummary/threadKey``. The thread key of an unresolved thread is
    /// `addr:<normalized>`, and that whole string sent as the address parameter
    /// matches nothing.
    static func forConversation(_ conversation: ConversationSummary) -> ThreadSelector {
        if let contactId = conversation.contactId, !contactId.isEmpty {
            return .contact(contactId)
        }
        return .address(conversation.counterpart)
    }

    /// The selector for one search hit, so a thread opened from search can be
    /// marked read the same way a thread opened from the list is.
    ///
    /// ⛔ A SEPARATE ENTRY POINT RATHER THAN A CONVERSATION LOOKUP, BECAUSE THE
    /// LOOKUP OFTEN FAILS AND MUST NOT DECIDE THIS. Search reaches threads outside
    /// the conversation list's 500-message scan window, so the row is frequently
    /// not in hand — and the whole point of a hit carrying ``MessageSearchHit/contactId``
    /// and ``MessageSearchHit/counterpart`` is that `messages/mark-read` accepts
    /// exactly those two. A reply TARGET genuinely cannot be derived from a hit
    /// (see the ⛔ on ``MessageSearchHit``); a read receipt can, and conflating the
    /// two left every thread opened from search permanently unread.
    ///
    /// ⛔ AND THE FALLBACK IS THE COUNTERPART, NEVER ``MessageSearchHit/threadKey``,
    /// for the reason ``forConversation(_:)`` states: `addr:<normalized>` sent whole
    /// matches nothing, so the write would succeed against zero rows and the badge
    /// would never clear.
    static func forSearchHit(_ hit: MessageSearchHit) -> ThreadSelector {
        if let contactId = hit.contactId, !contactId.isEmpty {
            return .contact(contactId)
        }
        return .address(hit.counterpart)
    }
}

/// One position in a thread's expand-only paging.
///
/// ⛔ IT CANNOT HOLD AN ID WITHOUT A TIMESTAMP, AND THAT IS THE WHOLE TYPE.
/// `beforeId` alone is a 400 from the route; the alternatives the server rejected
/// — guess a timestamp, or ignore the parameter — both end with the client
/// walking backwards through the same window forever.
///
/// ⚠️ OMITTING THE CURSOR ENTIRELY IS THE NEWEST WINDOW, byte for byte the
/// request this made before paging existed. That works only because nil query
/// entries are DROPPED rather than sent empty.
public struct ThreadCursor: Sendable, Equatable {
    /// ISO-8601, from `pageInfo.oldest`.
    public let before: String
    /// From `pageInfo.oldestId`, breaking ties among rows sharing the timestamp.
    public let beforeId: String

    public init(before: String, beforeId: String) {
        self.before = before
        self.beforeId = beforeId
    }
}
