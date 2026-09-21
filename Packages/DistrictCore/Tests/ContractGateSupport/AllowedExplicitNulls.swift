import Foundation

/// The one sanctioned escape from the strict gate's no-nulls invariant, in full.
///
/// ⛔ EVERY ENTRY IS AN EXACT PATH, INCLUDING THE ARRAY INDEX, AND THAT IS THE
/// DESIGN RATHER THAN AN ACCIDENT OF NOT HAVING WILDCARDS. `$.recentCalls[*]`
/// would be one line instead of four and would also silence a null on a row
/// nobody looked at — including a row a future regeneration ADDS. An exact path
/// silences one value in one file, and a fixture whose rows shift lands its null
/// on a path that is not listed, which reds the gate rather than passing quietly.
/// The verifier's path matching is plain set membership for the same reason: a
/// pattern language here would be a way to write a wider entry by accident.
///
/// ⛔ AN ENTRY IS A DECISION, NOT A FIX, AND THE ALTERNATIVE THAT ALWAYS LOOKS
/// CHEAPER IS THE ONE THAT MUST NOT BE TAKEN. Loosening the comparison so nulls
/// are tolerated everywhere retires the unknown-key check for every gated fixture
/// at once, because a dropped key and an omitted-nil key become indistinguishable.
///
/// ⚠️ WHAT AN ENTRY BUYS IS EXACTLY TWO EXEMPTIONS AT ONE PATH: the null
/// assertion, and the re-encode key-set comparison (Swift writes a nil Optional
/// as an ABSENT key, so the fixture's key would otherwise read as lost). It buys
/// nothing else. A dropped key whose value is NOT null still fails at that same
/// path, and every sibling key is untouched — both proven in
/// `StrictDecodeVerifierTests`.
///
/// ⚠️ AND AN ENTRY IS PERMISSION, NOT A REQUIREMENT. A listed path holding a real
/// value passes too, because these are NULLABLE COLUMNS: whether row 2 of a
/// regenerated fixture happens to carry a recording URL is not a contract
/// change, and a gate that demanded the null would fail on the good news. The
/// cost of that choice is that an entry can go stale silently when a null
/// disappears; the mitigation is that it cannot go stale DANGEROUSLY, since a
/// null appearing anywhere else is still a hard failure.
///
/// Every group below names the nullable column and why the server sends the key
/// rather than omitting it. Grouped by field, ordered by path.
public extension StrictDecodeVerifier {
    /// Fixture name → the exact JSON paths permitted to hold an explicit `null`.
    ///
    /// The core table. `AllowedExplicitNulls+Union.swift` unions it with the
    /// split-off groups (meetings moved to `AllowedExplicitNulls+Meetings.swift` for
    /// the line ceiling). ⚠️ The
    /// total is asserted by
    /// `ContractManifest.expectedAllowedNullPaths` rather than by this comment,
    /// which is what stops it going stale the way a stated number always does.
    static let base: [String: Set<String>] = [
        // ── The call log, and the two surfaces that re-serve its rows ────────
        //
        // ⛔ ONE MAPPING (`toCallSummaries`) FEEDS ALL THREE FIXTURES, so these
        // three lists describe the same seven nullable columns three times. If a
        // column stops being nulled, all three fail together — which is the
        // signal that the surfaces have NOT drifted.
        //
        //   analysis        `Call.analysis`, a Json? column. Written by the
        //                   post-call pipeline; null on every call that has not
        //                   been analysed, which is most of them.
        //   disposition     `Call.disposition`. Same pipeline, same absence.
        //   followUp        `Call.followUp*`. The route builds this object ONLY
        //                   when a follow-up was actually sent, and sends null
        //                   otherwise rather than omitting the key.
        //   recordingUrl    `Call.recordingUrl`. Only a completed, recorded call
        //                   has one; a missed or busy call never will.
        //   sentiment       `Call.sentiment`. Analysis again.
        //   transferStatus  `Call.transferStatus` / `.transferReason`, the
        //   transferReason  warm-transfer outcome. Null on every call that was
        //                   never transferred — including the answered one, row
        //                   0, which is why these two appear there and the other
        //                   five do not.
        "district-calls.json": [
            "$[1].analysis", "$[2].analysis", "$[3].analysis", "$[4].analysis",
            "$[1].disposition", "$[3].disposition", "$[4].disposition",
            "$[1].followUp", "$[2].followUp", "$[3].followUp", "$[4].followUp",
            "$[1].recordingUrl", "$[2].recordingUrl", "$[3].recordingUrl", "$[4].recordingUrl",
            "$[1].sentiment", "$[3].sentiment", "$[4].sentiment",
            "$[0].transferReason", "$[1].transferReason", "$[3].transferReason", "$[4].transferReason",
            "$[0].transferStatus", "$[1].transferStatus", "$[3].transferStatus", "$[4].transferStatus",
            // `phoneIntel`: the whole block is null on the two outbound rows, which
            // have no recorded callee (describing `from` would describe our own trunk);
            // `lineType`/`carrier` are null wherever no paid carrier lookup is stored.
            "$[2].phoneIntel", "$[3].phoneIntel",
            "$[1].phoneIntel.lineType", "$[4].phoneIntel.lineType",
            "$[1].phoneIntel.carrier", "$[4].phoneIntel.carrier",
        ],
        // The same five rows, nested under `recentCalls`. See the calls note.
        "district-overview.json": [
            "$.recentCalls[1].analysis", "$.recentCalls[2].analysis", "$.recentCalls[3].analysis",
            "$.recentCalls[4].analysis",
            "$.recentCalls[1].disposition", "$.recentCalls[3].disposition", "$.recentCalls[4].disposition",
            "$.recentCalls[1].followUp", "$.recentCalls[2].followUp", "$.recentCalls[3].followUp",
            "$.recentCalls[4].followUp",
            "$.recentCalls[1].recordingUrl", "$.recentCalls[2].recordingUrl", "$.recentCalls[3].recordingUrl",
            "$.recentCalls[4].recordingUrl",
            "$.recentCalls[1].sentiment", "$.recentCalls[3].sentiment", "$.recentCalls[4].sentiment",
            "$.recentCalls[0].transferReason", "$.recentCalls[1].transferReason",
            "$.recentCalls[3].transferReason", "$.recentCalls[4].transferReason",
            "$.recentCalls[0].transferStatus", "$.recentCalls[1].transferStatus",
            "$.recentCalls[3].transferStatus", "$.recentCalls[4].transferStatus",
            "$.recentCalls[2].phoneIntel", "$.recentCalls[3].phoneIntel",
            "$.recentCalls[1].phoneIntel.lineType", "$.recentCalls[4].phoneIntel.lineType",
            "$.recentCalls[1].phoneIntel.carrier", "$.recentCalls[4].phoneIntel.carrier",
        ],
        // The ANSWERED row, singly — so only the transfer pair is null here.
        "district-call-detail.json": [
            "$.call.transferReason",
            "$.call.transferStatus",
        ],

        // ── The CRM ─────────────────────────────────────────────────────────
        //
        // ⛔ BOTH CONTACT ROUTES RETURN THE RAW PRISMA ROW, which is precisely
        // why so many keys arrive as explicit nulls: nothing maps them, so every
        // nullable column is present and null. Row 1 of the list fixture is the
        // deliberately sparse contact — the email-first case that exists to
        // prove a phone-less contact decodes.
        //
        //   dgiError               `Contact.dgiError`. Null on every contact
        //                          whose enrichment has not FAILED, i.e. both
        //                          rows and the detail row.
        //   dgiStatus              Null means "no dossier and none queued",
        //                          which is NOT the same as "pending".
        //   phoneNumber            ⛔ Email-first contacts are supported: the
        //                          column is nullable by design.
        //   socialHandles          Json? columns, unset on a contact nobody has
        //   intelligence           enriched. Carried as `WireJSON`.
        //   visualMemory
        //   company                Firmographics, same story.
        //   latestContextSummary   Written by the voice agent after a call.
        //   budget / timeline      Free-text CRM fields nobody filled in.
        //   website
        //   lastUpdated            Null until the row is first enriched.
        "district-contacts.json": [
            "$.contacts[1].budget",
            "$.contacts[1].company",
            "$.contacts[0].dgiError", "$.contacts[1].dgiError",
            "$.contacts[1].dgiStatus",
            "$.contacts[1].intelligence",
            "$.contacts[1].lastUpdated",
            "$.contacts[1].latestContextSummary",
            "$.contacts[1].phoneNumber",
            "$.contacts[1].socialHandles",
            "$.contacts[1].timeline",
            "$.contacts[1].visualMemory",
            "$.contacts[1].website",
        ],
        // The ENRICHED row, singly: everything populated except the error.
        "district-contact-detail.json": [
            "$.contact.dgiError",
            // No paid carrier lookup is stored on the detail contact.
            "$.phoneIntel.lineType", "$.phoneIntel.carrier",
        ],

        // ── The account's signed-in devices ──────────────────────────────────
        //
        // ⛔ ROW 1 IS THE FRESHLY-SIGNED-IN INSTALL, AND ITS TWO NULLS ARE ONE
        // FACT EACH RATHER THAN A SPARSE ROW. `NativeSession.deviceName` is
        // nullable because the field is OPTIONAL on token exchange, so a client
        // that sent no name has one; `lastUsedAt` is nullable because the server
        // stamps it only when a refresh token ROTATES, so it is null for every
        // session's first ten minutes — i.e. exactly the row a user sees on the
        // screen right after signing in. Both keys are SENT as null rather than
        // omitted, because the route serialises the Prisma selection whole.
        //
        // ⚠️ THE OTHER THREE COLUMNS CANNOT BE NULL AND ARE DELIBERATELY NOT
        // LISTED: `deviceId`, `platform` and `createdAt` are non-null in the
        // schema, so a null on any of them is contract drift and must stay a
        // hard failure.
        "district-devices.json": [
            "$.devices[1].deviceName",
            "$.devices[1].lastUsedAt",
        ],

        // ── The Inbox ───────────────────────────────────────────────────────
        //
        // ⛔ ROW 1 IS THE UNRESOLVED-ADDRESS THREAD, AND ALL FOUR NULLS ARE ONE
        // FACT: the counterpart matched no `Contact`, so there is no id, no
        // name, no email and no phone to report. The server sends the keys with
        // nulls rather than omitting them, and the thread is still perfectly
        // usable — `canSms` is true and `counterpart` is the number. That is why
        // `ConversationSummary.displayName` falls back to the counterpart rather
        // than to a placeholder.
        "district-conversations.json": [
            "$.conversations[1].contactEmail",
            "$.conversations[1].contactId",
            "$.conversations[1].contactName",
            "$.conversations[1].contactPhone",
        ],
        // `MessageDraft.subject` is EMAIL-ONLY. Row 1 is an SMS thread's draft,
        // and the column is nullable rather than absent.
        "district-drafts-list.json": [
            "$.drafts[1].subject",
        ],
        // ⛔ `draft: null` IS THE ORDINARY ANSWER TO A READ, NOT AN ERROR — the
        // server chose null over 404 so the composer's common open path is not
        // logged as a fault. This one entry is the whole fixture.
        "district-draft-null.json": [
            "$.draft",
        ],

        // ── Analytics ───────────────────────────────────────────────────────
        //
        // ⛔ `pct` NULL MEANS "New", NOT ZERO. A workspace with no prior period
        // has no baseline, so the route computes `prior > 0 ? … : null` rather
        // than inventing a divide-by-zero or a fake 0%. Rendering it as "0%"
        // tells a brand-new customer their call volume is flat in their first
        // week. See `CallVolumeDelta.isNew`.
        "district-analytics-new-workspace.json": [
            "$.callVolumeDelta.pct",
        ],

        // ── Metered usage ───────────────────────────────────────────────────
        //
        // ⛔ `usage` NULL MEANS "NOTHING METERED THIS MONTH", NOT "ZERO OF
        // EVERYTHING". `getUsage` returns null the moment its `groupBy` comes back
        // with no rows, and the route forwards it rather than substituting an empty
        // object — so this one path IS the whole fixture. A screen that rendered it
        // as a column of zeros would state a billing fact nobody measured. See
        // ``UsageResponse``.
        // ⚠️ The sibling fixtures need no entry: `district-usage.json` carries every
        // key populated, and `district-usage-history.json`'s sparse months OMIT
        // their unmetered keys rather than nulling them, which is the shape a nil
        // Optional already round-trips.
        "district-usage-empty.json": [
            "$.usage",
        ],

        // ── The knowledge base ──────────────────────────────────────────────
        //
        // ⛔ ONE PATH, AND IT IS THE PASTED DOCUMENT RATHER THAN A SPARSE ROW.
        // `KnowledgeDocument.sourceUrl` is the only nullable column in the family:
        // a document typed into the form has no source URL, one imported from a
        // page does, and the list route serialises its Prisma selection whole, so
        // the key is SENT as null rather than omitted. Row 1 is the imported
        // document and carries a real URL, which is why only row 0 is listed.
        //
        // ⚠️ THE SIBLING CREATE FIXTURE NEEDS NO ENTRY AND MUST NOT BE GIVEN ONE.
        // `POST /workspace/knowledge` selects six fields where `GET` selects seven:
        // `sourceUrl` is ABSENT from the create echo, not null. That is already the
        // shape a nil Optional round-trips, so an entry there would permit a null
        // the server cannot send, and would silence the day it starts to.
        //
        // ⚠️ AND THE OTHER FIVE COLUMNS CANNOT BE NULL, so their absence from this
        // list is load-bearing: `title` is non-null in the schema and
        // `sourceType`, `status`, `chunkCount` and `createdAt` all carry defaults.
        // A null on any of them is contract drift and must stay a hard failure.
        "district-knowledge.json": [
            "$.documents[0].sourceUrl",
        ],

        // ── The automation monitor ──────────────────────────────────────────
        //
        // ⛔ `latestRun` NULL MEANS "HAS NEVER FIRED", WHICH IS THE MOST ORDINARY
        // WORKFLOW THERE IS: one somebody created five minutes ago. The list route
        // sends the key rather than omitting it, deliberately, because a missing key
        // would be indistinguishable from a stale client. Row 0 has a real rollup and
        // row 1 does not, so the fixture carries both branches and a DTO regressed to
        // non-null fails here rather than on a phone.
        "district-workflows.json": [
            "$.workflows[1].latestRun",
        ],
        // ⛔ FOUR PATHS AND THREE DIFFERENT FACTS, WHICH IS WHY THE FIXTURE HOLDS
        // FOUR RUNS.
        //
        //   error       The WHOLE-RUN failure, and it is null on every run that did
        //               not fail as a whole. Rows 0, 1 and 3 are success, partial and
        //               skipped: each has per-action outcomes and no run-level error.
        //               ⛔ It is NOT an action's `reason`, which is a different field
        //               on a different object and is ABSENT rather than null on an
        //               `ok` row.
        //   finishedAt  Null on row 2 only, the run that never finished. ⚠️ A STATE
        //               rather than a missing value, and the same row carries a real
        //               `error` with an EMPTY `actionResults` because the engine threw
        //               before any action ran. A screen that rendered only the
        //               per-action rows would show that as a failure with no
        //               explanation at all.
        //
        // ⚠️ ROW 2 IS DELIBERATELY ABSENT FROM THE `error` LIST and row 2 alone is on
        // the `finishedAt` one. The two lists are near-complements, and that is the
        // shape the four runs exist to keep apart.
        "district-workflow-runs.json": [
            "$.runs[0].error", "$.runs[1].error", "$.runs[3].error",
            "$.runs[2].finishedAt",
        ],
        // ⛔ THE UNCONFIGURED CAMPAIGN, AND BOTH NULLS ARE "NOT CONFIGURED" RATHER
        // THAN A ZERO OR AN EMPTY STRING. The route normalises absent and off into one
        // rendering, so this is the state of every workspace that has never opened the
        // campaigns tab. ⛔ `sdrBatchSize` is null and not 0 because the settings PATCH
        // floors it to at least 1: zero cannot be stored, so a client rendering nil as
        // 0 would state how many people a live outbound campaign calls from a field
        // that said nothing. ⚠️ `sdrCampaignGoal` collapses an empty string to null
        // server-side, so "opened the tab and typed nothing" and "never opened it" are
        // one state on the wire.
        // ⚠️ THE OTHER TWO CAMPAIGN FIXTURES NEED NO ENTRY: both carry all three
        // fields populated, which is what makes this one the interesting member of the
        // set rather than a shorter version of them.
        "district-campaign-status-empty.json": [
            "$.campaign.sdrBatchSize",
            "$.campaign.sdrCampaignGoal",
        ],

        // ── The workspace's carrier accounts ────────────────────────────────
        //
        // ⛔ ONE PATH ACROSS NINE FIXTURES, AND IT IS THE PLATFORM ACCOUNT.
        // `projectManagedSummary` returns null the moment the workspace has no
        // platform-purchased numbers, and the route forwards it rather than
        // substituting an empty object, so this one path IS the whole reason
        // `district-messaging-unmanaged.json` differs from the populated read in
        // more than length. ⛔ `managedAccount: null` is NOT the same fact as
        // `accounts: []`: a workspace can have no accounts of its own and several
        // numbers we bought for it, or the reverse.
        //
        // ⚠️ TWO SIBLING ABSENCES IN THE SAME FILE NEED NO ENTRY AND MUST NOT BE
        // GIVEN ONE. `defaultAccountId` is DROPPED (not nulled) when the account
        // list is empty, because `effectiveDefaultId` returns undefined and
        // `JSON.stringify` omits the key; `ManagedMessagingAccount.provider` is
        // omitted the same way when the stored value is blank. A nil Optional
        // already round-trips an absent key, so an entry for either would permit a
        // null the server does not send and silence the day it starts to.
        //
        // ⚠️ AND THE OTHER EIGHT FIXTURES NEED NOTHING AT ALL. Five are
        // `{success, …ids}` write echoes, the probe's pass carries a two-field
        // `details`, and its rejection carries a sentence. Nothing in the family
        // nulls a field except this.
        "district-messaging-unmanaged.json": [
            "$.managedAccount",
        ],

        // ── Scheduling ──────────────────────────────────────────────────────
        //
        // ⛔ FOUR STATUS FIXTURES BECAUSE THE NULLS MOVE, NOT BECAUSE THE SHAPE
        // DOES. The key set is identical in all four — the route serialises the
        // whole Prisma selection and derives `bookingUrl` with a `?? null` — so
        // what tells the states apart is WHICH columns are empty, and a single
        // fixture would gate the DTO against exactly one of them.
        //
        //   tenant       No `SchedulingTenant` row at all: the LEGACY state, i.e.
        //                every workspace before anyone presses Enable. ⛔ Not an
        //                error and not an empty tenancy — the whole object is
        //                null, and this one path IS the whole fixture.
        //   lastReadyAt  `SchedulingTenant.lastReadyAt`, stamped only when a
        //                provision is observed complete. Null on a tenancy that
        //                has never once been ready, which is the provisioning row.
        //                ⚠️ NOT cleared by a later failure, which is why the error
        //                fixture carries a real timestamp here.
        //   lastError    `SchedulingTenant.lastError`. Null on every tenancy whose
        //                provisioning has not FAILED — so on both the provisioning
        //                and the ready rows, and populated only on the error one.
        //   bookingUrl   Derived server-side as `status === "ready" ? … : null`,
        //                so it is null on every state except ready. ⛔ It is null
        //                on the ERROR row even though that row has a `publicHost`,
        //                which is the case worth gating: a client that rebuilt the
        //                URL from the host would publish a booking link for a
        //                tenancy that cannot serve one.
        "district-scheduling-status-legacy.json": [
            "$.tenant",
        ],
        "district-scheduling-status-provisioning.json": [
            "$.tenant.bookingUrl",
            "$.tenant.lastError",
            "$.tenant.lastReadyAt",
        ],
        "district-scheduling-status-ready.json": [
            "$.tenant.lastError",
        ],
        "district-scheduling-status-error.json": [
            "$.tenant.bookingUrl",
        ],
        // ⛔ `error` NULL IS THE SUCCESSFUL PROVISION, and the key is SENT rather
        // than omitted: the route writes `result.ok ? null : (result.message ??
        // null)`, so both branches always produce the key. ⚠️ `publicHost` needs
        // no entry here and would be a mistake to add — the host is allocated
        // before the platform call and reused forever, so the ready body carries a
        // real one, and permission for a null there would silence the one case
        // that means the allocation itself failed.
        "district-scheduling-enable.json": [
            "$.error",
        ],

        // ── Workspaces ──────────────────────────────────────────────────────
        //
        // `Workspace.subscriptionTier` is null until a plan is set. ⚠️ The
        // non-null values are MIXED CASE (`VoicePro`), which is the trap this
        // field is better known for — see `WorkspaceEntry.subscriptionTier`.
        // ⚠️ The two fixtures null DIFFERENT ROWS because the partial one is
        // missing the degraded region's workspace, so the indices are not
        // interchangeable.
        "district-workspace-list.json": [
            "$.workspaces[2].subscriptionTier",
        ],
        "district-workspace-list-partial.json": [
            "$.workspaces[1].subscriptionTier",
        ],
        // A routing rule's `target` is null for an action that has nowhere to
        // send — row 1 answers from the knowledge base rather than transferring.
        // ⚠️ INSIDE AN OPAQUE `WireJSON` BLOB, so this entry exempts the null
        // ASSERTION only: the carrier re-encodes the null as a null, and the key
        // is never lost. Both halves are exercised by this one fixture.
        "district-workspace-config.json": [
            "$.config.routingRules[1].target",
        ],
        // ⛔ THE KEY SET IS IDENTICAL WHETHER THE WORKSPACE IS CONFIGURED OR
        // BRAND NEW: the route NULLS a missing optional rather than dropping the
        // key. That is what makes this fixture the sparse twin of the one above
        // rather than a shorter version of it — seven columns nobody has set.
        "district-workspace-config-sparse.json": [
            "$.config.aiPersona",
            "$.config.campaignSettings",
            "$.config.creatorCellNumber",
            "$.config.messagingConfig",
            "$.config.plan",
            "$.config.subscriptionTier",
            "$.config.toolConfig",
        ],

        // ── Billing ─────────────────────────────────────────────────────────
        //
        // ⛔ THE TWO DEGRADED BODIES HOLD THE SAME THREE PATHS AND THAT IS THE
        // WHOLE MECHANISM RATHER THAN A COPY-PASTE. `GET /api/billing` has three
        // shapes: a healthy one, a Stripe outage (`billingUnavailable: true`),
        // and an account with no Stripe customer — and the last two are
        // byte-identical apart from that one key, which is ABSENT on the third
        // rather than false. So the same three nulls have to be permitted twice,
        // once per fixture, and collapsing the pair would delete the only thing
        // that distinguishes "we could not look" from "there is nothing". That
        // conflation sends a paying customer to a checkout page; here it would be
        // doing it about their PLAN.
        //
        //   paymentMethod   Stripe's default card, or null when there is no
        //                   customer to have one. The key is SENT on all three
        //                   bodies, which is why absent and null stay different.
        //   billingAddress  The customer's `address`, same story.
        //   customerId      `cus_…`, or null. ⛔ On the degraded pair this is the
        //                   discriminator for "no Stripe linkage" and it is only
        //                   readable ALONGSIDE `billingUnavailable`'s absence.
        "district-billing-no-customer.json": [
            "$.billingAddress",
            "$.customerId",
            "$.paymentMethod",
        ],
        "district-billing-unavailable.json": [
            "$.billingAddress",
            "$.customerId",
            "$.paymentMethod",
        ],
        // ⛔ TWO PATHS ON THE HEALTHY BODY, BOTH ON THE UNPAID INVOICE, AND IT IS
        // THE MOST ORDINARY ROW THERE IS. Stripe omits `hosted_invoice_url` and
        // `invoice_pdf` until an invoice is FINALISED, so this month's invoice
        // before it is paid carries both as nulls — a client that typed them
        // non-null would throw on the row every customer sees every month. ⚠️ Row
        // 0, the paid one, carries real strings for both, which is what makes
        // one fixture cover the branch in each direction. ⛔ And neither may be
        // OPENED from this client: they are modelled to satisfy the key-set walk,
        // not to be surfaced (App Store Review Guideline 3.1.3(b)).
        "district-billing.json": [
            "$.invoices[1].hosted_invoice_url",
            "$.invoices[1].invoice_pdf",
        ],
        // ⛔ TWO PATHS, ONE STATE, AND NEITHER NULL MAY BE READ AS A VALUE. This
        // is `workspace/billing` for a workspace that hit a hard cap and stopped
        // paying, which is exactly the workspace with no metered rows this month
        // — the two co-occur, which is why one fixture carries both.
        //
        //   subscriptionTier  `Workspace.subscriptionTier`, passed through
        //                     untouched. ⛔ NULL IS NOT "Free": `GET
        //                     /api/settings` substitutes that word and this route
        //                     deliberately does not, so inventing it here would
        //                     put a plan name on screen that no row contains.
        //   usage             `getUsage` returns null the moment its groupBy
        //                     comes back empty. ⛔ NOT ZERO. A column of zeros
        //                     under a billing label asserts that nothing was
        //                     used, beside a cap that says calls are being
        //                     refused; the two statements contradict each other
        //                     and only one of them was measured.
        //
        // ⚠️ The sibling `district-workspace-billing.json` needs no entry at all —
        // same six keys, every one populated — which is what makes the pair a
        // test of the Optionals rather than of the decoder.
        "district-workspace-billing-null-usage.json": [
            "$.billing.subscriptionTier",
            "$.billing.usage",
        ],
    ]
}
