import Foundation

/// The endpoints that still answer as bytes because their DTO does not exist
/// yet — the tracked `UNTYPED_ENDPOINTS` list.
///
/// ⛔ THIS IS A BURN-DOWN LIST AND IT MUST ONLY EVER SHRINK. Every route here is
/// read through ``RawResponse`` until its contract fixture is implemented and its
/// DTO ports. Moving an endpoint out of here means: add the DTO, implement its
/// fixture in `ContractFixtureTests`, AND change the repository that calls it to
/// decode typed — in one commit, so the strict gate, the client and this list
/// agree at every commit.
///
/// ⚠️ THE THIRD OF THOSE THREE IS THE ONE THAT IS EASY TO SKIP. DTOs can be
/// gated and proven while every repository still returns ``JSONValue``, so not one
/// of them is on a path any screen can reach. A DTO that nothing decodes is a
/// fixture test, not a client. This list means "the
/// repository hands back bytes", not "no DTO exists".
///
/// ⛔ AND THE THREE LISTS ARE EXHAUSTIVE AND DISJOINT BY TEST, NOT BY CONVENTION.
/// `EndpointSurfaceTests` asserts that ``all`` ∪ ``TypedEndpoints/all`` ∪
/// ``RedirectEndpoints/all`` is exactly ``EndpointID/allCases`` with no overlap,
/// so an endpoint added without being classified fails the suite rather than
/// quietly defaulting to "raw" — which is the shape that makes a burn-down list
/// stop being true without anyone noticing.
public enum UntypedEndpoints {
    public static let all: Set<EndpointID> = [
        .deleteDraft,
        .deleteDocument,
    ]
}

/// The endpoints a repository decodes into a `DistrictModel` DTO today.
///
/// ⚠️ THE ENDPOINT COUNT AND THE FIXTURE COUNT ARE DIFFERENT NUMBERS AND OFTEN
/// DISAGREE. A fixture pins a BODY, and a route is free to have several: the
/// messaging read has two because a fresh workspace's body OMITS
/// `defaultAccountId`, the credential probe has two because a rejected credential
/// arrives as a **200** with `success: false`, `hqPrompt` answers a plain answer and
/// a proposal, and `stripeBilling` answers three bodies (healthy,
/// `billingUnavailable`, and no-customer, the last two one absent key apart).
/// Sizing a change by fixtures overstates it.
///
/// ⛔ MEMBERSHIP HERE IS "A REPOSITORY DECODES IT", NOT "A DTO EXISTS FOR IT".
/// Routes still in ``UntypedEndpoints/all`` (`deleteDraft` and `deleteDocument`)
/// have gate-proven DTOs already and are listed as untyped anyway, correctly,
/// because nothing decodes them yet. Reversing the rule would make this list
/// describe `DistrictModel`'s contents rather than the client's behaviour, and the
/// burn-down would then be measuring the wrong thing. A DTO nothing decodes is the
/// failure the ⚠️ at the top of ``UntypedEndpoints`` describes: the two device
/// revokes are typed only because ``DevicesRepository`` decodes the device list
/// that makes an opaque `deviceId` learnable at all.
///
/// ⚠️ `saveDirectory` IS THE SHARPEST READING OF THAT RULE. Its DTO
/// (`district-directory-patch.json`, gated against ``SuccessResponse``) tells it
/// apart from nothing; only the repository does, and adding one is a decision about
/// the most destructive call in this client rather than a line of plumbing: the
/// route writes `callDirectory || []`, so an empty array WIPES every transfer target
/// and answers 200. ``WorkspaceRepository/saveDirectory(workspaceId:callDirectory:)``
/// is that decision taken. `deleteDocument` still sits where `saveDirectory` was.
///
/// ⚠️ NOT EVERY DTO HERE IS FIXTURE-PINNED, and that is a property of the corpus
/// rather than a lowered bar. The shared corpus is generated for the Android
/// client, so a route that client never calls (`createContact`, `messages/search`,
/// call handling, provisioning, the softphone hang-up) can have no fixture on disk;
/// its DTO is modelled from the route source and pinned by its repository's tests.
/// ⛔ `ContractManifest.expectedFixtureCount` is asserted EXACTLY against the files
/// on disk, so it moves only when files do.
///
/// ⚠️ SOME ROUTES SEND NO ENVELOPE FLAG AT ALL, and their repositories must not
/// affirm one: `stripeBilling` answers a bare OBJECT, `meetings` a bare ARRAY, and
/// the scheduling pair has the same property. The tempting edit on any new
/// repository is a copied `affirm` line from a neighbouring one.
public enum TypedEndpoints {
    /// ⚠️ THIS SET PLUS THE PER-FAMILY SETS IN SIBLING FILES — a lint ceiling rather
    /// than a taxonomy: one file would exceed `file_length`'s 500 lines and the
    /// commentary is the point of it. ⛔ A family declared elsewhere and not unioned in here
    /// fails `EndpointSurfaceTests`' partition assertion rather than defaulting to
    /// "raw", which is what keeps the split honest.
    public static let all: Set<EndpointID> =
        core.union(desk).union(inbox).union(callHandling).union(numbers).union(softphone)
            .union(schedulingAdmin).union(persona).union(blocking).union(setup)

    private static let core: Set<EndpointID> = [
        .unreadCount,
        // ── The account's own devices ────────────────────────────────────────
        // ⛔ THE READ IS WHAT MAKES THE TWO WRITES REACHABLE AT ALL. A `deviceId`
        // is client-generated and opaque, so this list is the only place one can
        // be learned; without it the revokes were a control nobody could press.
        .devices,
        .revokeDevice,
        .revokeAllDevices,
        // ── This installation's push registration ────────────────────────────
        // ⛔ A DIFFERENT `devices` SURFACE FROM THE THREE ABOVE, ON A DIFFERENT
        // PREFIX, AND THE TWO 404 EACH OTHER. Those three are session
        // management under `/api/auth/native/devices/…`; these two are push
        // registration under `/api/district/devices/…`. They arrive here
        // together because ``PushTokenRepository`` decodes both, which is the
        // membership rule this list actually states.
        //
        // ⚠️ BOTH LAND ON THE SHARED ``SuccessResponse``, gated per fixture in
        // `ImplementedFixtures`. See the ⛔ at the foot of
        // `DeviceResponses.swift` for why that is a decision rather than a
        // shortcut.
        .registerPushToken,
        .unregisterPushToken,
        .members,
        .addMember,
        .changeMemberRole,
        .removeMember,
        .renameWorkspace,
        .roomToken,
        // ── The core read surface ────────────────────────────────────────────
        // ⚠️ `workspaceList` DECODES TYPED WITHOUT GOING THROUGH
        // ``ApiClient/send(_:as:)``, and it is the only one that does. Its 503
        // body is part of the answer (`degradedRegions`), so the repository
        // takes the response unmapped and decodes the 2xx branch itself. It
        // belongs here because the outcome a caller receives is a DTO.
        .workspaceList,
        .overview,
        .calls,
        .callDetail,
        .callTranscript,
        .contacts,
        .contact,
        // ⛔ THE ONE ENTRY ON THIS LIST THAT SPENDS MONEY AND RINGS A TELEPHONE,
        // and the reason ``DialRepository`` reaches for `sendUnmapped` rather
        // than `send(_:as:)`. Its three refusals need three different sentences
        // and two of them are told apart by a `code` the normalised ``ApiError``
        // does not keep; the third has no code at all and is told apart by the
        // SHAPE of its envelope. See the ⛔ on that repository.
        .dial,
        // ⛔ THE OTHER HALF OF THE SAME CREDENTIAL EXCHANGE, AND THE ONE ENTRY
        // HERE THAT SPENDS NOTHING AND STILL MUST NOT BE RETRIED. `calls/answer`
        // writes the Redis rendezvous the agent's `ring-app` transfer is blocked
        // on, so a second attempt races a call that is being connected. It
        // reaches for `sendUnmapped` for the same reason the dial does: two of
        // its refusals are ANSWERS rather than errors (404/409 is "the caller
        // hung up while your phone rang", 403 is a viewer whose phone rang
        // anyway) and the normalised ``ApiError`` cannot carry that distinction.
        // See ``DistrictData``'s `InboundCallRepository`.
        .answerCall,
        // ── The contact writes ───────────────────────────────────────────────
        // ⛔ `createContact` DECODES A DTO WITH NO FIXTURE BEHIND IT. See the ⚠️
        // on this type: the corpus has no create/update/delete contact fixture,
        // so `ContactCreateResponse` is pinned by the route source and by
        // `RepositoryTests`, not by the strict gate. The other four land on
        // types the gate does cover (`SuccessResponse`, `EnrichResponse`).
        .createContact,
        .updateContact,
        .deleteContact,
        .enrichContact,
        .clearContactIntel,
        // ── Analytics and metered usage ──────────────────────────────────────
        // ⚠️ `usage` AND `usageHistory` ARE ONE ROUTE AND TWO ENTRIES, because the
        // response TYPE changes with the `history` query parameter — an object
        // there, an array here. Classifying them together would hide the fact that
        // a caller able to confuse them reads a single month as an empty history.
        .analytics,
        .usage,
        .usageHistory,
        .conversations,
        // ⚠️ NO FIXTURE, which is a property of the CORPUS rather than a lowered
        // bar: the fixtures mirror the Android client and that client has no search, so there is no
        // `district-message-search.json` to gate against. Same footing as
        // `createContact`. What pins the shape is the route source and
        // `InboxRepositoryTests`, including the short-query body whose `limit` key
        // is absent.
        .searchMessages,
        // ⚠️ TYPED HERE MEANS "THE REPOSITORY DECODES IT FIRST", NOT "NOTHING
        // ELSE CAN READ IT". `DistrictData.ThreadPageReader` keeps its
        // shape-guarded ``JSONValue`` walk as a fallback for a document the DTO
        // refuses, because a deployed origin can lag the fixture corpus by a
        // release. The typed path is the one that runs on a healthy fleet, which
        // is what puts this endpoint on this list. See `InboxRepository.timeline`.
        .timeline,
        // ── The composer ─────────────────────────────────────────────────────
        .sendMessage,
        .markRead,
        .uploadMedia,
        .draft,
        .drafts,
        .saveDraft,
        .generateDraft,
        // ── Scheduling ───────────────────────────────────────────────────────
        // ⚠️ NEITHER ROUTE CARRIES A `success` ENVELOPE — status answers
        // `{eligible, canManage, tenant}` and enable answers `{ok, status,
        // publicHost, error}`. "Typed" here means the repository decodes a DTO,
        // and for these two it also means it must NOT reach for
        // `ResponseEnvelope.affirm`, which would look for a flag that does not
        // exist and fail every response.
        .schedulingStatus,
        .schedulingEnable,
        .schedulingHandoff,
        // ── The tenant's own support requests with Distronode ────────────────
        // ⚠️ Their fixtures are gated in `ImplementedFixtures+DeskSupport.swift`.
        // Full reasoning is on `DistrictEndpoints+Support.swift`.
        .supportRequests,
        .createSupportRequest,
        .supportRequest,
        .replyToSupportRequest,
        .closeSupportRequest,
        // ── Workspace settings: the read and its three writes ────────────────
        // ⛔ `workspaceConfig` IS THE READ THE WRITES ARE BUILT ON, decoded by
        // ``WorkspaceRepository/config(workspaceId:)``.
        // ⚠️ IT MATTERS MORE HERE THAN ANYWHERE ELSE THAT THE FOUR ARE READ
        // TOGETHER: `saveTools` and `saveRoutingRules` REPLACE their stored value
        // wholesale, so the obligation on the caller is to build a save on a
        // SUCCESSFUL config load. The read being typed does not discharge that
        // obligation either; it only makes it expressible.
        //
        // ⚠️ ALL FOUR LAND ON THE SHARED ``SuccessResponse``, gated per fixture
        // in `ImplementedFixtures`. See the ⛔ at the foot of
        // `WorkspaceConfigResponses.swift` for why that is a decision rather than
        // a shortcut. ⚠️ `saveDirectory` is one of the four, decoded by
        // ``WorkspaceRepository/saveDirectory(workspaceId:callDirectory:)``.
        // ⛔ THE NATIVE TRANSFER DIRECTORY IS THEREFORE EDITABLE, and the
        // obligation that comes with that is the one above: the route writes
        // `callDirectory || []`, so a form that saved without loading first would
        // DELETE every human the agent can transfer a live caller to, answered 200.
        .workspaceConfig,
        .savePersona,
        .saveTools,
        .saveDirectory,
        .saveRoutingRules,
        // ── The knowledge base ───────────────────────────────────────────────
        // ⚠️ FOUR OF THE FIVE ROUTES IN THE FAMILY, AND THE MISSING ONE IS THE
        // DELETE. `deleteDocument` keeps its place in ``UntypedEndpoints``
        // because `KnowledgeRepository` deliberately does not wrap it in this
        // commit: `district-knowledge-delete.json` was already gated against
        // ``SuccessResponse`` long before the rest of the family arrived, so
        // moving it is a separate one-line burn-down rather than part of this one.
        //
        // ⚠️ THE READS ADMIT `viewer` AND THE WRITES DO NOT, which is the
        // OPPOSITE split from the workspace-settings trio above, whose READ
        // excludes viewers too. Nothing on this surface is a staff phone number.
        .knowledgeDocuments,
        .createDocument,
        .knowledgeMode,
        .saveKnowledgeMode,
        // ── The workspace's outbound carrier accounts ────────────────────────
        // ⛔ SEVEN ENTRIES FOR NINE FIXTURES, AND THE ARITHMETIC IS THE POINT
        // RATHER THAN A ROUNDING ERROR. The READ has two fixtures because its key
        // set genuinely differs between a configured workspace and a fresh one
        // (`defaultAccountId` is absent from the second), and `testMessagingCredentials`
        // has two because a rejected credential is a **200** carrying
        // `success: false`. Neither pair is a second endpoint.
        //
        // ⛔ FIVE OF THESE ARE ONE URL AND ONE VERB, separated only by an `action`
        // string in the body, and the route's switch falls through to the UPSERT on
        // an unrecognised action. So the thing that keeps a default change from
        // becoming an account edit is a string literal baked into each descriptor,
        // which is why they are five functions rather than one with a parameter.
        //
        // ⛔ `testMessagingCredentials` IS TYPED AND STILL MUST NEVER BE CALLED
        // AGAINST A REAL SERVER FROM A TEST. It makes one authenticated
        // third-party call per request with caller-supplied credentials, from the
        // platform's own egress; see the ⛔ on
        // ``MessagingRepository/testCredentials(workspaceId:providerConfig:)``.
        // Being on this list means a repository decodes it, not that it is cheap.
        //
        // ⚠️ `saveCreatorCell` LANDS ON THE SHARED ``SuccessResponse``, like the
        // three workspace-settings writes above. Its fixture is pinned separately.
        .messaging,
        .saveMessagingAccount,
        .setDefaultAccount,
        .setChannelDefault,
        .deleteMessagingAccount,
        .saveCreatorCell,
        .testMessagingCredentials,
        // ── District HQ ──────────────────────────────────────────────────────
        // ⛔ ONE ROUTE AND TWO ENTRIES, BECAUSE THE BODY PICKS THE OPERATION AND
        // THE TWO ANSWER DIFFERENT SHAPES. `POST /api/district/hq` branches on the
        // PRESENCE of a `confirm` key: without one it runs the model and answers
        // ``HqPromptResponse``, with one it EXECUTES a real write and answers
        // ``HqConfirmResponse``. There is no `/hq/confirm` path to point at, so the
        // two descriptors are the only thing keeping the operations apart.
        //
        // ⛔ AND `hqConfirm` IS THE MOST CONSEQUENTIAL ENTRY ON THIS WHOLE LIST. It
        // applies a persona change, a deletion, a routing replacement, an outbound
        // campaign, or a real email or SMS to a customer, and it is not idempotent.
        // ``HQRepository`` takes an ``HqPendingWrite`` rather than a tool name so a
        // caller cannot confirm an action the operator never read.
        .hqPrompt,
        .hqConfirm,
        // ── The automation monitor ───────────────────────────────────────────
        // ⚠️ FIVE ROUTES, THREE OF WHICH ADMIT `viewer` (the list, the run history
        // and the campaign READ) while the toggle and the campaign PATCH do not.
        // The campaign path is the only VERB split in this API, and it is what
        // lets that route admit the lowest-trust role at all.
        //
        // ⚠️ `setWorkflowActive` LANDS ON THE SHARED ``SuccessResponse``, like the
        // workspace-settings writes and the messaging `meta` action. Its fixture is
        // pinned separately, and the consequence is a UI one: nothing in that reply
        // can be adopted, so a toggle is optimistic-with-revert while the campaign
        // pause beside it adopts the read's whole shape from its own response.
        .workflows,
        .workflowRuns,
        .setWorkflowActive,
        .campaignStatus,
        .setCampaignEnabled,
        // ── Billing, read only ───────────────────────────────────────────────
        // ⛔ TWO ROUTES, TWO ENVELOPES, AND ONE OF THEM SENDS NO `success` AT
        // ALL. `workspace/billing` answers the ordinary `{success, billing}`
        // from our own columns; `/api/billing` answers a BARE OBJECT from
        // Stripe, so "typed" here means the repository decodes a DTO and, for
        // the second one, that it must NOT reach for `ResponseEnvelope.affirm`.
        //
        // ⛔ AND `stripeBilling` HAS THREE BODIES BEHIND ONE ENDPOINT — healthy,
        // `billingUnavailable: true`, and no-customer, the last two identical
        // but for one absent key. Three fixtures, one endpoint: the same
        // arithmetic messaging and HQ made, arriving a fourth time.
        //
        // ⛔ NEITHER MAY EVER GROW A WRITE. `POST /api/billing` cancels
        // subscriptions and changes plans; App Store Review Guideline 3.1.3(b)
        // is why no descriptor for it exists, and a portal link-out is the same
        // violation wearing a URL.
        .workspaceBilling,
        .stripeBilling,
        // ── The phone-number marketplace, read only ──────────────────────────
        // ⛔ THE SEARCH IS THE ONE ENTRY ON THIS LIST WHOSE ORDINARY REFUSAL IS
        // A **400**: a workspace with no carrier connected is a legitimate
        // account state, not a fault, and the repository passes the server's own
        // sentence through rather than turning it into an empty list.
        //
        // ⛔ `ownedNumbers` CAN ANSWER INCOMPLETELY ON A 200 (`partial` with
        // `failedProviders`), which is the shape that decodes cleanly and draws
        // like a complete answer. Typed decoding is what makes the two flags
        // reachable at all; `NumbersRepository` carries them through inside the
        // success rather than promoting them to an error.
        .searchNumbers,
        .ownedNumbers,
        // ── Meetings ─────────────────────────────────────────────────────────
        // ⛔ THE LIST IS A BARE ARRAY AND THE DETAIL IS A BARE OBJECT, so
        // `meetings` stays on ``BareArrayEndpoints`` as well as here — the two
        // lists answer different questions, and `meetingDetail` belongs to
        // neither envelope family. Typed here means `MeetingsRepository` decodes
        // `[MeetingSummary]` and `MeetingDetail`, which are NOT subsets of one
        // another: the list renames `summary` to `summaryPreview` and
        // `participants` to `participantCount`, so one model cannot read the
        // other's payload.
        .meetings,
        .meetingDetail,
    ]
}
