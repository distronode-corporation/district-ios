import Foundation

/// The most recent execution of one workflow, as the LIST route rolls it up.
///
/// ⛔ NOT A ``WorkflowRun``, AND THE TWO MUST NOT BE MERGED. The list route selects
/// three columns off `WorkflowRun` and publishes two of them; the runs route
/// publishes eight fields including the per-action outcomes. A client that modelled
/// this as a run would be asserting `actionResults` on a payload that has never
/// carried it, and the strict gate would fail on the added key rather than on the
/// mistake, which is the confusing way round.
///
/// ⚠️ ``status`` IS FREE TEXT ON THE WIRE. `WorkflowRun.status` is a plain String
/// column with no Prisma enum behind it, so the four values the engine writes today
/// are a convention rather than a guarantee. Kept a `String` for the reason
/// ``WorkspaceRole`` is parsed rather than decoded: a throwing enum here would take
/// out the whole list one unmodelled row arrived in. ⛔ The opposite call is right
/// for ``SchedulingTenantStatus``, whose column is CHECK-constrained in SQL.
public struct WorkflowLatestRun: Codable, Sendable {
    /// ⚠️ `success`, `partial`, `failed` or `skipped` today. Displayed, not
    /// switched on exhaustively.
    public let status: String
    /// ⚠️ An ISO-8601 STRING. This module owns no date parsing.
    public let startedAt: String
}

/// One row of `GET /api/district/workflows`.
///
/// ⛔ ``latestRun`` IS AN EXPLICIT NULL FOR A WORKFLOW THAT HAS NEVER RUN, and the
/// route sends the key rather than omitting it, deliberately: a missing key is
/// indistinguishable from a stale client. Both branches are in the fixture, because
/// a DTO regressed to non-null would throw on the most ordinary row there is, a
/// workflow somebody created five minutes ago.
///
/// ⛔ THE LIST IS A PROJECTION, NOT THE ROW. `actions`, `triggerMetadata`,
/// `workspaceId` and `updatedAt` are all on the Prisma row and none is published. A
/// client modelling this from the table would decode nothing, and one EXPECTING
/// those fields would fail on every response.
///
/// ⚠️ ``trigger`` IS FREE TEXT AND MUST NOT BE EXHAUSTED OVER. The column is a bare
/// String validated against a server-side list of ten values on write, and that
/// list grows: an already-installed build has to keep rendering a workflow whose
/// trigger it has never heard of, falling back to the raw string.
public struct WorkflowListItem: Codable, Sendable {
    public let id: String
    public let name: String
    /// ⚠️ What the screen's switch shows. Both branches are in the fixture so it
    /// cannot be pinned to a constant.
    public let active: Bool
    /// ⚠️ Free text. See the ⚠️ on the type.
    public let trigger: String
    public let createdAt: String
    /// ⛔ nil means NEVER RUN, which is a state and not a failure.
    public let latestRun: WorkflowLatestRun?
}

/// `GET /api/district/workflows`.
///
/// ⛔ AN EMPTY LIST IS A LEGITIMATE ANSWER AND MUST NOT RENDER AS A FAILURE. Most
/// workspaces have never created a workflow. ⚠️ But the envelope is still checked at
/// the repository, because a `{}` body would otherwise decode as "this workspace has
/// no workflows", which on the automation monitor reads as "your automation was
/// deleted".
///
/// ⚠️ ADMITS `viewer`, unlike the PATCH on the same path, and that split is what
/// makes the screen reachable by every role with only its switch gated. Ordered
/// newest first.
public struct WorkflowListResponse: Codable, Sendable {
    public let success: Bool
    public let workflows: [WorkflowListItem]
}

/// What one action inside a run did.
///
/// ⛔ ``reason`` IS PRESENT ONLY ON SOME OUTCOMES AND IS THE MOST USEFUL FIELD ON
/// THE ROW. The engine attaches it when an action was SKIPPED (no contact, no phone
/// number, missing metadata), i.e. exactly the case where the outcome word alone
/// tells an operator nothing they can act on. It is ABSENT on the ordinary `ok`
/// row, so a non-Optional here would throw on the commonest shape there is.
///
/// ⚠️ ``outcome`` IS FREE TEXT for the reason ``WorkflowLatestRun/status`` is: this
/// object is written by the engine into a `Json` column, so nothing type-checks the
/// vocabulary across the boundary. `ok`, `skipped` and `failed` are what it writes
/// today.
public struct WorkflowActionResult: Codable, Sendable {
    public let type: String
    /// ⚠️ Free text. See the ⚠️ on the type.
    public let outcome: String
    /// ⛔ Absent on an `ok` row. See the ⛔ on the type.
    public let reason: String?
}

/// One execution of one workflow.
///
/// ⛔ ``error`` IS THE WHOLE-RUN FAILURE AND IS NOT AN ACTION'S ``WorkflowActionResult/reason``.
/// A run can be `failed` with every action reporting its own outcome, and it can be
/// `failed` with an EMPTY ``actionResults`` because the engine threw before any
/// action ran. A screen that showed only the per-action rows would render the second
/// case as a failure with no explanation whatsoever, which is why the fixture carries
/// exactly that row.
///
/// ⚠️ ``finishedAt`` IS NULL FOR A RUN THAT DID NOT FINISH. That is a STATE rather
/// than a missing value, and it travels as an explicit null.
///
/// ⚠️ ``actionResults`` IS NON-OPTIONAL BECAUSE THE ROUTE GUARANTEES AN ARRAY: the
/// column is `Json`, so the read is wrapped in an `Array.isArray(...) ? ... : []`
/// and a non-array in the database becomes an empty list rather than a decode
/// failure on a phone.
public struct WorkflowRun: Codable, Sendable {
    public let id: String
    public let workflowId: String
    public let trigger: String
    /// ⚠️ Free text: `success`, `partial`, `failed` or `skipped` today. ⛔ `partial`
    /// is the one that draws like a healthy run if it is toned wrong, and it means
    /// some actions ran and some did not.
    public let status: String
    public let startedAt: String
    /// ⚠️ nil means the run did not finish. A state, not an absence.
    public let finishedAt: String?
    /// ⚠️ Empty is meaningful: the engine threw before any action ran. Read
    /// ``error`` in that case.
    public let actionResults: [WorkflowActionResult]
    /// ⛔ The whole-run failure. See the ⛔ on the type.
    public let error: String?
}

/// `GET /api/district/workflows/runs`.
///
/// ⛔ ``hasMore`` IS THE SERVER'S AND IS COMPUTED FROM A REAL ``total``, SO
/// END-OF-LIST IS KNOWN RATHER THAN INFERRED. ⛔ Do not re-derive it as
/// `runs.count < limit`: a run written between two requests makes those two answers
/// disagree, and the client's version ends the list early, silently hiding history
/// that exists.
///
/// ⛔ ``limit`` AND ``offset`` ARE ECHOED AS THE SERVER APPLIED THEM, WHICH IS NOT
/// THE SAME QUESTION AS WHAT WAS ASKED FOR. The route clamps `limit` to 1...50
/// (defaulting to 10) and REPLACES a non-numeric value rather than clamping it,
/// because a NaN `take` makes Prisma throw. So a caller must page from this echo,
/// not from the number it sent.
///
/// ⚠️ Ordered newest first, and `viewer` is admitted: read-only history.
public struct WorkflowRunsResponse: Codable, Sendable {
    public let success: Bool
    public let runs: [WorkflowRun]
    /// ⚠️ The real total, which is what makes ``hasMore`` trustworthy.
    public let total: Int
    /// ⛔ As APPLIED, not as requested. See the ⛔ on the type.
    public let limit: Int
    public let offset: Int
    public let hasMore: Bool
}

/// The three always-on-SDR fields.
///
/// ⛔ ALL THREE ARE NORMALISED SERVER-SIDE AND THE NULLS ARE LOAD-BEARING.
/// `campaignSettings` is a nullable `Json` column whose keys are all optional, so
/// the route collapses "absent" and "off" into ONE rendering. That is what stops
/// "we have no campaign" and "the campaign is off" being two different screens for
/// the same state, and it is why `district-campaign-status-empty.json` is a STATE
/// rather than an error or an empty response.
///
/// ⛔ ``sdrBatchSize`` IS NULL RATHER THAN 0, DELIBERATELY. The settings PATCH
/// floors it to at least 1, so 0 is a value that cannot be stored and would only
/// ever mean "we invented one". A client that rendered nil as 0 would be stating
/// how many people a live outbound campaign calls, from a field that said nothing.
///
/// ⛔ AND AN EMPTY ``sdrCampaignGoal`` COLLAPSES TO NULL. The settings PATCH writes
/// `goal || ""`, so a workspace that opened the tab and typed nothing stores `""`
/// while one that never opened it has no key at all. Those are the same state to a
/// reader, and only one of them reaches the wire.
///
/// ⚠️ ``sdrBatchSize`` IS AN `Int` OVER AN UNTYPED JSON COLUMN. The only writer
/// floors it, so every stored value is whole; a fractional one is a decode failure
/// rather than a rounded display, which is the right way round for a figure that
/// decides how many people get called.
public struct CampaignStatus: Codable, Sendable {
    /// Whether the always-on SDR engine is running.
    public let infiniteSdrEnabled: Bool
    /// ⛔ nil means "not configured", never zero. See the ⛔ on the type.
    public let sdrBatchSize: Int?
    /// ⛔ nil means "not configured", and empty collapses to nil server-side.
    public let sdrCampaignGoal: String?
}

/// `GET` **and** `PATCH /api/district/workspace/campaign-status`.
///
/// ⛔ ONE TYPE FOR BOTH VERBS, BECAUSE THE ROUTE DELIBERATELY ANSWERS THE READ'S
/// SHAPE FROM THE WRITE. The PATCH derives its reply from the object it merged
/// rather than re-reading it, so a client can render the result of a pause without a
/// second round trip that would race its own write. A second DTO would let the read
/// and the write drift into disagreeing about what a null batch size means.
///
/// ⛔ THIS IS NOT `workspace/campaign-settings`. That route rebuilds all three SDR
/// fields from its request body, so the same `{infiniteSdrEnabled:false}` sent there
/// WIPES the goal text and resets the batch size to 1, with a 200. This one spreads
/// the stored Json and assigns one key.
///
/// ⚠️ THE TWO VERBS DIFFER ON ROLE: the GET admits `viewer` and the PATCH does not.
/// It is the only verb split in this API, and it is what lets the route admit the
/// lowest-trust role at all.
///
/// ⚠️ ``campaign`` IS OPTIONAL ONLY TO SURVIVE A `{}` BODY. Both verbs always send
/// it on a 200, so nil is contract drift rather than a state, and
/// ``WorkflowsRepository`` reports it as such instead of rendering an unconfigured
/// campaign from nothing.
public struct CampaignStatusResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ nil is DRIFT, not "no campaign". See the ⚠️ on the type.
    public let campaign: CampaignStatus?
}

// ⛔ THERE IS NO `WorkflowToggleResponse` HERE. `PATCH /api/district/workflows`
// answers exactly `{"success": true}` and echoes nothing about the row it wrote,
// which is what ``SuccessResponse`` already is, so `district-workflow-toggle.json`
// is gated against that type in `ImplementedFixtures` alongside the
// workspace-settings patches, the messaging `meta` action and the bare
// acknowledgements. See the ⛔ at the foot of `WorkspaceConfigResponses.swift` for
// why sharing is sound: the gate pins each fixture separately.
//
// ⛔ THE CONSEQUENCE IS THE INTERESTING PART, AND IT IS A UI ONE. There is nothing
// in that reply to adopt, so a toggle is optimistic-with-revert rather than
// adopt-the-response, and a caller that needs fresh state has to re-read the list.
// ⚠️ Contrast the campaign pause immediately above, which answers the READ's whole
// shape: same screen, two writes, two different correct designs, and the reason is
// entirely what each response carries.
