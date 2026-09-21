import Foundation

/// How ``DistrictEndpoints/saveDeskSettings(workspaceId:enabled:notifyCustomersByEmail:publicBrandName:)``
/// is told to touch the public brand name.
///
/// ⛔ THREE STATES, AND AN `Optional<String>` CANNOT EXPRESS THEM. The route
/// distinguishes ABSENT ("leave it alone"), a string ("store this") and an explicit
/// NULL ("clear it, and fall back to the workspace name"), and ``JSONValue/object(_:)``
/// drops a nil pair by design — so a nil `String?` here would silently mean "leave it
/// alone" at the one call site whose whole purpose is to clear the value.
///
/// ⛔ THIS IS THE FIRST AND ONLY USER OF `JSONValue`'S EXPLICIT-NULL ESCAPE HATCH.
/// Its doc says a pair whose value is `.some(.null)` is KEPT, and that "nothing uses
/// it today, and it must stay an explicit choice at the call site". ``clear`` is that
/// choice, made once, in a named case rather than in a literal somewhere.
///
/// ⚠️ AN EMPTY STRING WOULD ALSO CLEAR IT, and relying on that would be a mistake to
/// inherit. The route's schema is `.string().trim().max(80).transform(v => v || null)`,
/// so `"  "` reaches the column as null today — but that is a coincidence of the
/// transform rather than the contract, and ``clear`` says what is meant.
public enum DeskBrandName: Sendable, Equatable {
    /// Store this name. ⚠️ Trimmed and bounded at 80 server-side; over-length is a 400.
    case set(String)
    /// ⛔ Clear it. The tenant's customers then see the workspace's own name.
    case clear
}

/// A ticket an operator is raising on a customer's behalf.
///
/// ⛔ A PARAMETER OBJECT RATHER THAN SEVEN ARGUMENTS, the same shape
/// ``MessagingAccountDraft`` takes and for a sharper reason: five of these fields are
/// strings, three of them are optional, and three of THOSE are the customer's name,
/// email address and phone number. A positional list of interchangeable strings is
/// exactly where an email ends up in the phone column, which then reaches the customer
/// as the address a notification is sent to.
///
/// ⛔ A BLANK OPTIONAL MUST ARRIVE HERE AS nil, NOT AS `""`. The route's schema permits
/// these keys to be ABSENT and not present-and-empty: `requesterEmail: ""` fails
/// `.email()` and takes the whole object down, so a phone-only ticket 400s with "A
/// subject and a description are required", naming two fields that were both filled
/// in. ``DeskRepository`` trims to nil on the way in, so a form may hand it whatever
/// is in its boxes.
///
/// ⚠️ BOUNDS, SO A FORM CAN STOP WHERE THE SERVER DOES: subject 3-200, message
/// 1-10,000, name 200, email 320, phone 40.
public struct DeskTicketDraft: Sendable, Equatable {
    public let subject: String
    /// ⛔ THE OPENING MESSAGE, AND THE SERVER STORES IT AS THE CUSTOMER'S OWN WORDS. A
    /// ticket an operator raises on someone's behalf still records the CUSTOMER as the
    /// author: it is their problem, and attributing it to the team would make the
    /// thread read as us talking to ourselves. The author type is fixed server-side.
    public let message: String
    public let requesterName: String?
    public let requesterEmail: String?
    public let requesterPhone: String?
    /// The `Contact` row this ticket belongs to, when the operator picked one.
    public let contactId: String?

    public init(
        subject: String,
        message: String,
        requesterName: String? = nil,
        requesterEmail: String? = nil,
        requesterPhone: String? = nil,
        contactId: String? = nil
    ) {
        self.subject = subject
        self.message = message
        self.requesterName = requesterName
        self.requesterEmail = requesterEmail
        self.requesterPhone = requesterPhone
        self.contactId = contactId
    }
}

/// District Desk: the tenant's own customers' tickets, and the queue's settings.
///
/// ⛔ EVERY ONE OF THESE NINE CARRIES `workspaceId` AS A **QUERY** PARAMETER,
/// INCLUDING THE MULTIPART UPLOAD AND THE THREE THAT ALSO HAVE BODIES. All nine
/// routes read `new URL(req.url).searchParams.get("workspaceId")` and hand it to
/// `requireWorkspaceRole` before anything else runs. Putting it in the body instead
/// — which is what `scheduling/enable` does, one file over — leaves the guard with
/// null and the request is refused before the handler is reached, while the body
/// looks entirely correct.
///
/// ⛔ ALL NINE ARE `["agency","client"]` AND EXCLUDE `viewer`, READS INCLUDED. That is
/// unusual on this surface and it is not an oversight: these payloads carry a
/// customer's name, email address and phone number in the clear plus the
/// correspondence about them, and a viewer seat exists to watch operations, which is
/// different in kind. The server's own comment says that if a viewer ever needs to
/// know a queue exists, the answer is a count endpoint rather than widening these.
/// So the ENTRY POINT must be hidden for a viewer, not merely captioned — the same
/// call ``workspaceConfig(workspaceId:)`` makes.
///
/// ⚠️ NOTHING HERE IS BILLABLE AND NOTHING HERE IS IRREVERSIBLE, which is worth
/// stating because most of the write surfaces in this client are one or the other.
/// The two rate limits that exist (30 creates and 60 replies per hour per workspace)
/// bound a runaway client rather than a spend.
public extension DistrictEndpoints {
    /// The workspace's desk configuration.
    ///
    /// ⛔ THIS IS THE READ THAT DECIDES WHICH SCREEN TO DRAW, AND ITS FAILURE IS A
    /// THIRD STATE. `enabled: false` means the queue is empty BY CONSTRUCTION and
    /// nothing is being recorded; a failed read means we could not ask. Rendering the
    /// second as the first sends an operator to turn on something already on, and
    /// rendering either as an empty ticket list says "no customer has ever contacted
    /// you", which is a lie in both cases.
    ///
    /// ⚠️ A WORKSPACE THAT HAS NEVER TOUCHED THE DESK STILL GETS A FULL BODY. There is
    /// no row until something is saved, and the server answers its own defaults rather
    /// than 404, so "no settings yet" is not a state this client can observe.
    static func deskSettings(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deskSettings,
            .get,
            DistrictPaths.deskSettings,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Change one or more desk settings.
    ///
    /// ⛔ SEND ONLY WHAT CHANGED. This is a PATCH and the route merges per field, so an
    /// omitted key is PRESERVED — and a client that posted its whole form state would
    /// make this screen the writer of values it may have read before another tab
    /// changed them. That is the `blank_form_overwrites_config` shape: a form saved
    /// after a failed load writing blanks over live configuration. The nil-dropping in
    /// ``JSONValue/object(_:)`` is the mechanism by which "only what changed" reaches
    /// the wire.
    ///
    /// ⛔ AN EMPTY PATCH IS A **400**, NOT A NO-OP 200. The route refines on at least
    /// one field being present, deliberately, because an empty body is always a client
    /// bug and answering 200 hides it. A caller that has nothing to change must not
    /// call this at all.
    ///
    /// ⛔ `publicLogoUrl` IS NOT A PARAMETER AND MUST NEVER BECOME ONE. The route's
    /// schema does not accept it: the value has to be a URL this platform produced, so
    /// only the logo route may store one. A caller-supplied string there would let a
    /// workspace member point their own customers' page at any image on the internet,
    /// with our domain's reputation attached.
    ///
    /// ⚠️ IT ECHOES THE WHOLE STORED ROW, so this write needs no re-read — and the echo
    /// is what must be adopted, never the values that were sent.
    static func saveDeskSettings(
        workspaceId: String,
        enabled: Bool?,
        notifyCustomersByEmail: Bool?,
        publicBrandName: DeskBrandName?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveDeskSettings,
            .patch,
            DistrictPaths.deskSettings,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("enabled", enabled.map { JSONValue.bool($0) }),
                ("notifyCustomersByEmail", notifyCustomersByEmail.map { JSONValue.bool($0) }),
                ("publicBrandName", publicBrandName.map(brandNameValue)),
            ]))
        )
    }

    /// Publish a logo for the tenant's customer-facing thread page.
    ///
    /// ⛔ THE WORKSPACE IS A QUERY PARAMETER AND THE MULTIPART BODY CARRIES **NO
    /// FIELDS AT ALL**, which is the one way this differs from ``uploadMedia`` and the
    /// only way to get it wrong. That route reads `workspaceId` off `req.formData()`;
    /// this one reads it off the URL. A part list copied from there leaves
    /// `requireWorkspaceRole` with null.
    ///
    /// ⛔ THE BYTES ARE PUBLISHED TO A WORLD-READABLE, DISTRONODE-CONTROLLED DOMAIN,
    /// for an audience that is not our customers. That is why there is no
    /// unauthenticated upload path and must never be one: the bound on abuse is that
    /// every byte is attributable to a named member of a workspace we can suspend.
    ///
    /// ⚠️ ITS REFUSALS ARE NOT ALL 400. 413 for too large, 415 for a media type the
    /// server will not host (an SVG lands here, sniffed from the bytes rather than
    /// trusted from the header), 400 for empty or out-of-bounds pixel dimensions, 502
    /// when object storage refused the write and 503 when logo hosting is not
    /// configured at all. Surface the server's own sentence; this client cannot
    /// pre-compute any of them.
    ///
    /// ⚠️ RE-UPLOADING THE SAME IMAGE IS A NO-OP RATHER THAN A CHURN. The object key is
    /// content-addressed, so the row ends up pointing at the same URL and the previous
    /// object is not swept.
    static func uploadDeskLogo(
        workspaceId: String,
        fileName: String,
        mimeType: String,
        bytes: Data
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .uploadDeskLogo,
            .post,
            DistrictPaths.deskLogo,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .multipart(MultipartBody(
                // ⛔ EMPTY, AND THAT IS THE POINT. See the ⛔ on this function.
                fields: [:],
                fileName: fileName,
                contentType: mimeType,
                bytes: bytes
            ))
        )
    }

    /// Take the logo down.
    ///
    /// ⛔ A **DELETE WITH A QUERY AND NO BODY**, like every other delete on this API.
    ///
    /// ⛔ IT IS THE TAKEDOWN PATH, NOT A TIDY-UP, WHICH IS WHY ITS ANSWER HAS TWO
    /// PARTS. The column is cleared first (that is what stops the image appearing on
    /// the tenant's customer-facing page) and the stored object second (that is what
    /// stops the bytes being served at all). A 200 says the first happened;
    /// `objectRemoved` says whether the second did. See ``DeskLogoRemovalResponse``.
    ///
    /// ⚠️ IDEMPOTENT: a workspace with no logo gets a 200 with `objectRemoved: false`.
    static func deleteDeskLogo(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteDeskLogo,
            .delete,
            DistrictPaths.deskLogo,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// The workspace's ticket queue, newest activity first.
    ///
    /// ⚠️ THE `status` FILTER IS OPTIONAL AND A SCREEN SHOWING COUNTS SHOULD NOT USE
    /// IT. Every filter chip on the web carries a count, so filtering server-side would
    /// mean four requests to draw one row of chips — and the counts could then disagree
    /// with each other between responses. Read the queue whole and filter locally; the
    /// parameter exists for a caller that genuinely wants one slice.
    ///
    /// ⚠️ THE ROUTE CAPS AT 100 ROWS AND HAS NO PAGING. There is no cursor, no offset
    /// and no `total`, so a workspace past the cap silently sees its 100 most recently
    /// updated tickets. Worth knowing before describing this list as complete.
    ///
    /// ⛔ AN EMPTY LIST IS NOT "THE DESK IS OFF". Those are two different screens with
    /// two different sentences, and the settings read is what tells them apart.
    ///
    /// ⚠️ `status` IS A `String` HERE AND A ``DeskTicketStatus`` AT THE REPOSITORY,
    /// which is the same split ``saveKnowledgeMode(workspaceId:mode:)`` makes: the
    /// closed vocabulary is enforced one tier up, and this module keeps its
    /// dependency on `DistrictModel` out of the request builders.
    static func deskTickets(workspaceId: String, status: String?) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deskTickets,
            .get,
            DistrictPaths.deskTickets,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                // ⚠️ A nil is DROPPED rather than sent empty. `status=` present-and-empty
                // is not in the route's vocabulary, so it would fall through to "no
                // filter" — the same answer by accident rather than by contract.
                ApiQueryItem("status", status),
            ]
        )
    }

    /// Raise a ticket by hand, for something a customer brought another way.
    ///
    /// ⛔ THE OPENING MESSAGE FIELD IS `message`, MATCHING THE REPLY ROUTE AND NOT THE
    /// SUPPORT DESK'S `body`. Everything else about the draft is on ``DeskTicketDraft``,
    /// including why the three requester fields must be nil rather than `""`.
    ///
    /// ⚠️ `idempotencyKey` IS PER SUBMIT, NOT PER SCREEN. It must be minted when the
    /// operator taps send, so a double tap collapses onto one ticket; a key held across
    /// submits would swallow the SECOND ticket as a duplicate. It is a `uuid` in the
    /// schema, so `UUID().uuidString` satisfies it. ⚠️ Omitting it is legal and simply
    /// forgoes the protection.
    static func createDeskTicket(
        workspaceId: String,
        draft: DeskTicketDraft,
        idempotencyKey: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createDeskTicket,
            .post,
            DistrictPaths.deskTickets,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("subject", .string(draft.subject)),
                ("message", .string(draft.message)),
                ("requesterName", .optional(draft.requesterName)),
                ("requesterEmail", .optional(draft.requesterEmail)),
                ("requesterPhone", .optional(draft.requesterPhone)),
                ("contactId", .optional(draft.contactId)),
                ("idempotencyKey", .optional(idempotencyKey)),
            ]))
        )
    }

    /// One ticket and its whole thread.
    ///
    /// ⚠️ A FOREIGN ID IS A **404**, not a 403, and that is a disclosure decision as
    /// well as a correctness one: the read is scoped by `workspaceId` in the
    /// where-clause AND by RLS, so a foreign id simply finds nothing, and 403 would
    /// confirm the id exists somewhere on the platform.
    static func deskTicket(workspaceId: String, ticketId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deskTicket,
            .get,
            DistrictPaths.deskTicket(ticketId),
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Answer the customer.
    ///
    /// ⛔ THE FIELD IS `message`. The route's schema is `z.object({ message })`, so a
    /// body spelled `body` parses to nothing and every reply 400s with "A message is
    /// required" — while the adjacent SUPPORT desk's reply takes exactly `body`. Two
    /// surfaces one word apart, and the failure is a plausible-looking request that
    /// never lands.
    ///
    /// ⛔ AND THE SERVER'S ROUTE SOURCE READS LIKE EVIDENCE FOR THE WRONG ANSWER, WHICH
    /// IS WHY THIS IS PINNED BY A TEST RATHER THAN BY THIS COMMENT. It contains the
    /// word `body` twice and NEITHER is the request field: one is the local holding
    /// the parsed request, the other passes `body: parsed.data.message` into the
    /// internal `replyToDeskTicket` call — an INTERNAL parameter name, on the far side
    /// of the schema. A reader grepping it for "body" finds both, in plausible
    /// positions, and concludes the opposite of the truth. `EndpointTable+Desk` asserts the serialised bytes and
    /// `EndpointSurfaceTests` asserts them again, so an edit that "harmonises" the two
    /// desks fails a test instead of shipping a silent 400.
    ///
    /// ⛔ THE AUTHOR TYPE IS FIXED TO `team` SERVER-SIDE AND IS NOT A PARAMETER. It
    /// decides three things at once — the status transition, whether the customer is
    /// emailed, and how the message is attributed in the thread — so accepting it from
    /// the wire would let a caller post a message attributed to their own customer and
    /// suppress the notification while doing it.
    ///
    /// ⛔ A REPLY AUTO-SETS THE TICKET TO `waiting` UNLESS IT IS RESOLVED, which is why
    /// the response carries the ticket as well as the message. Adopt the echoed status;
    /// a screen that assumed `waiting` would be wrong for a resolved ticket, where the
    /// server deliberately leaves the state alone.
    ///
    /// ⚠️ `idempotencyKey` IS SCOPED TO THE TICKET AS WELL AS THE WORKSPACE server-side,
    /// so the same key legitimately reaches two different tickets from a client that
    /// mints one per composer session. Mint it per SUBMIT anyway.
    static func replyToDeskTicket(
        workspaceId: String,
        ticketId: String,
        message: String,
        idempotencyKey: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .replyToDeskTicket,
            .post,
            DistrictPaths.deskTicketReply(ticketId),
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                // ⛔ `message`, NOT `body`. See the ⛔ on this function.
                ("message", .string(message)),
                ("idempotencyKey", .optional(idempotencyKey)),
            ]))
        )
    }

    /// Move a ticket between open, waiting and resolved.
    ///
    /// ⛔ THE ROUTE VALIDATES WITH `z.enum(DESK_TICKET_STATUSES)`, SO AN UNRECOGNISED
    /// VALUE IS A **400** RATHER THAN A STORED ONE. The column behind it is plain
    /// `TEXT` — chosen so adding a state never needs a migration on four databases —
    /// which makes that enum the only thing standing between a typo and a permanent,
    /// unfilterable status on a customer's ticket. ⚠️ The closed vocabulary is
    /// enforced one tier up, at ``DeskRepository``, exactly as
    /// ``saveKnowledgeMode(workspaceId:mode:)`` does: this parameter is a `String` so
    /// the request builders keep no dependency on `DistrictModel`.
    ///
    /// ⛔ RESOLVING STAMPS `resolvedAt` AND REOPENING CLEARS IT, both server-side, which
    /// is why the echoed ticket must be adopted rather than the requested status. A
    /// ticket that was resolved and reopened would otherwise keep a resolution time in
    /// the past, and every figure computed from it is wrong in a way that looks
    /// plausible.
    static func setDeskTicketStatus(
        workspaceId: String,
        ticketId: String,
        status: String
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setDeskTicketStatus,
            .post,
            DistrictPaths.deskTicketStatus(ticketId),
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([("status", .string(status))]))
        )
    }

    /// ⛔ THE EXPLICIT-NULL ESCAPE HATCH, USED DELIBERATELY AND EXACTLY ONCE. See the
    /// ⛔ on ``DeskBrandName``.
    private static func brandNameValue(_ change: DeskBrandName) -> JSONValue {
        switch change {
        case let .set(name): .string(name)
        case .clear: .null
        }
    }
}
