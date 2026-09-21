import ContractGateSupport
import DistrictModel
import Foundation

/// One fixture and the DTO the strict gate runs it through.
struct ImplementedFixture {
    let name: String
    let type: String
    let run: () throws -> Void
}

/// The fixtures that have a Swift DTO, and what decodes each one.
///
/// ⛔ THE PAIRING IS THE ASSERTION. Naming a fixture here is a claim that the
/// listed type models it exactly — no dropped keys, no invented ones — and
/// `StrictDecodeVerifier` is what proves the claim on every run. Moving a name
/// out of `ContractManifest.unimplemented` without adding it here fails the
/// suite, because every fixture on disk has to be in exactly one of the two
/// lists.
///
/// ⚠️ MANY OF THESE CARRY EXPLICIT NULLS AND ARE GATED ANYWAY. The gate's
/// no-nulls invariant is what makes the key-set comparison sound,
/// and it has exactly one sanctioned escape:
/// `StrictDecodeVerifier.allowedExplicitNulls`, whose size is asserted by
/// `ContractManifest.expectedAllowedNullPaths` rather than written here, because
/// a stated count goes stale. A blanket "no fixture with a null" rule would
/// hold out whole surfaces — overview, the calls feed and detail, contacts,
/// conversations, the workspace list and the workspace config — over fields
/// whose nullability is not in doubt.
///
/// ⛔ WHAT HAS NOT CHANGED IS THAT AN ENTRY IS PER PATH. There is no wildcard and
/// no per-fixture waiver, so a null anywhere the list does not name is still a
/// hard failure — including on a row a regeneration adds.
enum ImplementedFixtures {
    static var all: [ImplementedFixture] {
        authAndSessions + push + membership + meetings + overview
            + callsAndAnalytics + meteredUsage + inbox + messageThread + contacts + workspaceConfig + contactWrites
            + persona + scheduling + schedulingAdmin + knowledge + messaging + districtHQ + automation + deskAndSupport
            + billing + numbers + meetingRecords + schedulingA + schedulingB + schedulingC + setup
    }

    static var names: Set<String> {
        Set(all.map(\.name))
    }

    // MARK: - Auth and native sessions

    private static var authAndSessions: [ImplementedFixture] {
        [
            gate("district-native-revoke.json", SuccessResponse.self),
            gate("district-revoke-all.json", DeviceRevokeResponse.self),
            gate("district-device-revoke.json", DeviceRevokeResponse.self),
            // ⛔ THE READ THAT MAKES THE TWO REVOKES ABOVE USABLE, AND IT ARRIVED
            // LAST. Its two rows are the whole point: row 0 is a fully populated
            // device, row 1 nulls `deviceName` and `lastUsedAt` together — the
            // "signed in, never yet refreshed, sent no name" shape that every
            // session passes through for its first ten minutes. Both nulls have
            // exact `allowedExplicitNulls` paths; a DTO that regressed either
            // Optional to non-null fails here rather than on a phone.
            gate("district-devices.json", DevicesResponse.self),
            // ⛔ THE THREE ANSWERS TO ONE QUESTION, AND THEY MUST NOT SHARE A
            // TYPE. The 200 and the PARTIAL 200 are the same shape (the second
            // just carries a non-empty `degradedRegions`); the 503 is a
            // different body entirely, because "we could not look" and "there is
            // nothing" read to a paying customer as account loss when confused.
            gate("district-workspace-list.json", WorkspaceListResponse.self),
            gate("district-workspace-list-partial.json", WorkspaceListResponse.self),
            gate("district-workspace-list-degraded.json", WorkspaceListDegradedError.self),
        ]
    }

    // MARK: - Push registration

    /// ⛔ A DIFFERENT `devices` SURFACE FROM THE ONE ABOVE, AND THE TWO 404 EACH
    /// OTHER. `district-devices.json` describes `/api/auth/native/devices` —
    /// SESSION management on a public proxy prefix. These two describe
    /// `/api/district/devices/{register, unregister}` — PUSH registration behind
    /// the default-deny middleware. The names are one word apart, and a client
    /// that crossed them reads as broken rather than as misrouted, which is why
    /// they are gated in their own section rather than beside the device list.
    ///
    /// ⚠️ BOTH ARE `{"success": true}` AND BOTH ARE GATED AGAINST THE SHARED
    /// ``SuccessResponse``, not against two bespoke structs. See the ⛔ at the
    /// foot of `DeviceResponses.swift`: the sharing is sound because each fixture
    /// is pinned SEPARATELY here, so the day either route grows a field, that one
    /// fails on its own.
    private static var push: [ImplementedFixture] {
        [
            gate("district-device-register.json", SuccessResponse.self),
            gate("district-device-unregister.json", SuccessResponse.self),
        ]
    }

    // MARK: - Workspace membership

    private static var membership: [ImplementedFixture] {
        [
            gate("district-members.json", MemberListResponse.self),
            // POST, PATCH and DELETE through one type. The DELETE fixture is the
            // one that proves `member` has to be Optional.
            gate("district-member-add.json", MemberMutationResponse.self),
            gate("district-member-role-patch.json", MemberMutationResponse.self),
            gate("district-member-remove.json", MemberMutationResponse.self),
            gate("district-member-duplicate.json", ApiErrorEnvelope.self),
            gate("district-member-last-agency.json", ApiErrorEnvelope.self),
            gate("district-rename.json", RenameResponse.self),
        ]
    }

    // MARK: - Rooms and other bare acknowledgements

    private static var meetings: [ImplementedFixture] {
        [
            // Both branches of the viewer split. See RoomTokenResponse: the
            // guest keys are ABSENT for a viewer, not null, and that is a
            // security decision rather than a shape quirk.
            gate("district-room-token.json", RoomTokenResponse.self),
            gate("district-room-token-viewer.json", RoomTokenResponse.self),
            gate("district-clear-intel.json", SuccessResponse.self),
            gate("district-knowledge-delete.json", SuccessResponse.self),
            gate("district-messages-unread-count.json", UnreadCountResponse.self),
        ]
    }

    // MARK: - Calls, the softphone and analytics

    // MARK: - The dashboard's own surface

    private static var overview: [ImplementedFixture] {
        [
            // ⚠️ `recentCalls` IS THE SAME `CallSummary` THE FEED RETURNS, from
            // one server-side mapping, so this fixture and `district-calls.json`
            // gate the same type through two different envelopes. A drift in one
            // reds both, which is the point.
            gate("district-overview.json", OverviewResponse.self),
        ]
    }

    private static var callsAndAnalytics: [ImplementedFixture] {
        [
            // ⛔ A BARE ARRAY, NOT AN ENVELOPE. `GET /api/district/calls` is one
            // of the three routes that answer with a top-level array; gating it
            // as `[CallSummary]` is what keeps that in the type system rather
            // than in a comment nobody reads.
            gate("district-calls.json", [CallSummary].self),
            gate("district-call-detail.json", CallDetailResponse.self),
            gate("district-call-transcript.json", CallTranscriptResponse.self),
            gate("district-dial.json", DialResponse.self),
            // ⛔ THE THREE REFUSALS OF THE SAME BILLABLE ROUTE, AND THEY NEED TWO
            // TYPES. The DNC 403 and the dormancy 403 are the route's own
            // `{success,error[,code]}`; the 402 is the shared subscription
            // guard's, and it carries a fourth key (`status`) that
            // `ApiErrorEnvelope` deliberately does not model — the strict gate
            // would drop it on re-encode.
            gate("district-dial-dnc.json", ApiErrorEnvelope.self),
            // ⚠️ SAME TYPE AS THE DNC REFUSAL, OPPOSITE PRODUCT ANSWER. This one
            // carries `workspace_dormant`, so it is the branch that sends the
            // operator to the dashboard's reactivation route instead of showing
            // a refusal they can do nothing about. See ``ApiErrorCode``.
            gate("district-dial-dormant.json", ApiErrorEnvelope.self),
            gate("district-dial-subscription.json", SubscriptionInactiveError.self),
            // ⛔ THE INBOUND HALF, AND IT IS A DIFFERENT TYPE FROM THE DIAL ON
            // PURPOSE. Four keys each, three of them shared, and the fourth is
            // where they part: the dial answers `callId` (the row it just wrote)
            // and the answer does not (the client sent it in the path). One DTO
            // for both would have to make that key Optional and every dial-side
            // reader would lose a guarantee. See `CallAnswerResponse`.
            gate("district-call-answer.json", CallAnswerResponse.self),
            gate("district-analytics.json", AnalyticsResponse.self),
            // The same type against a workspace with no history: every metric
            // zero and `callVolumeDelta.pct` an explicit null, which is the
            // "no baseline to compare against" branch rather than a zero delta.
            gate("district-analytics-new-workspace.json", AnalyticsResponse.self),
        ]
    }

    // MARK: - Metered usage

    /// ⛔ ONE ROUTE, TWO RESPONSE TYPES, AND THE PAIRING BELOW IS THE ASSERTION.
    /// `workspace/usage` answers an OBJECT for the current month and an ARRAY when
    /// `history=true`, so gating both against one type would either fail or, worse,
    /// pass against a DTO loose enough to accept either — which is exactly the
    /// confusion that reads a single month as an empty history.
    private static var meteredUsage: [ImplementedFixture] {
        [
            // The populated month: every metric present, `provider` and
            // `lastUpdated` with it, and the fractional call minutes that make
            // these `Double` rather than `Int`.
            gate("district-usage.json", UsageResponse.self),
            // ⛔ `usage: null` IS THE ORDINARY ANSWER FOR A MONTH WITH NO METERING
            // ROWS, not an error and not a zeroed object. This fixture is that one
            // null and nothing else, which is why its allowlist entry is a single
            // path. See `UsageResponse`.
            gate("district-usage-empty.json", UsageResponse.self),
            // ⚠️ THE SPARSE ROWS ARE THE POINT OF THIS ONE. Its second and third
            // months OMIT the metrics nobody metered rather than nulling them, so
            // it is the fixture that proves absent and zero stay distinguishable —
            // and, because Swift writes a nil Optional as an absent key, that the
            // round trip does not invent the keys back.
            gate("district-usage-history.json", UsageHistoryResponse.self),
        ]
    }

    // MARK: - Inbox composer: drafts, sends and attachments

    private static var inbox: [ImplementedFixture] {
        [
            // ⛔ `draft` IS AN OBJECT ON THESE TWO AND A BARE STRING ON THE
            // THIRD. `messages/drafts` (plural) persists; `messages/draft`
            // (singular) is a billed Vertex generation. Gated side by side so
            // the one-character difference is visible rather than inferred.
            gate("district-draft.json", DraftResponse.self),
            gate("district-draft-put.json", DraftResponse.self),
            gate("district-ai-draft.json", AiDraftResponse.self),
            gate("district-draft-delete.json", SuccessResponse.self),
            // All three send branches through one type. The email fixture is the
            // one that proves `subject` has to be Optional, and the two SMS ones
            // prove the same of `externalId` and `accountId`.
            gate("district-message-send.json", SendMessageResponse.self),
            gate("district-message-send-email.json", SendMessageResponse.self),
            gate("district-message-send-media.json", SendMessageResponse.self),
            gate("district-message-mark-read.json", MarkReadResponse.self),
            gate("district-media-upload.json", MediaUploadResponse.self),
            // The persisted-drafts list, whose second row carries `subject: null`
            // (an SMS draft has no subject), and the thread with no draft at all.
            // ⛔ `draft: null` MUST NOT RENDER AS A FAILURE: it is the empty
            // composer, not an error, and the two are one Optional apart.
            gate("district-drafts-list.json", MessageDraftsResponse.self),
            gate("district-draft-null.json", DraftResponse.self),
            // The thread list. Its unresolved-address row nulls all four contact
            // fields — a conversation with someone who is not a contact yet.
            gate("district-conversations.json", ConversationsResponse.self),
            // The timeline page, including its `pageInfo` block.
            //
            // ⚠️ NEITHER FIXTURE CARRIES A SINGLE NULL, WHICH IS WHY NEITHER
            // NEEDS AN `allowedExplicitNulls` ENTRY — and that is worth stating,
            // because `TimelinePageInfo`'s two cursor fields ARE nullable and the
            // natural assumption is that a paging block must be the place a null
            // shows up. It is not: they are null together only on an EMPTY page,
            // and no empty-page fixture exists. The Optionals on `TimelineEvent`
            // are absences, not nulls — `duration`/`summary`/`hasTranscript` on a
            // message row, `subject` off an email, `mediaUrls` with no
            // attachments.
            //
            // ⛔ TWO FIXTURES, NOT ONE, AND THE SECOND IS NOT REDUNDANT: the
            // first page pins the field UNION (a missed call, an answered call
            // with a summary and a transcript flag, an outbound SMS, an MMS with
            // `mediaUrls`, an email with `subject`), while the page fixture is
            // the only one where `hasMore` is TRUE — i.e. the only proof the
            // "there is an older window" branch decodes at all.
            gate("district-timeline.json", TimelineResponse.self),
            gate("district-timeline-page.json", TimelineResponse.self),
        ]
    }

    // MARK: - Contacts and the workspace call directory

    private static var contacts: [ImplementedFixture] {
        [
            gate("district-enrich.json", EnrichResponse.self),
            // The opt-out refusal is a route's own envelope with no code to
            // branch on, so the sentence is the whole product here.
            gate("district-enrich-disabled.json", ApiErrorEnvelope.self),
            gate("district-directory-patch.json", SuccessResponse.self),
            // The paged feed and one row in full. Thirteen nulls between them are
            // unenriched columns, not absent data — see AllowedExplicitNulls.
            gate("district-contacts.json", ContactListResponse.self),
            gate("district-contact-detail.json", ContactDetailResponse.self),
        ]
    }

    // MARK: - The workspace list and its configuration

    private static var workspaceConfig: [ImplementedFixture] {
        [
            // ⚠️ The two list fixtures are gated with the rest of the workspace
            // surface above, not here — one fixture, one gate, or the counted
            // burn-down starts double-counting itself.
            //
            // The full config and the freshly-created one. `-sparse` is where
            // every optional persona/tool field is null at once, so it is the
            // fixture that actually exercises the Optionals.
            gate("district-workspace-config.json", WorkspaceConfigResponse.self),
            gate("district-workspace-config-sparse.json", WorkspaceConfigResponse.self),
            // ⛔ THE THREE SAVES THIS CLIENT CAN NOW MAKE, AND ALL THREE ARE THE
            // SAME BARE `{success:true}`. Gated side by side precisely so the
            // sameness is visible: nothing on the wire tells a persona MERGE apart
            // from a wholesale routing-rules REPLACEMENT, so the whole difference
            // has to be carried by the descriptors and the repository instead.
            // ⚠️ The fourth sibling, `district-directory-patch.json`, is gated with
            // the contacts group above rather than here (it is the workspace CALL
            // directory, i.e. staff phone numbers). One fixture, one gate: listing it twice would make the counted
            // burn-down start double-counting itself.
            //
            // ⛔ THE ABSENCE OF A `config` KEY IS WHAT THESE ACTUALLY PIN. The
            // strict gate's re-encode walk fails on an ADDED key as loudly as on a
            // dropped one, so the day any of these routes starts echoing the row it
            // wrote, that one fixture reds and the extra re-read the caller has to
            // perform can be dropped. Nothing else watches for it.
            gate("district-persona-patch.json", SuccessResponse.self),
            gate("district-tools-patch.json", SuccessResponse.self),
            gate("district-routing-patch.json", SuccessResponse.self),
        ]
    }

    // MARK: - Scheduling

    /// ⛔ FOUR FIXTURES FOR ONE ROUTE, AND NOT ONE OF THEM IS REDUNDANT. All four
    /// have the SAME key set — the status route serialises the whole selection and
    /// derives `bookingUrl` with a `?? null`, so nothing is ever omitted — which
    /// means the key-set walk alone cannot tell them apart, and a single fixture
    /// would pin the DTO against exactly one state's nulls. What differs is which
    /// columns are empty:
    ///
    ///   legacy        `tenant: null`, the whole object. The state every workspace
    ///                 is in before anyone presses Enable, and the one that must
    ///                 never render as a failure.
    ///   provisioning  A row with no `lastReadyAt`, no `lastError` and no
    ///                 `bookingUrl`, and `hasCredentials: false` — the tenancy
    ///                 exists and the platform call has not stored a key yet.
    ///   ready         Everything populated, `bookingUrl` present. The only state
    ///                 that carries a link.
    ///   error         ⛔ THE MOST INFORMATIVE ONE. `lastReadyAt` AND `publicHost`
    ///                 AND `hasCredentials` are all populated while `bookingUrl` is
    ///                 null — a tenancy that WAS ready, still owns its host and its
    ///                 credential, and cannot serve bookings right now. A DTO that
    ///                 rebuilt the URL from the host would publish a dead link, and
    ///                 this is the fixture that would catch it.
    ///
    /// ⚠️ THE ENABLE FIXTURE IS THE `ok: true` BRANCH ONLY. The corpus carries no
    /// `ok: false` body, so that branch is decoded from literal bytes in
    /// `SchedulingContractTests` — the same treatment `UsageHistoryResponse`'s
    /// empty array gets, and for the same reason.
    private static var scheduling: [ImplementedFixture] {
        [
            gate("district-scheduling-status-legacy.json", SchedulingStatusResponse.self),
            gate("district-scheduling-status-provisioning.json", SchedulingStatusResponse.self),
            gate("district-scheduling-status-ready.json", SchedulingStatusResponse.self),
            gate("district-scheduling-status-error.json", SchedulingStatusResponse.self),
            gate("district-scheduling-enable.json", SchedulingEnableResponse.self),
        ]
    }

    // MARK: - The knowledge base

    /// ⛔ FOUR FIXTURES, THREE TYPES, AND THE ONE THAT IS SHARED IS SHARED ACROSS
    /// A READ AND A WRITE. `knowledge-mode` GET and PATCH answer the identical
    /// body, because the PATCH re-reads through the server's own sanitiser before
    /// answering, so ``KnowledgeModeResponse`` gates both. That echo is the reason
    /// this is the ONE write on the workspace-settings surface that needs no
    /// separate re-read, and gating the pair together is what would catch the two
    /// drifting apart.
    ///
    /// ⛔ THE LIST AND THE CREATE SHARE ``KnowledgeDocument`` AND DO NOT SHARE A
    /// KEY SET, WHICH IS THE PAIRING WORTH LOOKING AT TWICE. `GET`'s `select`
    /// carries `sourceUrl`; `POST`'s does not, so the create echo is six keys to
    /// the list's seven. A type that required `sourceUrl` would throw on the
    /// response to a successful upload, and a gate run against only the list
    /// fixture would never notice. ⚠️ Only the list needs an
    /// `allowedExplicitNulls` entry, and only for row 0: the pasted document nulls
    /// that column while the create OMITS it.
    private static var knowledge: [ImplementedFixture] {
        [
            gate("district-knowledge.json", KnowledgeListResponse.self),
            gate("district-knowledge-create.json", KnowledgeCreateResponse.self),
            gate("district-knowledge-mode.json", KnowledgeModeResponse.self),
            gate("district-knowledge-mode-patch.json", KnowledgeModeResponse.self),
        ]
    }

    // MARK: - The workspace's outbound carrier accounts

    /// ⛔ NINE FIXTURES, SEVEN ROUTES, SIX TYPES, AND EVERY ONE OF THOSE THREE
    /// NUMBERS IS DIFFERENT FOR ITS OWN REASON. The READ has two fixtures because
    /// its KEY SET differs (a fresh workspace omits `defaultAccountId` and nulls
    /// `managedAccount`), the PROBE has two because a rejected credential is a
    /// **200** with `success: false`, and `setDefault` and `delete` share one type
    /// because the route genuinely returns one shape for both.
    ///
    /// ⛔ THE READ PAIR IS THE ONLY PLACE ON THIS SURFACE WHERE THE STRICT GATE
    /// EARNS ITS KEEP TWICE OVER. `MessagingResponse.defaultAccountId` has to be
    /// Optional or the unmanaged body fails to decode, AND the re-encode walk is
    /// what proves the Optional does not invent the key back on a body that never
    /// had it. A DTO that defaulted it to `""` would pass a decode test and add a
    /// key here.
    ///
    /// ⛔ THE REJECTION FIXTURE IS GATED AGAINST THE SAME TYPE AS THE PASS, NOT
    /// AGAINST `ApiErrorEnvelope`, and that is the assertion rather than a
    /// convenience. `{success:false, error}` on a **200** is this route's ANSWER;
    /// modelling it as an error envelope would be modelling it as a failure, which
    /// is precisely the confusion `MessagingTestResponse` exists to prevent. Both
    /// bodies decode as the same type and the caller branches on the flag.
    ///
    /// ⚠️ `district-messaging-meta.json` LANDS ON THE SHARED ``SuccessResponse``,
    /// like the three workspace-settings patches. The consequence is a product one
    /// and is recorded at the foot of `MessagingResponses.swift`: nothing in this
    /// client can read the stored creator cell number back.
    private static var messaging: [ImplementedFixture] {
        [
            gate("district-messaging.json", MessagingResponse.self),
            gate("district-messaging-unmanaged.json", MessagingResponse.self),
            gate("district-messaging-upsert.json", MessagingAccountSaveResponse.self),
            // ⚠️ ONE TYPE, TWO ACTIONS, TWO GATES. Sharing the type says the server
            // returns one shape; gating each fixture says so about each action
            // separately, so a divergence reds one of them rather than neither.
            gate("district-messaging-set-default.json", MessagingDefaultResponse.self),
            gate("district-messaging-delete.json", MessagingDefaultResponse.self),
            gate("district-messaging-channel-default.json", MessagingChannelDefaultResponse.self),
            gate("district-messaging-meta.json", SuccessResponse.self),
            gate("district-messaging-test.json", MessagingTestResponse.self),
            gate("district-messaging-test-rejected.json", MessagingTestResponse.self),
        ]
    }

    // MARK: - District HQ

    /// ⛔ ONE ROUTE, THREE FIXTURES, TWO TYPES, AND THE SPLIT IS THE ASSERTION.
    /// `POST /api/district/hq` branches on the PRESENCE of a `confirm` key in the
    /// body, so the two prompt bodies and the confirm body come from one path. They
    /// are gated against two types rather than one union with everything Optional,
    /// because a union would let a CONFIRM response decode as a prompt response with
    /// an empty answer, i.e. an executed write silently reported as a reply.
    ///
    /// ⛔ THE TWO PROMPT FIXTURES DIFFER BY TWO ABSENT KEYS, AND THAT IS WHY THERE
    /// ARE TWO. A plain answer carries `{success, answer}` and nothing else; a
    /// proposal adds `needsConfirmation` and `pendingWrite`. A single fixture would
    /// pin those as either mandatory or non-existent, and the second mistake means a
    /// phone that silently drops the confirmation prompt for a deletion. ⚠️ The keys
    /// are ABSENT rather than null on the plain branch, so neither needs an
    /// `allowedExplicitNulls` entry and adding one would be a mistake.
    private static var districtHQ: [ImplementedFixture] {
        [
            gate("district-hq-answer.json", HqPromptResponse.self),
            gate("district-hq-pending-write.json", HqPromptResponse.self),
            gate("district-hq-confirm.json", HqConfirmResponse.self),
        ]
    }

    // MARK: - Workflows and the always-on campaign

    /// ⛔ SIX FIXTURES ACROSS FIVE ROUTES, AND THE TWO CAMPAIGN VERBS SHARE A TYPE
    /// BECAUSE THE ROUTE ANSWERS THE READ'S SHAPE FROM THE WRITE. That is deliberate
    /// server-side, so a phone can render the result of a pause without a second
    /// request that would race its own write, and gating all three campaign bodies
    /// against one type is what would catch the two verbs drifting apart.
    ///
    /// ⛔ THE UNCONFIGURED CAMPAIGN IS A STATE AND NOT AN ERROR, which is the single
    /// most important thing these fixtures pin. `district-campaign-status-empty.json`
    /// is `{false, null, null}`: the route collapses "absent" and "off" into one
    /// rendering so that "we have no campaign" and "the campaign is off" are not two
    /// screens for the same thing. Both nulls have exact allowlist paths, and neither
    /// may be read as a zero or an empty string.
    ///
    /// ⚠️ THE FOUR RUN STATUSES ARE IN ONE FIXTURE ON PURPOSE. `partial` is the one
    /// that draws like a healthy run if it is toned wrong, and the `failed` row is the
    /// one with an EMPTY `actionResults` and a run-level `error`, which is the shape a
    /// screen showing only per-action rows would render as an unexplained failure.
    ///
    /// ⚠️ `district-workflow-toggle.json` LANDS ON THE SHARED ``SuccessResponse``.
    /// The consequence is a UI one and is recorded at the foot of
    /// `WorkflowResponses.swift`: nothing in that reply can be adopted, so a toggle
    /// is optimistic-with-revert while the pause beside it adopts its own response.
    private static var automation: [ImplementedFixture] {
        [
            gate("district-workflows.json", WorkflowListResponse.self),
            gate("district-workflow-runs.json", WorkflowRunsResponse.self),
            gate("district-workflow-toggle.json", SuccessResponse.self),
            gate("district-campaign-status.json", CampaignStatusResponse.self),
            gate("district-campaign-status-empty.json", CampaignStatusResponse.self),
            gate("district-campaign-pause.json", CampaignStatusResponse.self),
        ]
    }

    /// ⚠️ INTERNAL RATHER THAN `private`, AND THE REASON IS THE 500-LINE
    /// `file_length` CEILING RATHER THAN A DESIGN CHANGE. Groups that did not fit
    /// here live in the `ImplementedFixtures+*.swift` files as extensions, and a
    /// `private` helper is file-private, which an extension in another file cannot
    /// call. Keep new
    /// groups over there; this file has no room left.
    static func gate(_ name: String, _ type: (some Codable).Type) -> ImplementedFixture {
        ImplementedFixture(name: name, type: String(describing: type)) {
            _ = try StrictDecodeVerifier.verify(fixture: name, as: type)
        }
    }
}
