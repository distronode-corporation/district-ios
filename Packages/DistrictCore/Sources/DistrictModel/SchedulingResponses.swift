import Foundation

/// The state of a workspace's scheduling tenancy.
///
/// ⛔ AN UNKNOWN STRING IS A DECODE FAILURE, NOT A DEFAULT, AND THIS IS THE ONE
/// PLACE ON THIS SURFACE WHERE THAT IS THE RIGHT ANSWER. ``WorkspaceRole`` takes
/// the opposite decision for the opposite reason: `Workspace.role` is a bare
/// column with no server-side union, so a fourth value is a schema-level
/// possibility and a throwing enum there would take out a whole member list over
/// one unrecognised row. Here the column is constrained in SQL by a CHECK and in
/// TypeScript by `SchedulingTenantStatus`, so the vocabulary is closed and owned
/// by the server. A value outside it is contract drift, and the strict gate must
/// see it: a lenient fallback would decode `"retiring"` as `.error`, re-encode it
/// as `"error"`, and the key-set walk would pass because it compares SHAPE and
/// not values.
///
/// ⛔ `error` IS NOT TERMINAL AND `ready` IS NOT PERMANENT. The hourly reconciler
/// re-runs provisioning for `provisioning` and `error` and re-asserts DNS for
/// `ready`, so a screen must re-read rather than latch. `disabled` is the only
/// state the reconciler leaves alone: it means a human, or a workspace deletion,
/// took the tenancy down, and anything that "healed" it would resurrect booking
/// pages somebody switched off.
public enum SchedulingTenantStatus: String, Codable, Sendable, CaseIterable {
    /// The row exists and the multi-system provision has not finished (or has not
    /// been re-run since it last failed). ⚠️ NOT a queue position: the enable
    /// route's work has already run by the time it answers.
    case provisioning
    /// Booking pages are live at ``SchedulingTenant/publicHost``.
    case ready
    /// The last provision failed. ``SchedulingTenant/lastError`` carries the
    /// operator-facing reason, and the reconciler will try again.
    case error
    /// Switched off deliberately. ⛔ The one state nothing re-provisions.
    case disabled
}

/// The workspace's scheduling tenancy, as the status route reports it.
///
/// ⛔ NO CREDENTIAL AND NO CIPHERTEXT REACHES HERE, AND THAT IS THE ROUTE'S
/// `select` RATHER THAN THIS TYPE'S RESTRAINT. `apiKeyEnc` and `webhookSecretEnc`
/// are KMS-wrapped columns the route deliberately does not select;
/// ``hasCredentials`` is the boolean it derives from the first of them, which is
/// what distinguishes a tenancy that can be talked to from one that cannot.
/// Nothing here should ever grow a field that carries the key itself.
///
/// ⚠️ `publicHost` AND `region` ARE NON-OPTIONAL BECAUSE THE COLUMNS ARE. The
/// host is allocated before the platform call and is globally unique (it is a DNS
/// name, and two workspaces claiming one means a customer's bookings landing in
/// someone else's calendar); the region records which scheduler deployment
/// actually holds the tenancy, which is not always what the workspace directory
/// says and is the truth when the two disagree.
///
/// ⛔ `bookingUrl` IS NULL FOR EVERY STATUS EXCEPT `ready`, AND IT IS DERIVED
/// SERVER-SIDE RATHER THAN BEING A COLUMN. The route builds it from `publicHost`
/// only when the status is `ready`, so a client that rebuilt it from the host
/// itself would publish a booking link for a tenancy that is still provisioning
/// or has failed. Use this key or offer no link.
///
/// ⚠️ `lastReadyAt` IS AN ISO-8601 STRING, NOT AN INSTANT, for the reason every
/// timestamp on this surface is: `NextResponse.json` serialises a `Date` through
/// `JSON.stringify`, and this module owns no date parsing because one decoder
/// strategy would have to be right for every timestamp here and they do not all
/// agree.
public struct SchedulingTenant: Codable, Sendable {
    public let status: SchedulingTenantStatus
    public let publicHost: String
    /// `us`, `ca`, `eu` or `apac`. ⚠️ Kept as a `String`: unlike ``status`` this
    /// one is not CHECK-constrained, and a region this client does not know is a
    /// label to show rather than a response to reject.
    public let region: String
    /// When the tenancy was last observed fully provisioned. ⚠️ Null until the
    /// first success, and NOT cleared by a later failure.
    public let lastReadyAt: String?
    /// ⚠️ OPERATOR-FACING AND SHOWN TO ANY MEMBER OF THE WORKSPACE, deliberately:
    /// somebody who cannot see why provisioning failed has to open a ticket to
    /// learn it. ⛔ It is classified, truncated text and never a raw remote body,
    /// because a raw body from the scheduler can contain the once-only API key.
    public let lastError: String?
    /// Whether the stored tenant API key exists. ⛔ A PRESENCE BOOLEAN, never the
    /// key.
    public let hasCredentials: Bool
    /// ⛔ Present only on `ready`. See the class doc.
    public let bookingUrl: String?
}

/// `GET /api/district/scheduling/status?workspaceId=` — what the Scheduling card
/// renders.
///
/// ⛔ THERE IS NO `success` ENVELOPE ON THIS ROUTE, AND THAT IS NOT AN OVERSIGHT
/// TO PAPER OVER. `NextResponse.json({eligible, canManage, tenant})` is the whole
/// body; there is no flag to check, so a repository must not run this through
/// ``ResponseEnvelope`` and a DTO must not declare a `success` the server never
/// sends (the strict gate would fail on the added key). The three required fields
/// are what reject `{}`.
///
/// ⛔ `tenant == nil` IS THE LEGACY STATE AND IT IS A STATE, NEVER AN ERROR. It
/// means this workspace has no `SchedulingTenant` row — the ordinary condition of
/// every workspace before anyone presses Enable — and rendering it as a failure
/// would tell an operator something is broken when nothing is. It is also not the
/// same question as ``eligible``: a workspace can be admitted and unprovisioned,
/// or provisioned and later removed from the allowlist, so both answers are sent.
///
/// ⚠️ READABLE BY `viewer` TOO. ``canManage`` is the server telling the client
/// which buttons to draw (`agency` or `client`) rather than leaving it to
/// re-derive that from a role string — and, like ``WorkspaceRole``, it is a UX
/// affordance and not the boundary: the enable route enforces the role itself.
public struct SchedulingStatusResponse: Codable, Sendable {
    /// Whether the FEATURE admits this workspace at all, which decides between
    /// "Enable scheduling" and "ask us about scheduling".
    public let eligible: Bool
    /// Whether this member may press Enable. ⛔ Not a security boundary.
    public let canManage: Bool
    /// ⛔ nil is the legacy, never-provisioned state. See the class doc.
    public let tenant: SchedulingTenant?
}

/// `POST /api/district/scheduling/enable` — the answer to pressing Enable.
///
/// ⛔ IT ANSWERS **202**, AND THE 202 IS ABOUT THE STATE IT LEAVES RATHER THAN
/// ABOUT QUEUEING. Provisioning is a multi-system operation that has already run
/// by the time this body is written: the row may be `ready`, or `error` with a
/// reason, and either way the client's next move is to re-read the status.
/// ``ApiClient`` treats every 2xx as success, so nothing special is needed for
/// it — which is worth stating because a client that only accepted 200 would
/// report every successful enable as a failure.
///
/// ⛔ `ok: false` IS A SUCCESSFUL DECODE CARRYING AN ERROR SENTENCE, NOT AN
/// ``ApiError``. The provision refused or failed, the server said so in a
/// well-formed 202, and ``error`` is the operator-facing text (the same string
/// stored in `lastError`). Promoting it to a transport-level failure would throw
/// away the one sentence that says what went wrong. The refusals that ARE
/// ``ApiError``s are the ones that never reached the provisioner: **403** (this
/// workspace is not on the scheduling allowlist) and **429** (five enables in an
/// hour, per workspace).
///
/// ⚠️ NO `success` KEY HERE EITHER — the flag is spelled `ok`. Same rule as the
/// status route: nothing may run this through ``ResponseEnvelope``.
public struct SchedulingEnableResponse: Codable, Sendable {
    public let ok: Bool
    /// ⛔ A `String`, NOT ``SchedulingTenantStatus``, AND THE ASYMMETRY WITH
    /// ``SchedulingTenant/status`` IS DELIBERATE. This key forwards
    /// `ProvisionResult.status`, whose TypeScript type is
    /// `SchedulingTenantStatus | "skipped"` — a wider union than the column's,
    /// because one provisioner type serves both provisioning and deprovisioning.
    /// The enable path cannot reach `"skipped"` today, but a throwing enum here
    /// would turn a future one into a decode failure on a body that is otherwise
    /// perfectly readable, and the sentence in ``error`` is the part that matters.
    /// Branch on `SchedulingTenantStatus(rawValue: status)`; ⚠️ its nil means "not
    /// a tenancy state" (today only `"skipped"`), which is not an error: re-read the
    /// status route, the advice for every outcome of this call anyway.
    public let status: String
    /// The allocated booking host, when there is one. ⚠️ Present on a FAILED
    /// provision too, whenever the host had already been claimed — the host is
    /// allocated once and reused forever, so it survives a failure.
    public let publicHost: String?
    /// ⚠️ Null on success. The provisioner's classified message otherwise; never
    /// a credential and never a raw remote body.
    public let error: String?
}
