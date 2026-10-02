import DistrictModel
import DistrictNetwork
import Foundation

/// What a create answered.
///
/// ⛔ TWO CASES, BECAUSE A SUCCESS MAY LEGITIMATELY CARRY NO TICKET AND THAT IS NOT AN
/// ERROR. When the submitted `idempotencyKey` has already produced a ticket the route
/// answers `{success: true, deduplicated: true}` and nothing else — deliberately,
/// since reporting a retried submit as a failure would make it look broken and invite
/// a third. Collapsing this into `DeskTicketSummary?` would push the same fork onto
/// every caller as an `if let`, which is where it gets read as "the create failed".
public enum DeskTicketCreation: Sendable, Equatable {
    case created(DeskTicketSummary)
    /// ⛔ A ticket for this key already exists. Re-read the queue; do not resubmit.
    case deduplicated
}

/// What a reply answered.
///
/// ⛔ THE THREAD APPENDS ONLY ``DeskReply/message``, WHICH IS THE SERVER'S OWN COPY OF
/// THE ROW IT WROTE. Never a local echo of the draft: showing one would tell an
/// operator their customer had been answered when the message may never have been
/// stored, which is the worst failure this surface can produce, because the customer
/// is waiting. `createdAt` is a database default, so the only authoritative copy is
/// the one the write returned.
///
/// ⛔ AND ``deduplicatedWithoutBody`` IS A REAL, REACHABLE STATE RATHER THAN A
/// DEFENSIVE BRANCH. Two concurrent submits, or Redis dying between the claim and the
/// cached-result read, produce a bare `{success: true, deduplicated: true}`. No second
/// row was written — which is the property that matters — but there is nothing to add
/// to the thread, so a caller has to refetch rather than append. Treating it as an
/// ordinary success leaves the reply invisible until something else reloads.
public enum DeskReplyOutcome: Sendable, Equatable {
    case posted(DeskReply)
    /// ⛔ The reply is safe and unduplicated; this response cannot show it. Refetch.
    case deduplicatedWithoutBody
}

/// One posted reply, as the server recorded it.
public struct DeskReply: Sendable, Equatable {
    /// ⛔ ADOPT THIS STATUS, never the one a screen assumed. A team reply auto-sets
    /// `waiting` UNLESS the ticket is resolved, where the server leaves it alone.
    public let ticket: DeskTicketSummary
    /// ⛔ The row that was written. Append this. See the ⛔ on ``DeskReplyOutcome``.
    public let message: DeskMessage
    /// ⚠️ REPORTED, NOT ENFORCED. False is an ordinary outcome (no address on file,
    /// notifications off, the daily cap, or Postmark refusing) and never a failure of
    /// the reply itself.
    public let notified: Bool
    /// ⚠️ True when this is the cached replay of an earlier submit. The message is
    /// still the real one; nothing was written twice.
    public let deduplicated: Bool
}

/// What a logo takedown achieved.
///
/// ⛔ TWO FACTS, AND COLLAPSING THEM IS THE ONE ANSWER THIS CALL MUST NEVER GIVE. The
/// column is cleared first and the stored object second: clearing the column is what
/// stops the image appearing on the tenant's customer-facing page, and deleting the
/// object is what stops the bytes being served at all — which is what an abuse
/// takedown actually needs. A response saying the bytes are gone when they are not is
/// exactly what the route's own header forbids.
public struct DeskLogoRemoval: Sendable, Equatable {
    public let settings: DeskSettings
    /// ⛔ False means the image is off the page and MAY STILL BE DOWNLOADABLE from the
    /// URL it had. ⚠️ It is also false for the ordinary idempotent case, a workspace
    /// that had no logo — which is why ``DeskRepository/removeLogo(workspaceId:)``
    /// only ever reports it when there was something to delete.
    public let objectRemoved: Bool
}

/// District Desk: the tenant's own customers' tickets, and the queue's settings.
///
/// ⛔ NOT DISTRONODE'S SUPPORT DESK, AND THE LABELS ARE THE ONLY THING KEEPING THEM
/// APART IN A NAV LIST. This surface is the tenant's customers raising something with
/// the TENANT, filed by their own agent when a call cannot be resolved;
/// `/api/district/support/*` is the tenant raising something with US. Every sentence
/// this repository's callers show has to say whose customers it means, and a bare
/// "Tickets" on either surface undoes that.
///
/// ⛔ ALL NINE ROUTES ARE `["agency","client"]` AND EXCLUDE `viewer`, READS INCLUDED,
/// which is the OPPOSITE split from ``KnowledgeRepository`` and the same one
/// `workspace/config` makes. It is not an oversight: these payloads carry a customer's
/// name, email address and phone number in the clear plus the correspondence about
/// them. So the ENTRY POINT is hidden from a viewer rather than the controls being
/// disabled — a screen whose every call 403s is worse than no row.
///
/// ⛔ NOTHING HERE IS RETRIED, AND TWO OF THE WRITES CARRY A CLIENT-MINTED
/// IDEMPOTENCY KEY INSTEAD. That key is the retry story: it must be minted per SUBMIT
/// so a double tap collapses onto one row, and it must not be held across submits or
/// the second ticket is swallowed as a duplicate. ⚠️ The server's claim is Redis-backed
/// and FAIL-OPEN, so a green response is not proof a duplicate was impossible.
///
/// ⚠️ NO CACHE. A queue is opened to see what has changed, and a settings row decides
/// which of three screens to draw; a process-scoped copy of either would show a state
/// that another operator changed on the web in between.
public struct DeskRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    // MARK: - Settings

    /// The workspace's desk configuration.
    ///
    /// ⛔ ITS FAILURE IS A THIRD STATE AND MUST NOT BE FLATTENED INTO EITHER OF THE
    /// OTHER TWO. `enabled: false` means the queue is empty BY CONSTRUCTION and nothing
    /// is being recorded; a `.failure` means we could not ask. Rendering the second as
    /// the first sends an operator to switch on something already on, and rendering
    /// either as an empty ticket list claims no customer has ever contacted them.
    ///
    /// ⚠️ ENVELOPE-CHECKED EVEN THOUGH THE DTO'S FIELDS ARE REQUIRED. A required field
    /// rejects `{}`; it does not reject a well-formed body that says `success: false`,
    /// which is what a handler falling into its own error branch after the headers are
    /// written produces on a 200.
    public func settings(workspaceId: String) async -> Result<DeskSettings, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.deskSettings(workspaceId: workspaceId),
            as: DeskSettingsResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskSettingsResponse", $0.success, $0) }
            .map(\.settings)
    }

    /// Change one or more desk settings.
    ///
    /// ⛔ PASS ONLY WHAT THE OPERATOR CHANGED. Every parameter is Optional and a nil is
    /// DROPPED from the body, because the route merges per field: an omitted key is
    /// preserved, and a caller that sent its whole form state would make this the
    /// writer of values it may have read before another tab changed them.
    ///
    /// ⛔ AN ALL-NIL CALL IS A **400**, NOT A NO-OP, and it is refused here before a
    /// round trip is spent learning that. The route refines on at least one field
    /// being present precisely because an empty body is always a client bug.
    ///
    /// ⛔ THE ECHO IS ADOPTED, NEVER THE VALUES THAT WERE SENT. The route answers the
    /// whole stored row, so this write needs no re-read — and the row is what a later
    /// read will see, which a locally-assembled copy would not be.
    ///
    /// ⚠️ `publicLogoUrl` IS ABSENT FROM THIS SIGNATURE ON PURPOSE and must stay
    /// absent. The route's schema does not accept it: only the logo route may store
    /// one, because the value has to be a URL this platform produced.
    public func updateSettings(
        workspaceId: String,
        enabled: Bool? = nil,
        notifyCustomersByEmail: Bool? = nil,
        publicBrandName: DeskBrandName? = nil
    ) async -> Result<DeskSettings, ApiError> {
        guard enabled != nil || notifyCustomersByEmail != nil || publicBrandName != nil else {
            // ⚠️ SHAPED AS THE ROUTE'S OWN 400 so a caller has one failure path rather
            // than two. The message is this client's, because the server never saw it.
            return .failure(.http(status: 400, message: "At least one setting must be provided."))
        }
        let descriptor = DistrictEndpoints.saveDeskSettings(
            workspaceId: workspaceId,
            enabled: enabled,
            notifyCustomersByEmail: notifyCustomersByEmail,
            publicBrandName: publicBrandName
        )
        let outcome = await client.send(descriptor, as: DeskSettingsResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskSettingsResponse", $0.success, $0) }
            .map(\.settings)
    }

    // MARK: - The logo the tenant's customers see

    /// Publish a logo for the tenant's customer-facing thread page.
    ///
    /// ⛔ THESE BYTES BECOME PUBLIC, on a Distronode-controlled domain, to an audience
    /// that is not our customers. A caller must say so before a file is picked rather
    /// than after it is uploaded.
    ///
    /// ⚠️ THE TWO CHEAP CHECKS RUN FIRST, and they are a courtesy rather than a
    /// control: see ``DeskLogoLimits``. Everything the server actually enforces — the
    /// magic-number sniff that refuses an SVG whatever its filename claims, the pixel
    /// bounds, the animation check — happens there and cannot be anticipated here.
    ///
    /// ⚠️ IT ECHOES THE WHOLE SETTINGS ROW, like the PATCH, so a caller adopts that
    /// rather than assembling a new URL. There is no optimistic preview to be had: a
    /// local file URL shown as "your customers can see this" would be a claim about an
    /// upload that may never have landed.
    ///
    /// ⚠️ THE PART'S FILENAME IS A CONSTANT, ``logoFileName``, AND NO CALLER PASSES ONE.
    /// A filename is what makes the multipart part a file at all (without one the
    /// route's `file instanceof File` check fails), but the server stores the mime
    /// type and the byte length and never reads the name, so a stable placeholder is
    /// honest and a guessed extension would not be.
    public func uploadLogo(
        workspaceId: String,
        mimeType: String,
        bytes: Data
    ) async -> Result<DeskSettings, ApiError> {
        if let refusal = DeskLogoLimits.refusal(mimeType: mimeType, byteCount: bytes.count) {
            return .failure(refusal)
        }
        let descriptor = DistrictEndpoints.uploadDeskLogo(
            workspaceId: workspaceId,
            fileName: Self.logoFileName,
            mimeType: mimeType,
            bytes: bytes
        )
        let outcome = await client.send(descriptor, as: DeskSettingsResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskSettingsResponse", $0.success, $0) }
            .map(\.settings)
    }

    static let logoFileName = "logo"

    /// Take the logo down, and delete the stored object with it.
    ///
    /// ⛔ THE RESULT CARRIES BOTH HALVES. See ``DeskLogoRemoval``: a 200 says the image
    /// is off the tenant's customer-facing page, and `objectRemoved` says whether the
    /// bytes are gone from storage too. Only the second is a takedown.
    public func removeLogo(workspaceId: String) async -> Result<DeskLogoRemoval, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.deleteDeskLogo(workspaceId: workspaceId),
            as: DeskLogoRemovalResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskLogoRemovalResponse", $0.success, $0) }
            .map { DeskLogoRemoval(settings: $0.settings, objectRemoved: $0.objectRemoved) }
    }

    // MARK: - The queue

    /// The workspace's tickets, most recently updated first.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND MUST NOT RENDER AS A FAILURE — nor as "the
    /// desk is off", which is a different fact with a different screen and comes from
    /// ``settings(workspaceId:)``.
    ///
    /// ⚠️ PREFER NO `status` AND FILTER LOCALLY when the screen shows per-status
    /// counts: a server-side filter would need one request per chip, and the counts
    /// could then disagree with each other between responses.
    ///
    /// ⚠️ CAPPED AT 100 ROWS SERVER-SIDE WITH NO PAGING. There is no cursor and no
    /// total, so a busy workspace silently sees its 100 most recently updated tickets.
    public func tickets(
        workspaceId: String,
        status: DeskTicketStatus? = nil
    ) async -> Result<[DeskTicketSummary], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.deskTickets(workspaceId: workspaceId, status: status?.rawValue),
            as: DeskTicketsResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskTicketsResponse", $0.success, $0) }
            .map(\.tickets)
    }

    /// Raise a ticket by hand.
    ///
    /// ⛔ BLANK OPTIONALS ARE NORMALISED TO ABSENT HERE, AND THAT IS NOT COSMETIC. The
    /// route's schema permits these keys to be ABSENT, not present-and-empty:
    /// `requesterEmail: ""` fails `.email()` and takes the whole object down, so a
    /// phone-only ticket would 400 with "A subject and a description are required",
    /// naming two fields that were both filled in. A form hands over whatever is in
    /// its boxes, so the trim-to-nil belongs on this tier rather than in each screen —
    /// which is exactly why the draft is rebuilt below rather than passed through.
    ///
    /// ⚠️ `idempotencyKey` MUST BE MINTED PER SUBMIT. Held across submits it swallows
    /// the second ticket as a duplicate; omitted, a double tap files two. It is not
    /// generated here because a repository cannot tell one tap from two.
    ///
    /// ⛔ NOTHING RETRIES THIS. The claim behind the key is fail-open, so a resend
    /// during a Redis outage creates a second ticket in a human's queue.
    public func createTicket(
        workspaceId: String,
        draft: DeskTicketDraft,
        idempotencyKey: String? = nil
    ) async -> Result<DeskTicketCreation, ApiError> {
        let descriptor = DistrictEndpoints.createDeskTicket(
            workspaceId: workspaceId,
            draft: DeskTicketDraft(
                subject: draft.subject,
                message: draft.message,
                requesterName: blankToNil(draft.requesterName),
                requesterEmail: blankToNil(draft.requesterEmail),
                requesterPhone: blankToNil(draft.requesterPhone),
                contactId: blankToNil(draft.contactId)
            ),
            idempotencyKey: idempotencyKey
        )
        let outcome = await client.send(descriptor, as: DeskTicketCreateResponse.self)
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("DeskTicketCreateResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            if let ticket = response.ticket {
                return .success(.created(ticket))
            }
            if response.deduplicated == true {
                return .success(.deduplicated)
            }
            // ⚠️ NEITHER A TICKET NOR A DEDUPE FLAG IS DRIFT, NOT AN EMPTY SUCCESS.
            // Reporting it as a create would leave a caller to invent a row that was
            // never made, and reporting it as a dedupe would claim one exists.
            return .failure(.decoding("DeskTicketCreateResponse affirmed success with no ticket"))
        case let .failure(error):
            return .failure(error)
        }
    }

    /// One ticket and its whole thread.
    ///
    /// ⚠️ A TICKET THAT IS NOT THIS WORKSPACE'S IS A **404**, which arrives as
    /// ``ApiError/http(status:message:)`` rather than as a nil, so a nil `ticket` on a
    /// 200 is contract drift and is reported as such.
    public func ticket(workspaceId: String, ticketId: String) async -> Result<DeskTicketDetail, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.deskTicket(workspaceId: workspaceId, ticketId: ticketId),
            as: DeskTicketResponse.self
        )
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("DeskTicketResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            guard let ticket = response.ticket else {
                return .failure(.decoding("DeskTicketResponse affirmed success with no ticket"))
            }
            return .success(ticket)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Answer the customer.
    ///
    /// ⛔ THE WIRE FIELD IS `message` AND THE SUPPORT DESK'S IS `body`. Transposing
    /// them is a silent 400 from a request that reads perfectly well. That spelling is
    /// settled in ``DistrictEndpoints/replyToDeskTicket(workspaceId:ticketId:message:idempotencyKey:)``
    /// and nothing above this tier should ever have to know it.
    ///
    /// ⛔ APPEND ONLY ``DeskReply/message`` AND ONLY ON ``DeskReplyOutcome/posted(_:)``.
    /// The other case means the reply is safe and unduplicated and this response
    /// cannot show it, so the thread must be refetched — not left looking as though
    /// nothing was sent, and not filled in from the draft.
    ///
    /// ⛔ NOT RETRIED. Resending without a key appends a second message to a customer's
    /// thread; resending with the same key relies on a fail-open Redis claim.
    public func reply(
        workspaceId: String,
        ticketId: String,
        message: String,
        idempotencyKey: String? = nil
    ) async -> Result<DeskReplyOutcome, ApiError> {
        let descriptor = DistrictEndpoints.replyToDeskTicket(
            workspaceId: workspaceId,
            ticketId: ticketId,
            message: message,
            idempotencyKey: idempotencyKey
        )
        let outcome = await client.send(descriptor, as: DeskReplyResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeskReplyResponse", $0.success, $0) }
            .map(replyOutcome)
    }

    /// Move a ticket between open, waiting and resolved.
    ///
    /// ⛔ ADOPT THE ECHOED TICKET, NEVER THE STATUS THAT WAS ASKED FOR. Resolving
    /// stamps `resolvedAt` and reopening CLEARS it, both server-side, so the row that
    /// comes back carries a fact the request did not.
    ///
    /// ⚠️ THE PARAMETER IS THE ENUM, WHICH IS WHAT MAKES THE ROUTE'S 400 UNREACHABLE
    /// FROM THIS CLIENT.
    public func setStatus(
        workspaceId: String,
        ticketId: String,
        status: DeskTicketStatus
    ) async -> Result<DeskTicketSummary, ApiError> {
        let descriptor = DistrictEndpoints.setDeskTicketStatus(
            workspaceId: workspaceId,
            ticketId: ticketId,
            status: status.rawValue
        )
        let outcome = await client.send(descriptor, as: DeskTicketStatusResponse.self)
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("DeskTicketStatusResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            guard let ticket = response.ticket else {
                return .failure(.decoding("DeskTicketStatusResponse affirmed success with no ticket"))
            }
            return .success(ticket)
        case let .failure(error):
            return .failure(error)
        }
    }

    // MARK: - Internals

    /// ⛔ THE TICKET AND THE MESSAGE ARE REQUIRED TOGETHER OR NOT AT ALL. A response
    /// carrying one without the other has never been observed and is not a state the
    /// route defines; treating it as `posted` would mean inventing the half that is
    /// missing, and the degraded replay is exactly the right answer for it — the reply
    /// is safe, and this response cannot show it.
    private func replyOutcome(_ response: DeskReplyResponse) -> DeskReplyOutcome {
        guard let ticket = response.ticket, let message = response.message else {
            return .deduplicatedWithoutBody
        }
        return .posted(DeskReply(
            ticket: ticket,
            message: message,
            // ⚠️ ABSENT MEANS "NOT SENT" RATHER THAN "UNKNOWN". The only shape that
            // omits the key is the degraded replay, which does not reach this line, so
            // a nil here is drift and false is the answer that cannot mislead: it
            // states no email went out, which is what a caller can act on.
            notified: response.notified ?? false,
            deduplicated: response.deduplicated ?? false
        ))
    }

    /// ⛔ TRIM-TO-NIL, BECAUSE ABSENT AND EMPTY ARE DIFFERENT INSTRUCTIONS HERE. See
    /// the ⛔ on ``createTicket``.
    private func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// What the desk logo route accepts, mirrored so a doomed upload is refused before it
/// is sent.
///
/// ⚠️ A MIRROR, NOT THE AUTHORITY, exactly as ``MediaUploadLimits`` is for the
/// composer's attachments. The server re-derives both of these from the ACTUAL bytes
/// and its answer wins; duplicating the two cheap checks buys latency and a metered
/// connection, not safety. If the two ever disagree the server is right and this is
/// what moves.
///
/// ⛔ THE THINGS THAT ACTUALLY MAKE THIS ROUTE SAFE ARE NOT MIRRORED AND CANNOT BE.
/// The server sniffs magic numbers, so an SVG renamed `logo.png` with a
/// `image/png` header passes every check below and is refused there — which is the
/// point, since an SVG is a script container being published to a
/// Distronode-controlled domain. The pixel bounds (16 to 2000) need an image decoder
/// this module does not have. A 415 or a 400 naming the rule is the honest way to
/// learn either, and neither may be pre-empted with a guess.
public enum DeskLogoLimits {
    /// The three types the route allows. Anything else is a 415.
    public static let allowedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/webp",
    ]

    /// 512 KB, as the route counts it (`DESK_LOGO_MAX_BYTES`).
    public static let maximumByteCount = 512 * 1024

    /// The refusal to return without sending anything, or nil when the file might be
    /// acceptable.
    ///
    /// ⚠️ "MIGHT BE". A nil here means only that the two checks this client can make
    /// passed, never that the upload will succeed.
    ///
    /// ⚠️ SHAPED AS AN ``ApiError/http(status:message:)`` CARRYING THE ROUTE'S OWN
    /// STATUS — 415 for the type and 413 for the size — so a caller has one failure
    /// path and the sentence it shows is the same one a real refusal would produce.
    public static func refusal(mimeType: String, byteCount: Int) -> ApiError? {
        guard allowedMimeTypes.contains(mimeType) else {
            return .http(status: 415, message: "Logos must be a PNG, JPEG or WebP image.")
        }
        guard byteCount > 0 else {
            return .http(status: 400, message: "That file is empty.")
        }
        guard byteCount <= maximumByteCount else {
            return .http(status: 413, message: "Logos must be 512 KB or smaller.")
        }
        return nil
    }
}
