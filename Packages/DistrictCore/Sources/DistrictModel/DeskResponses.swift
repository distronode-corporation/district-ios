import Foundation

// District Desk — the tenant's OWN customers' tickets.
//
// ⛔ THIS IS NOT THE SUPPORT DESK, AND THE TWO POINT IN OPPOSITE DIRECTIONS.
// `/api/district/desk/*` is where the TENANT'S customers' requests land, filed by
// the tenant's own agent when a call cannot be resolved. `/api/district/support/*`
// is where the tenant raises something WITH DISTRONODE. The web sidebar carries a
// comment demanding the labels stay apart, because a two-word nav entry cannot
// carry the distinction on its own and a bare "Tickets" on either surface undoes
// it. Every string in this family says whose customers it means.
//
// ⛔ AND THERE IS A THIRD `desk` FAMILY THIS CLIENT MUST NEVER ADDRESS.
// `/api/desk/threads/{handle}` is the PUBLIC page a tenant's customer opens from
// their notification email; it authenticates with a capability token and an
// HttpOnly cookie rather than a bearer, and it is the only surface that may show a
// stranger a thread. `/api/internal/desk-lookup` and `/api/internal/desk-ticket`
// are the voice agent's, behind the internal-key middleware. Neither has an
// `EndpointID`, and both are unconstructible from here.

/// Where a ticket sits.
///
/// ⛔ A CLOSED VOCABULARY ON THE WRITE AND FREE TEXT ON THE READ, WHICH IS THE SAME
/// ASYMMETRY ``KnowledgeMode`` MAKES AND FOR THE SAME REASON. `POST
/// /api/district/desk/tickets/{id}/status` validates with `z.enum(DESK_TICKET_STATUSES)`,
/// so a write typed as this enum cannot earn that 400. The column behind it is a
/// plain `TEXT` — chosen server-side so adding a state never needs a migration on
/// four databases — so a status this build has not learned must arrive as a value to
/// DISPLAY rather than as a decode failure that blanks a queue.
///
/// ⚠️ `waiting` MEANS THE BALL IS WITH THE CUSTOMER, NOT THAT THE TEAM IS WAITING.
/// A team reply auto-sets it and a customer message moves it back to `open`; an
/// assistant note changes nothing. Wording it the other way round in a UI inverts
/// the one thing the badge is for.
public enum DeskTicketStatus: String, Sendable, CaseIterable, Equatable {
    /// With the team.
    case open
    /// Answered; the ball is with the customer.
    case waiting
    /// ⚠️ Sticky. A note added to a resolved ticket does not reopen it.
    case resolved
}

/// The workspace's desk configuration, as `GET`/`PATCH /api/district/desk/settings`
/// and both logo calls all echo it.
///
/// ⛔ `enabled` IS NOT A COSMETIC TOGGLE AND A UI MUST SAY SO BEFORE IT IS FLIPPED.
/// Turning it on re-routes the voice agent's unresolved-call teardown away from
/// Distronode's desk and into this workspace's queue, and lets callers ask the agent
/// for the status of their own requests. Both consequences land on a LIVE CALL, so
/// discovering them afterwards means discovering them in production. The server's
/// default is false for a workspace that has never touched it, deliberately.
///
/// ⛔ `enabled` IS A `Bool` HERE AND MUST NOT BECOME `Bool?`. On the wire the server
/// always sends one (a missing row falls back to `DESK_SETTINGS_DEFAULTS`), so the
/// three-state "on / off / could not ask" the screens need is a property of the
/// REQUEST's outcome, not of this field: `Result` already carries it. Modelling the
/// unknown here would put a state in the DTO that no response can produce and invite
/// a screen to render "off" for a read that failed — which is the failure this whole
/// family is written to avoid.
///
/// ⚠️ `publicBrandName` NIL MEANS "FALL BACK TO THE WORKSPACE NAME", never "show
/// nothing" and above all never "show ours". The server owns that resolution; this
/// type carries only the stored value, which is why it stays Optional all the way
/// through rather than being defaulted here.
public struct DeskSettings: Codable, Sendable, Equatable {
    /// ⛔ Changes what happens on a live call. See the ⛔ on the type.
    public let enabled: Bool
    /// Whether a team reply emails the customer. Best effort, and only when the
    /// workspace holds an address for them.
    public let notifyCustomersByEmail: Bool
    /// ⛔ RENDERED TO PEOPLE WHO ARE NOT OUR CUSTOMERS: it is the heading on the
    /// tenant's public thread page and the author label on every team reply there.
    /// Bounded at 80 server-side.
    public let publicBrandName: String?
    /// ⛔ WRITTEN ONLY BY THE LOGO ROUTE, NEVER BY THE SETTINGS PATCH. The value has
    /// to be a URL this platform produced, so a caller-supplied string here would let
    /// a workspace member point their customers' page at any image on the internet.
    /// The settings PATCH schema deliberately does not accept it and neither does
    /// ``DistrictEndpoints/saveDeskSettings(workspaceId:enabled:notifyCustomersByEmail:publicBrandName:)``.
    public let publicLogoUrl: String?

    /// The maximum length of ``publicBrandName``.
    ///
    /// ⚠️ A MIRROR OF THE ROUTE'S `z.string().trim().max(80)`, NOT THE AUTHORITY. It
    /// exists so a text field can stop where the server does rather than letting
    /// someone type a heading that is then silently refused; the server's answer
    /// still wins, and if the two disagree this constant is the one to fix.
    public static let brandNameMaxLength = 80
}

/// `GET` and `PATCH /api/district/desk/settings`, and `POST /api/district/desk/logo`.
///
/// ⛔ ONE ENVELOPE FOR THREE ROUTES, WHICH IS THE SERVER'S OWN SHAPE RATHER THAN A
/// CONVENIENCE. All three answer `{success, settings}` with the full row, so the
/// read, the patch echo and the upload echo cannot disagree about what a field
/// means. ⚠️ The logo DELETE is the exception: it carries one extra key and has its
/// own type, ``DeskLogoRemovalResponse``.
public struct DeskSettingsResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ NON-OPTIONAL BECAUSE EVERY SUCCESS PATH EMITS IT. An absent `settings` is
    /// contract drift rather than a state, and the `success` flag is still checked by
    /// hand at the repository, because a required field rejects `{}` and does not
    /// reject a well-formed `success: false`.
    public let settings: DeskSettings
}

/// `DELETE /api/district/desk/logo`.
///
/// ⛔ `objectRemoved` IS A SEPARATE FACT FROM `success` AND COLLAPSING THEM IS THE
/// ONE ANSWER THIS ROUTE MUST NEVER GIVE. The handler clears the column FIRST and
/// deletes the stored object SECOND, in that order on purpose: clearing the column
/// is what stops the tenant's customer-facing page showing the image, and it must not
/// be blocked by a storage error. Deleting the object is what stops the BYTES from
/// being served at all, which is what an abuse takedown needs — so its outcome is
/// reported rather than folded into a blanket success. `success: true` with
/// `objectRemoved: false` means the image is off the page and may still be
/// downloadable from the URL it had.
///
/// ⚠️ IT IS ALSO `false` FOR THE ORDINARY IDEMPOTENT CASE: a workspace that had no
/// logo gets `{success: true, settings, objectRemoved: false}` because there was
/// nothing to delete. A UI that reads it as a warning has to know the difference,
/// which is why ``DeskLogoRemoval`` is returned only when a logo was actually set.
public struct DeskLogoRemovalResponse: Codable, Sendable {
    public let success: Bool
    public let settings: DeskSettings
    /// ⛔ False means the bytes may still be served. See the ⛔ on the type.
    public let objectRemoved: Bool
}
