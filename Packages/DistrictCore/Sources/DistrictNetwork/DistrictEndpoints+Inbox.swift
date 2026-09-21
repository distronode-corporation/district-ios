import Foundation

/// The unified Inbox — SMS and email in one thread per counterpart — and the
/// composer's persistence and generation routes.
///
/// ⛔ THE READS ADMIT `viewer`; THE WRITES DO NOT. `conversations`, `timeline`,
/// `unreadCount` and `searchMessages` allow agency/client/viewer, while `sendMessage`,
/// `markRead` and `uploadMedia` are agency/client only — so the reply box must be
/// gated on the same role the app already threads through for contacts.
/// `markRead` excluding viewers is why a viewer left ungated gets a permanent
/// unread badge plus an error on every tap.
public extension DistrictEndpoints {
    /// The Inbox list, most recent first.
    ///
    /// ⛔ NOT PAGED, AND NOT BECAUSE NOBODY GOT AROUND TO IT. The server scans a
    /// bounded window of recent messages (500) and GROUPS them into threads, so
    /// there is no stable offset to page on — a thread's position depends on
    /// messages that may fall outside the window. The response reports `scanned`
    /// and `scanLimit` so the client can say the list is partial instead of
    /// implying it is complete.
    static func conversations(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .conversations,
            .get,
            DistrictPaths.conversations,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// One thread's full history: SMS, email AND calls, interleaved.
    ///
    /// ⚠️ TAKES `contactId` WHEN THE THREAD RESOLVED TO A CONTACT AND `address`
    /// WHEN IT DID NOT — exactly one is required. The server's parameter is still
    /// named `phoneNumber` for the address case and now accepts an email in it;
    /// that name is historical and renaming it here would 400.
    ///
    /// ⛔ EXPAND-ONLY PAGING, AND OMITTING BOTH CURSOR ARGUMENTS IS THE NEWEST
    /// WINDOW — byte for byte the request this made before paging existed. That
    /// works only because nil query entries are DROPPED rather than sent empty:
    /// `before=` present-but-empty becomes `new Date("")`, an Invalid Date, and
    /// the route answers 400 — every thread open would break.
    ///
    /// ⛔ `beforeId` WITHOUT `before` IS A 400 FROM THE ROUTE, NOT A DEFAULT. An
    /// id alone cannot say which timestamp it breaks a tie at. The pairing is
    /// enforced one layer up, in `DistrictData`'s thread cursor, which cannot
    /// hold an id without a timestamp; these stay two optional strings because
    /// this layer is the wire's shape.
    ///
    /// - Parameter before: ISO-8601, echoed back from a previous response's
    ///   `pageInfo.oldest`. ⚠️ NEVER a timestamp this client formatted: the
    ///   server compares it against what it emitted.
    static func timeline(
        workspaceId: String,
        contactId: String?,
        address: String?,
        before: String? = nil,
        beforeId: String? = nil
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .timeline,
            .get,
            DistrictPaths.timeline,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("contactId", contactId),
                ApiQueryItem("phoneNumber", address),
                ApiQueryItem("before", before),
                ApiQueryItem("beforeId", beforeId),
            ]
        )
    }

    /// The workspace's total unread message count.
    ///
    /// ⚠️ A SEPARATE CALL FROM ``conversations(workspaceId:)`` ON PURPOSE. The nav
    /// badge needs this number without paying for the 500-message scan the list
    /// costs, and the web sidebar polls exactly this route for the same reason.
    ///
    /// ⚠️ ITS ENVELOPE IS `{success, count, workspaceId}` — the count is a
    /// TOP-LEVEL key, not a nested object, and the workspace id is echoed back.
    /// `UnreadCountResponse` is one of the nine DTOs that already exist, so this
    /// is one of the few endpoints that decodes typed today.
    static func unreadCount(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .unreadCount,
            .get,
            DistrictPaths.messagesUnreadCount,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Search the workspace's messages by content.
    ///
    /// ⛔ THE WHOLE MESSAGE TABLE, NOT THE CONVERSATION LIST FILTERED. The route
    /// matches `body` and the email `subject` case-insensitively across every
    /// message in the workspace, so it reaches threads that
    /// ``conversations(workspaceId:)`` never scanned. That is the entire reason it
    /// is a round trip rather than a predicate over rows already on screen, and it
    /// is why a client-side filter is not a cheaper version of this: the two
    /// answer different questions and only one of them is complete.
    ///
    /// ⛔ THE SHORT-QUERY BRANCH OMITS `limit` ENTIRELY. A `q` shorter than two
    /// characters (after the server's own trim) answers `{success, results: []}`
    /// with **no `limit` key at all**, so ``MessageSearchResponse/limit`` is
    /// Optional. A non-optional `Int` there is a decode failure waiting for the
    /// first person who types one letter, and this client decodes strictly.
    ///
    /// ⚠️ THIRTY RESULTS, SERVER-CAPPED, AND THE CAP IS REPORTED RATHER THAN
    /// INFERRED. A full page means older matches exist and are not shown; say so
    /// instead of drawing a truncated list as if it were complete, the same way
    /// the conversation list uses `scanned`/`scanLimit`.
    ///
    /// ⚠️ ADMITS `viewer`, like the other Inbox reads and unlike every write on
    /// this surface. Do not gate it more tightly than the server does.
    ///
    /// - Parameter query: sent as `q`. ⚠️ The server trims it before measuring, so
    ///   a caller mirroring the two-character floor must measure the TRIMMED value
    ///   or it will send requests the route answers empty.
    static func searchMessages(workspaceId: String, query: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .searchMessages,
            .get,
            DistrictPaths.messagesSearch,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("q", query),
            ]
        )
    }

    /// Send a reply.
    ///
    /// ⛔ THIS SPENDS REAL MONEY — SMS/MMS segments or a Postmark email — and is
    /// capped server-side at 30 requests per minute PER WORKSPACE (not per user,
    /// because the cost lands on the workspace either way). A client that retried
    /// a send automatically is spending someone's money on its own initiative.
    /// Nothing here may.
    ///
    /// ⚠️ THE SERVER'S REFUSALS ARE SPECIFIC — unverified sender, exhausted A2P
    /// registration, per-workspace rate limit — and are surfaced verbatim,
    /// because "could not send" throws all of that away.
    ///
    /// - Parameter mediaUrls: the URLs ``uploadMedia(workspaceId:fileName:mimeType:bytes:)``
    ///   returned. ⛔ Those URLs are ANONYMOUS (`/api/media/<uuid>` answers
    ///   without a session, because a carrier's MMS fetcher has none) — do not
    ///   attach the bearer token when loading one back.
    static func sendMessage(
        workspaceId: String,
        to: String,
        body: String,
        channel: String,
        subject: String? = nil,
        mediaUrls: [String] = []
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .sendMessage,
            .post,
            DistrictPaths.messagesSend,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("to", .string(to)),
                ("body", .string(body)),
                ("channel", .string(channel)),
                ("subject", .optional(subject)),
                ("mediaUrls", .array(mediaUrls.map { JSONValue.string($0) })),
            ]))
        )
    }

    /// Mark a thread read.
    ///
    /// ⚠️ `contactId` OR `counterpart`; NEITHER IS A 400. A thread with no
    /// Contact row has only an address, which is why the server accepts both —
    /// and it validates that at least one is PRESENT, which is why the nils are
    /// dropped rather than sent as explicit nulls.
    ///
    /// ⛔ EXCLUDES `viewer`. A viewer can list the inbox and 403s on opening a
    /// thread; gate it in the UI or it is a permanent unread badge plus an error
    /// on every tap.
    static func markRead(
        workspaceId: String,
        contactId: String?,
        counterpart: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .markRead,
            .post,
            DistrictPaths.messagesMarkRead,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .optional(contactId)),
                ("counterpart", .optional(counterpart)),
            ]))
        )
    }

    /// Mark the WHOLE workspace read.
    ///
    /// ⛔ THE SAME ROUTE AND THE SAME ``EndpointID/markRead`` AS THE PER-THREAD
    /// CALL, BECAUSE `all: true` IS A THIRD SELECTOR ON ONE ROUTE RATHER THAN A
    /// SECOND ROUTE. `messages/mark-read` destructures `{workspaceId, contactId,
    /// counterpart, all}` and branches on `all` before it builds any clause; there
    /// is no `mark-read/all` path and inventing one would 404. So this adds no
    /// ``EndpointID`` case and no row to `EndpointTable` — it is a body, and a
    /// route may have several.
    ///
    /// ⛔ AND IT IS THE ONE BODY ON THIS ROUTE WITH NO SELECTOR TO GET WRONG,
    /// WHICH IS EXACTLY WHY IT IS A SEPARATE FUNCTION. The route's own comment
    /// records the trap from the other side: a selector that resolved to nothing
    /// usable must mark ZERO rows, because "falling through to an empty filter
    /// would mark the ENTIRE workspace read". A single function taking
    /// `all: Bool = false` beside two optional selectors would put that
    /// fall-through one defaulted argument away at every call site.
    ///
    /// ⚠️ NOT DESTRUCTIVE AND NOT IDEMPOTENT-SENSITIVE: it stamps `readAt` on
    /// inbound rows that have none, so a repeat marks nothing and answers
    /// `{success, marked: 0}`. It deletes nothing and it is invisible to the
    /// customer. ⛔ It is still workspace-wide shared state — every colleague's
    /// badge clears with it — so it belongs behind a deliberate control rather
    /// than behind a refresh.
    static func markAllRead(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .markRead,
            .post,
            DistrictPaths.messagesMarkRead,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("all", .bool(true)),
            ]))
        )
    }

    /// One message id exchanged for the thread it belongs to.
    ///
    /// ⛔ THE RESOLVER A MESSAGE PUSH CANNOT DO WITHOUT. The payload carries
    /// `{type, category, workspaceId, messageId}` and every endpoint on this
    /// surface is addressed by THREAD, so a notification can neither deep-link
    /// into the conversation nor offer Reply / Mark read without this one request.
    /// ⛔ Widening the payload instead is the bug this route exists to prevent: a
    /// `threadKey` is `addr:<address>` whenever the thread has no `Contact` row,
    /// which puts a customer's phone number or email address on a lock screen and
    /// in front of every installed notification-listener app.
    ///
    /// ⚠️ THE ID IS A PATH SEGMENT AND ARRIVES FROM A PUSH, i.e. from the least
    /// trustworthy input in the app. ``DistrictPaths/messageThreadTarget(_:)`` is a
    /// function for that reason; see its ⛔.
    ///
    /// ⚠️ THE WORKSPACE IS A QUERY PARAMETER AND IS WORTH SENDING EVEN THOUGH THE
    /// ROUTE WOULD FALL BACK. Omitted, the guard picks the caller's active
    /// workspace, which on a multi-tenant account is a different tenant from the
    /// one the push named — and the answer would then 404 for a message that
    /// exists. The push carries the workspace; pass it.
    ///
    /// ⛔ ANSWERS **409** FOR A ROW WITH NO ADDRESSABLE COUNTERPART, and **404**
    /// identically for "not in this workspace" and "does not exist". Neither is a
    /// retry: the first is a malformed row and the second is a deliberate refusal
    /// to confirm whether an id exists elsewhere on the platform.
    static func messageThread(workspaceId: String, id: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .messageThread,
            .get,
            DistrictPaths.messageThreadTarget(id),
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Upload one image and get back the URL ``sendMessage`` accepts as a
    /// `mediaUrl`.
    ///
    /// ⛔ THE ONLY NON-JSON REQUEST THIS CLIENT MAKES, and `workspaceId` travels
    /// as a FORM FIELD rather than a query parameter: the route reads it off
    /// `req.formData()`, and a query parameter would leave it undefined and trip
    /// the guard's 400 while the URL looked perfectly correct.
    ///
    /// ⚠️ SERVER LIMITS, MIRRORED CLIENT-SIDE RATHER THAN TRUSTED TO THE ROUND
    /// TRIP: JPEG, PNG, GIF or WebP only, 1 byte to 5MB. Pre-check both so a 5MB
    /// upload is not spent on a metered connection to be told no.
    static func uploadMedia(
        workspaceId: String,
        fileName: String,
        mimeType: String,
        bytes: Data
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .uploadMedia,
            .post,
            DistrictPaths.messagesMedia,
            body: .multipart(MultipartBody(
                fields: ["workspaceId": workspaceId],
                fileName: fileName,
                contentType: mimeType,
                bytes: bytes
            ))
        )
    }

    /// One thread's saved draft, or `null` when there is none.
    ///
    /// ⛔ BOTH PARAMETERS, ALWAYS. The SAME path with `threadKey` ABSENT is the
    /// LIST endpoint — see ``drafts(workspaceId:)`` — which answers
    /// `{success, drafts: [...]}`, a different key and a different type. Dropping
    /// the thread key here does not 400; it decodes as a draft-less response and
    /// the composer silently restores nothing.
    ///
    /// ⛔ `null` IS THE ORDINARY ANSWER AND NOT A FAILURE. Almost every thread has
    /// no draft; the server answers `{success, draft: null}` rather than 404
    /// precisely so the composer's normal open path is not an error in every log.
    static func draft(workspaceId: String, threadKey: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .draft,
            .get,
            DistrictPaths.messagesDrafts,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("threadKey", threadKey),
            ]
        )
    }

    /// Every draft this author has open, newest first.
    ///
    /// ⚠️ READ ONCE PER INBOX LOAD TO BADGE THE LIST, NOT PER ROW. It is one
    /// indexed query capped at 100 rows; a per-thread call would be one request
    /// per visible conversation.
    static func drafts(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .drafts,
            .get,
            DistrictPaths.messagesDrafts,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Upsert a draft.
    ///
    /// ⛔ **PUT, NOT POST.** The route exports GET/PUT/DELETE only; a POST is a
    /// 405, and the upsert semantics are why PUT is the honest verb — autosave
    /// has no create-versus-update distinction to express.
    ///
    /// ⛔ NEVER WITH A BLANK BODY. The server answers 400 `code: "empty_body"` and
    /// means "send DELETE instead" — a blank draft is the absence of one.
    ///
    /// ⚠️ Rate limited at 60 writes/min per WORKSPACE, shared with
    /// ``deleteDraft(workspaceId:threadKey:)``. That is an autosave ceiling rather
    /// than a meter, but a debounce tighter than a second would reach it with two
    /// operators in one workspace.
    static func saveDraft(
        workspaceId: String,
        threadKey: String,
        body: String,
        subject: String? = nil,
        mediaUrls: [String] = []
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveDraft,
            .put,
            DistrictPaths.messagesDrafts,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("threadKey", .string(threadKey)),
                ("body", .string(body)),
                ("subject", .optional(subject)),
                ("mediaUrls", .array(mediaUrls.map { JSONValue.string($0) })),
            ]))
        )
    }

    /// Delete a draft. Idempotent: deleting one that is not there succeeds,
    /// because the goal state is met.
    ///
    /// ⚠️ QUERY PARAMETERS AND NO BODY, like `contacts/delete`. The route reads
    /// `url.searchParams`.
    static func deleteDraft(workspaceId: String, threadKey: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteDraft,
            .delete,
            DistrictPaths.messagesDrafts,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("threadKey", threadKey),
            ]
        )
    }

    /// Generate a reply with the model.
    ///
    /// ⛔ **SINGULAR `messages/draft` — THIS IS THE BILLED ONE**, and it is one
    /// letter from ``saveDraft(workspaceId:threadKey:body:subject:mediaUrls:)``'s
    /// plural persistence path. One Vertex generation per call, capped at 20/min
    /// per workspace, non-idempotent. Pointing an autosave here would bill a
    /// model call on every keystroke debounce and nothing about the name would
    /// suggest it. `DraftPathTrapTests` pins both paths.
    static func generateDraft(
        workspaceId: String,
        contactId: String?,
        phoneNumber: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .generateDraft,
            .post,
            DistrictPaths.messagesDraft,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .optional(contactId)),
                ("phoneNumber", .optional(phoneNumber)),
            ]))
        )
    }
}
