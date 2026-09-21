import Foundation

/// Every endpoint this client can reach, named once.
///
/// ⛔ THIS IS A CLOSED LIST AND THAT IS THE SECURITY PROPERTY, NOT THE
/// BOOKKEEPING. ``ApiRequestDescriptor``'s initialiser is internal, so the only
/// requests the public API can express are the ones ``DistrictEndpoints`` builds
/// — and there is no case here for `calls/outbound` (the AI campaign dialer: a
/// human dialling through it would find the voice agent on their own line) or
/// for any `video_` room (a billable Tavus avatar, concurrency ceiling 1, never
/// exercised in production). Both are UNCONSTRUCTIBLE rather than discouraged.
/// `EndpointSurfaceTests` pins that.
///
/// ⚠️ THE RAW VALUE IS THE KOTLIN FUNCTION NAME, deliberately. The two clients
/// speak the same API and are reviewed against each other; a diff between
/// `HttpDistrictApi.kt`'s function list and `EndpointID.allCases` is the cheapest
/// parity check available, and renaming for Swift taste would cost it.
///
/// ⚠️ THE CASE COUNT IS ASSERTED IN `EndpointTableTests` AND NOWHERE ELSE, AND
/// THIS PARAGRAPH IS NOT THE PLACE TO READ IT. A number quoted in prose goes stale
/// as soon as the next route lands. Re-derive it from `EndpointID.allCases`.
///
/// ⚠️ SOME CASES HAVE NO KOTLIN COUNTERPART YET (the scheduling family, the
/// provisioning family, the desk families). ⛔ Their raw values are still spelled
/// as Kotlin function names, so the parity diff keeps working the day that client
/// catches up.
///
/// ⚠️ ``searchMessages`` IS A DIFFERENT KIND OF GAP. `messages/search` has
/// existed on the SERVER the whole time and no client of ours — web, Kotlin or
/// this one — has ever called it, so the parity diff will report it missing on
/// the Kotlin side indefinitely rather than until that client catches up.
public enum EndpointID: String, Sendable, CaseIterable {
    // Workspaces + overview
    case workspaceList
    case overview
    /// The setup wizard's state, read only to decide whether the overview offers the
    /// owner the rest of setup. ⚠️ Owner only: a member's 403 means "offer nothing".
    /// The raw value is the Android client's name for it (`SetupApi.districtSetup`).
    case districtSetup

    // Calls
    case calls
    case callDetail
    case callTranscript
    case callRecordingUrl
    case dial
    case answerCall
    /// ⚠️ THE THIRD ROUTE IN THE DIAL/ANSWER FAMILY AND THE ONLY ONE THAT IS SAFE
    /// TO SEND TWICE. See ``DistrictEndpoints/hangUpCall(callId:workspaceId:)``.
    case hangUpCall

    // Rooms + meetings
    case roomToken
    case meetings
    case meetingDetail

    // Contacts + DGI
    case contacts
    case contact
    case createContact
    case updateContact
    case deleteContact
    case enrichContact
    case clearContactIntel
    /// ⛔ ONE CASE FOR BLOCK **AND** UNBLOCK, because the route takes the desired
    /// state in its body rather than exposing two paths. Two cases would imply two
    /// routes and would put the partition assertion in `EndpointSurfaceTests` to
    /// work proving something the server does not do.
    case setContactBlocked
    case blockedContacts

    // Inbox
    case conversations
    case timeline
    case unreadCount
    /// ⚠️ NOT A FILTER OVER ``conversations``. It reads the whole Message table
    /// for the workspace, so it reaches threads that list never scanned.
    case searchMessages
    /// One message id exchanged for the thread it belongs to.
    ///
    /// ⛔ IT IS THE ONLY THING THAT MAKES A MESSAGE PUSH ACTIONABLE, because every
    /// other endpoint on this surface is addressed by THREAD. The payload carries a
    /// `messageId` and deliberately carries nothing else — a `threadKey` is a raw
    /// phone number or email address whenever the thread has no `Contact` row, and
    /// a notification is readable by the OS. So the deep link and both shade
    /// actions spend one authenticated request rather than widening the payload.
    ///
    /// ⚠️ ITS ROLES ARE `["agency","client"]`, matching `markRead`/`sendMessage`
    /// rather than `timeline`. Gate it where the writes are gated.
    case messageThread
    case sendMessage
    case markRead
    case uploadMedia

    // Composer
    case draft
    case drafts
    case saveDraft
    case deleteDraft
    case generateDraft

    // HQ
    case hqPrompt
    case hqConfirm

    // Analytics + usage
    case analytics
    case usage
    case usageHistory

    // Numbers marketplace (read only)
    case searchNumbers
    case ownedNumbers

    // Sessions + push
    case devices
    case revokeDevice
    case revokeAllDevices
    case registerPushToken
    case unregisterPushToken

    // Billing (read only)
    case workspaceBilling
    case stripeBilling

    // Workspace settings
    case workspaceConfig
    case savePersona

    // The two routes that make the persona form EDITABLE from a phone rather
    // than merely readable.
    //
    // ⛔ `personaOptions` EXISTS BECAUSE `workspace/persona` COERCES. An
    // unrecognised `modelId` is silently rewritten to `deepgram-pipeline` and an
    // unrecognised `voice` is stored verbatim and then replaced by the agent's own
    // fallback at synthesis time — both answering 200, both producing a persona
    // nobody chose with nothing anywhere reporting it. The web form never has that
    // problem because it derives its pickers from the same modules the route
    // reads; this is that derivation, on the wire. A hardcoded Swift catalogue
    // would be the drifting second copy the route was built to retire.
    //
    // ⛔ `personaPreviewToken` MINTS A LIVE, BILLED SESSION. It is an invitation
    // for the voice agent to join a room and start burning STT/LLM/TTS minutes, it
    // is capped at 10/min per WORKSPACE, and it is not idempotent — nothing in
    // this client may retry it. See
    // ``DistrictEndpoints/previewToken(workspaceId:form:)``.
    //
    // ⚠️ NO KOTLIN COUNTERPART, like the scheduling pair, the inbox search and both
    // desk families. The raw values are still spelled as Kotlin function names so
    // the parity diff against `HttpDistrictApi.kt` keeps working the day that
    // client catches up.
    // ⛔ BOTH HAVE A CONTRACT FIXTURE, unlike the scheduling admin pair; the two
    // files are gated in `ImplementedFixtures` rather than skip-listed.
    case personaOptions
    case personaPreviewToken
    case saveTools
    case saveDirectory
    case saveRoutingRules

    // Who answers a call, and whether this person can be rung
    //
    // ⛔ FOUR CASES FOR TWO PATHS, because each is GET + PATCH — the same split
    // `desk/settings` makes, and what lets `EndpointTableTests` assert a method
    // per entry so a read cannot be expressed as a write.
    //
    // ⛔ AND THE TWO PATHS ARE NOT ONE SURFACE. `call-handling` is a WORKSPACE
    // setting; `availability` is a fact about the CALLER'S OWN membership row and
    // writes nobody else's — the route takes no email and no user id, deliberately.
    //
    // ⚠️ NO KOTLIN COUNTERPART YET, like the scheduling pair, the inbox search and
    // the support and desk families. The raw values are still spelled as Kotlin
    // function names so the parity diff against `HttpDistrictApi.kt` keeps working
    // the day that client catches up.
    case callHandling
    case saveCallHandling
    case availability
    case saveAvailability

    // Knowledge base
    case knowledgeDocuments
    case createDocument
    case deleteDocument
    case knowledgeMode
    case saveKnowledgeMode

    // Carrier accounts
    case messaging
    case saveMessagingAccount
    case setDefaultAccount
    case setChannelDefault
    case deleteMessagingAccount
    case saveCreatorCell
    case testMessagingCredentials

    // District Desk — the tenant's OWN customers' tickets
    //
    // ⛔ NOT THE SUPPORT DESK. `/api/district/support/*` is the tenant raising
    // something WITH DISTRONODE; this family is the tenant's customers raising
    // something with the TENANT. Two queues, opposite directions, and the raw values
    // below say `desk` for exactly one of them.
    //
    // ⛔ NINE CASES FOR SEVEN PATHS, because two of them carry two verbs each:
    // `desk/settings` is GET + PATCH and `desk/logo` is POST + DELETE. Splitting each
    // into its own case is what lets `EndpointTableTests` assert a method per entry,
    // and what keeps a read from being expressible as a write.
    //
    // ⚠️ NO KOTLIN COUNTERPART EXISTS. Like the scheduling pair and the inbox search,
    // these raw values are still spelled as Kotlin function names so the parity diff
    // against `HttpDistrictApi.kt` keeps working the day that client catches up.
    case deskSettings
    case saveDeskSettings
    /// ⛔ The second multipart route on this surface, and the workspace travels in the
    /// QUERY rather than as a form field. See ``DistrictPaths/deskLogo``.
    case uploadDeskLogo
    case deleteDeskLogo
    case deskTickets
    case createDeskTicket
    case deskTicket
    /// ⛔ Its body field is `message`, not `body`. See ``DistrictPaths/deskTicketReply(_:)``.
    case replyToDeskTicket
    case setDeskTicketStatus

    // Membership
    case members
    case addMember
    case changeMemberRole
    case removeMember
    case renameWorkspace

    // Scheduling
    //
    // ⛔ A COUNT WRITTEN INTO PROSE GOES STALE THE MOMENT THE NEXT ROUTE LANDS, so
    // derive the size of this family from the cases rather than from a comment.
    //
    // ⛔ `scheduling/sso` IS NOT RETIRED. It is still the CALENDAR-OAUTH leg (the
    // round trip comes back with an explicit `next=/v1/calendar/connect…`), and it
    // answers **410 `scheduler_console_retired`** only for a `next` that lands on
    // `/admin`. It has no case here for the reason it never had one: it answers a
    // **302** whose `Location` is a one-time sign-in credential, so the App target
    // fetches it with redirects DISABLED and hands the URL to the browser.
    // ``RedirectEndpoints`` is not the home for it either — that list is for
    // targets that are presigned OBJECTS, where following the redirect wastes
    // bandwidth rather than SPENDING a credential on a transport nobody sees.
    //
    // ⛔ THE THREE SCHEDULING ADMIN CASES ARE ONE ROUTE FAMILY WITH THREE TRANSPORTS, NOT
    // THREE FEATURES. `schedulingAdmin` is the RPC that carries all 75 catalogued
    // ops (see ``SchedulingAdminOp``); `schedulingAdminUpload` exists only because
    // an image cannot travel through a zod-validated params object, and
    // `schedulingAdminDownload` only because a recording is a 302 to a presigned
    // object the server refuses to proxy. A fourth transport would need a fourth
    // reason of that kind, not a fourth screen.
    case schedulingStatus
    case schedulingEnable
    case schedulingHandoff
    case schedulingAdmin
    case schedulingAdminUpload
    /// ⛔ THE SECOND ENTRY ON ``RedirectEndpoints/all`` AND THE FIRST ONE THAT IS
    /// NOT A RECORDING OF A PHONE CALL. Same handling, same reason: send it
    /// through ``ApiClient/redirectTarget(_:)`` or the transport downloads a
    /// multi-hundred-megabyte video to learn its address.
    case schedulingAdminDownload

    // The tenant's own support requests WITH Distronode
    //
    // ⛔ NOT THE TENANT'S DESK. `district/support/*` is the customer raising
    // something with us; `district/desk/*` is their customers raising something
    // with them. Both families speak of requests, threads and replies, and the
    // only thing separating them anywhere in this client is the word in the path
    // and the word on the screen. A bare `tickets` on either side undoes that.
    //
    // ⛔ FIVE CASES FOR FIVE ROUTES, INCLUDING TWO THAT ARE **NOT IDEMPOTENT**.
    // `replyToSupportRequest` posts a public comment into a live human queue, and
    // `closeSupportRequest` posts an audit comment BEFORE it transitions the
    // request — so a repeat of either leaves a second visible message in a
    // customer's own thread. See ``SupportResubmit``.
    //
    // ⚠️ THESE RAW VALUES NAME NO KOTLIN FUNCTION, and they are the third such
    // group after the scheduling pair and `searchMessages`. `HttpDistrictApi.kt`
    // has no support surface at all, so the parity diff will report all five
    // missing on that side until the Android client ports this screen. The
    // spelling still follows that client's conventions so the diff keeps working
    // the day it does.
    case supportRequests
    case createSupportRequest
    case supportRequest
    case replyToSupportRequest
    case closeSupportRequest

    // Workflows + campaign
    case workflows
    case workflowRuns
    case setWorkflowActive
    case campaignStatus
    case setCampaignEnabled

    // Phone-number provisioning: everything that happens to a number that is not
    // buying one, plus the carrier surfaces a number needs to work at all.
    //
    // ⛔ THERE IS NO `purchaseNumber` CASE AND THERE MUST NOT BE. Buying a number
    // charges a setup fee AND opens a recurring monthly charge for a service consumed
    // inside the app, which is App Store Review Guideline 3.1.1: an in-app purchase or
    // nothing. With no case here and no ``DistrictPaths`` constant, and with
    // ``ApiRequestDescriptor``'s initialiser internal, `workspace/numbers/purchase` is
    // UNCONSTRUCTIBLE from outside this module rather than merely undocumented — the
    // same mechanism that holds out `calls/outbound`, for an entirely different reason.
    // ⛔ 3.1.1 ALSO COVERS STEERING, so nothing links to the web marketplace either.
    // `EndpointSurfaceTests` pins both halves.
    //
    // ⛔ AND NO `startVerification` / `checkVerification` EITHER, which is a SCOPING
    // decision rather than a policy one: `workspace/verify/start` and
    // `workspace/verify/check` are live, and an OTP entry flow is its own screen with
    // its own retry, expiry and attempt-ceiling states. ``verifyService`` and
    // ``setVerifyServiceEnabled`` below are the service's CONFIGURATION.
    //
    // ⚠️ SIXTEEN CASES FOR TWELVE PATHS, because four paths carry two verbs each:
    // `numbers/registrations` is GET + POST, `numbers/registrations/documents` is
    // POST + DELETE, `workspace/sip` is GET + POST and `workspace/verify` is GET +
    // POST. The same "a path is not an endpoint" arithmetic the desk family made.
    //
    // ⚠️ NO KOTLIN COUNTERPART EXISTS FOR ANY OF THEM. Like the scheduling pair, the
    // inbox search and both desk families, these raw values are still spelled as
    // Kotlin function names so the parity diff against the Android client's
    // `HttpDistrictApi` keeps working the day that client catches up.
    // ⛔ AND NONE HAS A CONTRACT FIXTURE, so `ContractManifest.expectedFixtureCount`
    // MUST NOT MOVE for them: it is asserted exactly against the files on disk, and
    // the shared corpus mirrors the Android client.
    case providerStatus
    case numberRequirements
    case numberRegistrations
    case createNumberRegistration
    /// ⛔ The THIRD multipart route here, and its part list matches neither of the
    /// other two. See ``DistrictPaths/numbersRegistrationDocuments``.
    case uploadRegistrationDocument
    /// ⛔ The only DELETE on this API that carries a JSON body. See
    /// ``DistrictPaths/numbersRegistrationDocuments``.
    case deleteRegistrationDocument
    /// ⛔ Files a regulated application in the customer's name. Never retried
    /// automatically.
    case submitNumberRegistration
    /// ⛔ Restates the EU trunk binding or an EU DID is answered on the US hub, with a
    /// 200 either way. See ``DistrictPaths/numbersConfigure``.
    case configureNumber
    /// ⛔ IRREVERSIBLE, and it can answer 200 with `warnings` that a screen must not
    /// swallow. See ``DistrictPaths/numbersRelease``.
    case releaseNumber
    /// ⛔ Creates billable carrier objects and has NO status read.
    case submitA2PRegistration
    /// ⛔ Files a manual carrier review and has NO status read.
    case submitTollFreeVerification
    case sipTrunks
    case createSipTrunk
    case verifyService
    case setVerifyServiceEnabled
    /// ⛔ BILLABLE PER CALL, a GET, and it admits `viewer`. One tap, one lookup — never
    /// on a keystroke, on appear, or in a retry loop. See
    /// ``DistrictPaths/workspaceLookup``.
    case lookupNumber
}
