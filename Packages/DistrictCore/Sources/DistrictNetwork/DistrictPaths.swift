import Foundation

/// Every endpoint path, in one place, as SEGMENT LISTS.
///
/// ⛔ LISTS OF SEGMENTS, NOT STRINGS. ``ApiPath/build(_:)`` encodes each element
/// as exactly one segment; a path template with an id interpolated into it let
/// that id introduce new segments on the Kotlin client, including `..`, and a
/// call id of `a/../../admin` turned `calls/{id}/transcript` into
/// `/api/district/admin/transcript`.
///
/// ⚠️ INTERNAL. These are the raw materials of ``ApiRequestDescriptor``, whose
/// initialiser is also internal — see its ⛔. Exporting them would hand feature
/// code the ability to assemble a path this client has deliberately not ported.
enum DistrictPaths {
    private static let district = ["api", "district"]

    /// ⚠️ NOT `private`, UNLIKE ``district``, AND THE ONE REASON IS THE SIBLING FILE.
    /// `private` is FILE scope in Swift, so `DistrictPaths+Numbers.swift` could not
    /// see it — and the alternative there was a second literal `["api",
    /// "district", "workspace"]`, which is exactly the duplication this whole type
    /// exists to prevent. Still internal to the module, so nothing outside
    /// `DistrictNetwork` can assemble a path from it; see the ⚠️ on the type.
    static let workspace = district + ["workspace"]

    static let workspaceList = workspace + ["list"]

    /// ⚠️ UNDER THE WORKSPACE PATH FAMILY, NOT BESIDE ``analytics``. The two
    /// routes back one screen but they are unrelated server-side — usage is a
    /// workspace-administration read and analytics is a telephony one — and
    /// inventing `/api/district/usage` to make them look like siblings would 404.
    static let workspaceUsage = workspace + ["usage"]

    /// ⚠️ A SIBLING OF ``workspaceUsage`` AND NOT TO BE CONFUSED WITH ``billing``.
    /// This one is the District, workspace-scoped, Stripe-free plan read;
    /// ``billing`` is the caller-scoped Stripe detail at the top level of the
    /// API. One screen reads both, and pointing either at the other's path would
    /// answer a plausible-looking body for the wrong scope.
    static let workspaceBilling = workspace + ["billing"]

    /// ⛔ THE READ THAT EXISTS FOR THIS CLIENT AND FOR NOTHING ELSE, AND THE
    /// WRITES IT GUARDS. The web settings page never needed `workspace/config` —
    /// it is a server component that hydrates its forms from the row during
    /// render — so this is the one path here with no browser caller at all.
    /// Pointing a form at any of the three wholesale-replace writes without
    /// going through it first is how a save becomes a delete.
    static let workspaceConfig = workspace + ["config"]
    static let workspacePersona = workspace + ["persona"]

    /// The persona form's vocabularies, and the preview session's credential.
    ///
    /// ⛔ BOTH ARE CHILDREN OF `workspace/persona` AND NEITHER IS A VERB ON IT.
    /// `workspace/persona` is PATCH-only, so a GET there is a 405 rather than a
    /// catalogue, and the preview is a POST to its own path rather than an action
    /// key in the save body. Spelling either as the parent path is the mistake
    /// available here.
    ///
    /// ⚠️ `preview-token` IS HYPHENATED AND `options` IS NOT, which is the server's
    /// own inconsistency rather than a choice available here — the same shape
    /// `knowledge-mode` has beside `knowledge`.
    static let workspacePersonaOptions = workspacePersona + ["options"]
    static let workspacePersonaPreviewToken = workspacePersona + ["preview-token"]

    static let workspaceTools = workspace + ["tools"]

    /// ⛔ THE OTHER TWO WHOLESALE-REPLACE WRITES. `directory` is a **PATCH** and
    /// `routing-rules` is a **POST**, which is the server's asymmetry rather than
    /// a choice available here — pointing either at the other's verb would 405.
    static let workspaceDirectory = workspace + ["directory"]
    static let workspaceRoutingRules = workspace + ["routing-rules"]

    /// ⛔ TWO ROUTES, TWO SCOPES, AND THE SECOND ONE IS NOT ABOUT THE WORKSPACE.
    /// `call-handling` is a WORKSPACE setting: which of the agent and the app
    /// answers a call, and how long the app rings. `availability` is a fact about
    /// the CALLER'S OWN membership row in that workspace — it writes nobody else's,
    /// and takes no email or user id to do it with. Reading them as one surface is
    /// how a UI ends up offering to set a colleague's availability.
    ///
    /// ⚠️ BOTH ARE GET + PATCH ON ONE PATH, so each is two ``EndpointID`` cases
    /// rather than one, the same split `desk/settings` makes.
    static let workspaceCallHandling = workspace + ["call-handling"]
    static let workspaceAvailability = workspace + ["availability"]

    /// ⚠️ TWO SEPARATE ROUTES, NOT A NESTED ONE. The document store is
    /// `workspace/knowledge` and the source choice is its SIBLING
    /// `workspace/knowledge-mode` — not `workspace/knowledge/mode`, which does
    /// not exist.
    static let workspaceKnowledge = workspace + ["knowledge"]
    static let workspaceKnowledgeMode = workspace + ["knowledge-mode"]

    /// ⛔ ONE PATH, TWO VERBS, AND THE PATCH IS SIX DIFFERENT OPERATIONS. GET
    /// reads the redacted account list; PATCH creates, edits, re-points the
    /// default, sets a per-channel sender, writes the creator cell number, and
    /// DELETES an account — dispatched on an `action` string in the body. There
    /// are no per-action sub-paths: `messaging/default` and `messaging/delete`
    /// do not exist and would 404.
    ///
    /// ⚠️ ``workspaceMessagingTest`` IS A SIBLING ROUTE, NOT A SEVENTH ACTION. It
    /// is a POST, it takes UNSAVED plaintext credentials, and it answers a failed
    /// check with a **200**.
    static let workspaceMessaging = workspace + ["messaging"]
    static let workspaceMessagingTest = workspaceMessaging + ["test"]

    /// ⛔ NOT `workspace/campaign-settings`, WHICH IS A DIFFERENT ROUTE AND A
    /// DESTRUCTIVE ONE. The PATCH on `campaign-settings` writes all three SDR
    /// fields unconditionally, so a partial body sent to it WIPES the goal text
    /// and resets the batch size to 1, with a 200. `campaign-status` reads the
    /// stored Json, spreads it and assigns ONE key. One path apart, opposite
    /// outcomes.
    static let workspaceCampaignStatus = workspace + ["campaign-status"]

    /// ⛔ ONE PATH, FOUR VERBS, AND ITS SIBLING IS A SEPARATE ROUTE. The roster
    /// lives at `workspace/members` (GET/POST/PATCH/DELETE) and the display name
    /// at `workspace/rename` — NOT `workspace/members/rename` and not a `name`
    /// field on the members PATCH, both of which would 404 or be ignored.
    ///
    /// ⚠️ AND THEIR ROLE GUARDS DIFFER: the members WRITES are agency-only while
    /// `rename` admits agency and client, so a shared path would also have
    /// implied a shared guard.
    static let workspaceMembers = workspace + ["members"]
    static let workspaceRename = workspace + ["rename"]

    /// ⚠️ THE MARKETPLACE'S TWO ROUTES ARE NOT SIBLINGS, WHICH LOOKS LIKE AN
    /// ACCIDENT AND IS NOT ONE TO TIDY. Searching available inventory lives at
    /// `workspace/numbers/search` while listing what the workspace already owns
    /// lives at `workspace/provider/numbers`. Inventing `workspace/numbers/owned`
    /// to make them match would 404.
    static let numbersSearch = workspace + ["numbers", "search"]
    static let providerNumbers = workspace + ["provider", "numbers"]

    // ⚠️ THE OTHER TWELVE NUMBER PATHS ARE IN `DistrictPaths+Numbers.swift`, WHICH
    // IS A LINT CEILING RATHER THAN A TAXONOMY: this file is against SwiftLint's
    // 500-line `file_length` and the commentary is the point of it. Same cut
    // `EndpointClassification+Desk.swift` and `EndpointEnvelopes.swift` already
    // made. The two constants above stay here because they are the READ pair that
    // predates the rest of the family.
    //
    // ⛔ `workspace/numbers/purchase` IS ABSENT FROM BOTH FILES ON PURPOSE. It
    // charges a setup fee and opens a recurring monthly charge for a service
    // consumed inside the app, which is App Store Review Guideline 3.1.1
    // territory. See the ⛔ at the head of `DistrictPaths+Numbers.swift`.

    static let overview = district + ["overview"]
    /// The setup wizard's state. ⚠️ Owner only; see ``DistrictEndpoints/districtSetup(workspaceId:)``.
    static let districtSetup = district + ["setup"]
    static let analytics = district + ["analytics"]
    static let calls = district + ["calls"]

    /// ⛔ THE ROOM-JOIN TOKEN LIVES UNDER `calls`, AND THAT IS THE SERVER'S PATH
    /// RATHER THAN A MISFILING TO CORRECT. `/api/district/rooms/token` does not
    /// exist and would 404; the route predates standalone rooms and grew the
    /// `meet_`/`video_` branch later, which is why its own body parameter is
    /// called `roomName` even when it is a `Call.id`.
    static let callsToken = calls + ["token"]

    /// ⛔ A SIBLING OF ``callsToken`` AND EMPHATICALLY NOT THE SAME ROUTE, even
    /// though both mint a LiveKit token under `calls/`. `token` signs a
    /// credential for a room that already exists and persists nothing; `dial`
    /// CREATES a call — it writes a `Call` row, tells the carrier to ring a
    /// telephone, and spends the workspace's minutes.
    ///
    /// ⛔ `calls/outbound` IS THE THIRD ROUTE IN THIS FAMILY AND IT IS ABSENT
    /// FROM THIS FILE ON PURPOSE. It is the AI campaign dialer: it creates a
    /// `call_` room the voice agent joins and speaks in, so a human dialling
    /// through it would find an agent on their own line. There is no constant for
    /// it, no ``EndpointID`` case for it, and ``ApiRequestDescriptor``'s
    /// initialiser is internal — so it is unconstructible from outside this
    /// module rather than merely undocumented. `EndpointSurfaceTests` pins that.
    static let callsDial = calls + ["dial"]

    /// ⛔ A FUNCTION RATHER THAN A CONSTANT, BECAUSE THE ID SITS IN THE MIDDLE OF
    /// THE PATH. Every other per-call route appends the id LAST (`calls/{id}`,
    /// `calls/{id}/transcript`); this one is `calls/{id}/answer`, which is the
    /// shape that invites string interpolation.
    static func callAnswer(_ callId: String) -> [String] {
        calls + [callId, "answer"]
    }

    /// ⛔ THE SAME MIDDLE-OF-THE-PATH SHAPE AS ``callAnswer(_:)``, AND A FUNCTION
    /// FOR THE SAME REASON. `calls/{id}/hangup` invites interpolation, and a
    /// `callId` carrying a `/` interpolated into a template would address a
    /// different route entirely; ``ApiPath/build(_:)`` percent-encodes each
    /// segment, so a segment list cannot traverse.
    static func callHangUp(_ callId: String) -> [String] {
        calls + [callId, "hangup"]
    }

    /// ⛔ UNDER `district`, WHICH IS THE OPPOSITE PREFIX FROM ``nativeDevices``
    /// DESPITE THE WORD "devices" APPEARING IN BOTH. Push registration is a
    /// district resource and sits behind proxy.ts's default-deny middleware as
    /// well as the route's own `requireAuth`; SESSION management is
    /// `/api/auth/native/devices/…`, a PUBLIC prefix where the route guard is the
    /// whole of the access control. `/api/auth/native/devices/register` and
    /// `/api/district/devices/revoke` both 404, and each reads as a broken client.
    private static let pushDevices = district + ["devices"]
    static let devicesRegister = pushDevices + ["register"]
    static let devicesUnregister = pushDevices + ["unregister"]

    /// ⚠️ A TOP-LEVEL DISTRICT ROUTE, NOT A `workspace/` ONE, even though it
    /// takes a `workspaceId` query parameter like the workspace family does.
    /// `workspace/meetings` would 404. The detail route is this path plus the id
    /// — there is no `meetings/detail` segment.
    static let meetings = district + ["meetings"]

    /// ⛔ ONE PATH, FOUR VERBS, AND ONLY TWO ARE REACHABLE FROM THIS CLIENT. GET
    /// lists and PATCH toggles; POST creates a workflow and DELETE removes one,
    /// and neither is ported (a workflow's actions send SMS, send email, register
    /// a DNC entry or POST a webhook). ⛔ There is NO per-workflow path: the id
    /// travels in the PATCH body and in the runs query, so `workflows/{id}` would
    /// 404.
    static let workflows = district + ["workflows"]
    static let workflowRuns = workflows + ["runs"]

    static let contacts = district + ["contacts"]
    static let contactsEnrich = contacts + ["enrich"]
    static let contactsClearIntel = contacts + ["clear-intel"]

    /// The two moderation routes App Store Review Guideline 1.2 asks for.
    ///
    /// ⛔ `block` IS A STATE ASSERTION, NOT A TOGGLE, AND THE PATH IS THE SAME FOR
    /// BOTH DIRECTIONS. The body carries `blocked: Bool`, so the route is
    /// idempotent and a repeat writes the same row — which is what makes it the one
    /// contact mutation a caller may safely send again after an ambiguous failure.
    /// A `contacts/unblock` sibling would have made "am I blocked" a question about
    /// which of two routes last answered.
    ///
    /// ⚠️ `blocked` IS A READ AND IS THE ONLY WAY A CLIENT LEARNS THE SET. The
    /// contact row's own DTO is NOT extended (see ``BlockedContact``), because the
    /// list and detail reads return the raw Prisma row and the gated fixtures pin
    /// it byte for byte.
    static let contactsBlock = contacts + ["block"]
    static let contactsBlocked = contacts + ["blocked"]
    static let conversations = district + ["conversations"]
    static let timeline = district + ["timeline"]

    private static let messages = district + ["messages"]
    static let messagesUnreadCount = messages + ["unread-count"]
    static let messagesSend = messages + ["send"]
    static let messagesMarkRead = messages + ["mark-read"]

    /// One message id exchanged for the thread it belongs to.
    ///
    /// ⛔ A FUNCTION RATHER THAN AN INTERPOLATED TEMPLATE, like ``callAnswer(_:)``
    /// and ``deskTicket(_:)``, and here the argument comes from the least
    /// trustworthy input in the app: a push payload's `messageId` is a string the
    /// sender chose and the OS handed over unauthenticated. ``ApiPath/build(_:)``
    /// encodes each element as exactly ONE segment, so an id of `a/../../admin`
    /// cannot turn `messages/{id}` into another route — which is the bug the
    /// Kotlin client shipped on `calls/{id}/transcript` before its paths were
    /// segment lists.
    ///
    /// ⚠️ THE ID SITS LAST AND THE FAMILY'S OTHER MEMBERS ARE LITERAL WORDS, so
    /// this path is one segment away from ``messagesSend``, ``messagesMarkRead``,
    /// ``messagesSearch``, ``messagesMedia``, ``messagesDrafts`` and
    /// ``messagesDraft``. A message whose id happened to be `send` would address
    /// the send route with a GET; it answers 405 rather than sending anything,
    /// because ids here are cuids and the route exports POST only — worth knowing
    /// rather than worth guarding, since the server owns the id space.
    static func messageThreadTarget(_ id: String) -> [String] {
        messages + [id]
    }

    /// ⛔ FULL-CONTENT SEARCH, AND IT IS NOT ``conversations`` FILTERED. The route
    /// queries the whole `Message` table for the workspace (body AND email subject,
    /// case-insensitive), so a match in a thread that fell outside the conversation
    /// list's 500-row scan window still surfaces. A client that filtered the loaded
    /// rows instead would silently answer "no matches" for messages the workspace
    /// definitely has, which is the failure mode `scanned`/`scanLimit` exists to
    /// caption in the first place.
    ///
    /// ⚠️ A READ THAT ADMITS `viewer`, like the rest of the Inbox reads.
    static let messagesSearch = messages + ["search"]

    /// The multipart attachment upload. Its response url is what
    /// ``messagesSend`` accepts as a `mediaUrl`.
    static let messagesMedia = messages + ["media"]

    /// ⛔ PLURAL IS PERSISTENCE, SINGULAR IS THE BILLED GENERATOR, AND THEY ARE
    /// ONE LETTER APART. `messages/drafts` (GET/PUT/DELETE) stores an unsent
    /// reply and is cheap and idempotent; `messages/draft` (POST) runs a Vertex
    /// generation and is capped at 20/min per workspace. Autosave pointed at the
    /// singular path would bill a model call on every debounce, and nothing about
    /// the name would suggest it.
    static let messagesDrafts = messages + ["drafts"]
    static let messagesDraft = messages + ["draft"]

    /// ⛔ A TOP-LEVEL DISTRICT FAMILY, NOT A `workspace/` ONE, even though every
    /// route in it is workspace-scoped by a `workspaceId` the caller supplies.
    /// `workspace/scheduling` would 404. Same shape as ``meetings``.
    ///
    /// ⛔ AND `scheduling/sso` IS ABSENT WITHOUT BEING RETIRED — A DISTINCTION
    /// THIS COMMENT'S NEIGHBOURS GOT WRONG. It answers a **302** carrying a
    /// one-time sign-in URL, so it is not a JSON body and has no descriptor here
    /// and no ``EndpointID`` case; the App target fetches it as a bearer request
    /// with redirects DISABLED and hands the `Location` to the browser, because
    /// following it here would spend the one-time token on a transport nobody can
    /// see. It is still the CALENDAR-OAUTH leg, answering
    /// 410 only when `next` lands on `/admin`.
    /// `scheduling/webhook/{workspaceId}` is absent for a different and simpler
    /// reason: it is the scheduler's inbound callback and this client is never its
    /// caller.
    private static let scheduling = district + ["scheduling"]
    static let schedulingStatus = scheduling + ["status"]
    static let schedulingEnable = scheduling + ["enable"]

    /// ⛔ ONE PATH FOR SEVENTY-FIVE OPERATIONS, AND THAT IS THE SECURITY MODEL
    /// RATHER THAN AN ECONOMY. The route takes an `op` NAME out of the body and
    /// resolves the scheduler path itself, so this client cannot address a
    /// scheduler route the server's catalog does not name — including the ones a
    /// tenant must never reach (instance credentials shared by every tenancy, the
    /// platform API that can delete any tenancy, and the ownership transfer). See
    /// ``SchedulingAdminOp``.
    static let schedulingAdmin = scheduling + ["admin"]

    /// ⛔ THE THIRD MULTIPART ROUTE ON THIS SURFACE, AND THE WORKSPACE TRAVELS IN
    /// THE **QUERY** — like ``deskLogo`` and unlike ``messagesMedia``. That is not
    /// a style choice at either end: the workspace id has to be readable BEFORE
    /// `req.formData()`, or an anonymous client can make a 4-vCPU origin parse a
    /// body up to Cloudflare's 100 MB for a request it was always going to refuse.
    /// A field list copied from the media upload leaves `requireWorkspaceRole`
    /// with null while the URL looks perfectly correct.
    static let schedulingAdminUpload = schedulingAdmin + ["upload"]

    /// ⛔ A **302** TO A PRESIGNED OBJECT, LIKE `calls/{id}/recording`, AND THE
    /// ONLY OTHER ONE IN THIS CLIENT. The fork answers the download with a
    /// redirect and has no 2xx path at all; the route forwards it rather than
    /// streaming, so this must go through ``ApiClient/redirectTarget(_:)``.
    static func schedulingAdminDownload(_ recordingId: String) -> [String] {
        schedulingAdmin + ["download", recordingId]
    }

    /// ⛔ THE REPLACEMENT FOR `scheduling/sso`, AND IT IS JSON WHERE THAT ONE WAS A
    /// 302. The console was retired (the route now answers 410); `handoff` mints a
    /// short-lived URL in a body this client can decode, so unlike its predecessor it
    /// HAS a descriptor and an ``EndpointID``. The URL is still single-use and still
    /// goes straight to the browser without being followed here.
    static let schedulingHandoff = scheduling + ["handoff"]

    /// ⛔ THE TENANT'S OWN TICKETS **WITH DISTRONODE**, WHICH IS THE OPPOSITE
    /// DIRECTION FROM `district/desk`. Support is the customer writing to us; the
    /// desk is their customers writing to them. The two families are one segment
    /// apart, they carry the same kinds of noun (a request, a thread, a reply) and
    /// pointing one at the other would show a tenant somebody else's
    /// correspondence — so the labels on every screen keep them apart and so does
    /// this comment. `district/support/tickets` does not exist and would 404.
    ///
    /// ⚠️ THE IDENTIFIER IN THE PATH IS A **JIRA ISSUE KEY** (`DA-42`), NOT A
    /// NUMERIC ID AND NOT OUR OWN ROW ID. The server's funnel accepts either
    /// spelling (`OR: [{ issueKey }, { id }]`) so a request that has not been filed
    /// yet is still addressable by its local id, which is why every function below
    /// takes one opaque `key` rather than two parameters.
    private static let support = district + ["support"]
    static let supportRequests = support + ["requests"]

    /// ⛔ FUNCTIONS RATHER THAN CONSTANTS, AND THE LAST TWO PUT THE KEY IN THE
    /// MIDDLE OF THE PATH — the shape that invites string interpolation, exactly as
    /// ``callAnswer(_:)`` does. A key is encoded as ONE segment by
    /// ``ApiPath/build(_:)``.
    static func supportRequest(_ key: String) -> [String] {
        supportRequests + [key]
    }

    static func supportRequestReply(_ key: String) -> [String] {
        supportRequests + [key, "reply"]
    }

    static func supportRequestClose(_ key: String) -> [String] {
        supportRequests + [key, "close"]
    }

    static let hq = district + ["hq"]

    /// District Desk: the tickets THIS workspace's own customers have raised.
    ///
    /// ⛔ THREE UNRELATED FAMILIES SHARE THE WORD `desk` AND ONLY THIS ONE BELONGS
    /// TO THIS CLIENT.
    ///
    ///   - `/api/district/desk/…` — HERE. The tenant's own queue, bearer-authenticated,
    ///     `agency`/`client` only, RLS-scoped to the workspace.
    ///   - `/api/district/support/…` — the MIRROR IMAGE: the tenant raising something
    ///     with DISTRONODE, filed into our Atlassian project. Same auth, opposite
    ///     direction, and its reply field is spelled differently (see ``deskTicketReply(_:)``).
    ///   - `/api/desk/threads/{handle}` — the PUBLIC page a tenant's CUSTOMER opens
    ///     from their notification email. It authenticates with a capability token and
    ///     an HttpOnly cookie rather than a bearer, and it is the only surface that may
    ///     show a stranger a thread. There is no constant for it and no ``EndpointID``
    ///     case, so it is unconstructible from here rather than merely undocumented.
    ///
    /// ⛔ `/api/internal/desk-lookup` AND `/api/internal/desk-ticket` ARE LIKEWISE
    /// ABSENT ON PURPOSE. Those are the voice agent's, behind proxy.ts's internal-key
    /// middleware, and the lookup answers STATUS ONLY because a phone call is
    /// authenticated by caller ID and caller ID is spoofable. Nothing this client
    /// sends carries that key.
    private static let desk = district + ["desk"]

    /// ⛔ ONE PATH, TWO VERBS, AND THE PATCH IS A MERGE RATHER THAN A REPLACE. GET
    /// reads the row; PATCH writes only the keys it is sent and REJECTS an empty body
    /// with a 400 rather than answering a no-op 200. That is the opposite convention
    /// from ``workspaceTools`` and ``workspaceDirectory``, which replace wholesale —
    /// so the obligation those carry (load before you save) does not apply here, and
    /// sending a whole form's state through this route is what WOULD introduce it.
    static let deskSettings = desk + ["settings"]

    /// ⛔ ONE PATH, TWO VERBS, AND THE POST IS THE ONLY MULTIPART CALL ON THIS SURFACE
    /// BESIDES ``messagesMedia`` — with the workspace carried DIFFERENTLY. This route
    /// reads `searchParams.get("workspaceId")`; `messages/media` reads it off
    /// `req.formData()`. Copying the media upload's part list here leaves the query
    /// empty and the request is refused before the bytes are looked at, while the URL
    /// reads perfectly correct. See
    /// ``DistrictEndpoints/uploadDeskLogo(workspaceId:fileName:mimeType:bytes:)``.
    ///
    /// ⚠️ THE DELETE IS ON THE SAME PATH RATHER THAN A `…/delete` SIBLING, which is
    /// the server's own shape: the resource is "this workspace's desk logo" and it has
    /// exactly one of each operation.
    static let deskLogo = desk + ["logo"]

    /// ⛔ ONE PATH, TWO VERBS, AND THE `status` QUERY PARAMETER IS A FILTER ON THE GET
    /// ONLY. An unrecognised value there is IGNORED rather than refused — the route
    /// answers the full queue — so a typo presents as "the filter did nothing" rather
    /// than as an error, which is why the filter is typed at the call site.
    static let deskTickets = desk + ["tickets"]

    /// One ticket and its thread.
    ///
    /// ⚠️ A FUNCTION RATHER THAN A CONSTANT because the id is a path segment, and
    /// ``ApiPath/build(_:)`` encodes each element separately. A ticket id interpolated
    /// into a template is the shape that turned `calls/{id}/transcript` into
    /// `/api/district/admin/transcript` on the Kotlin client.
    static func deskTicket(_ ticketId: String) -> [String] {
        deskTickets + [ticketId]
    }

    /// ⛔ THE ID SITS IN THE MIDDLE OF THE PATH, like ``callAnswer(_:)`` and unlike
    /// every other per-row route here.
    ///
    /// ⛔ AND ITS BODY FIELD IS `message`, WHERE THE SUPPORT DESK'S REPLY TAKES `body`.
    /// Two adjacent surfaces, two spellings, and transposing them is a silent
    /// 400 ("A message is required") from a request that looks entirely reasonable.
    /// The web hit exactly this: its textarea is named `body` in the DOM, which is how
    /// the two came to disagree. See
    /// ``DistrictEndpoints/replyToDeskTicket(workspaceId:ticketId:message:idempotencyKey:)``.
    static func deskTicketReply(_ ticketId: String) -> [String] {
        deskTickets + [ticketId, "reply"]
    }

    /// ⚠️ A **POST**, not a PATCH, even though it changes one field of an existing
    /// row. That is the server's asymmetry rather than a choice available here.
    static func deskTicketStatus(_ ticketId: String) -> [String] {
        deskTickets + [ticketId, "status"]
    }

    /// ⛔ NOT UNDER `district`, AND THE PREFIX IS NOT INTERCHANGEABLE.
    /// `/api/billing` is caller-scoped and predates the district namespace;
    /// `/api/district/billing` does not exist and would 404.
    static let billing = ["api", "billing"]

    /// ⛔ NOT UNDER `district` EITHER. Device management lives under
    /// `/api/auth/native/` — the same family as token exchange and refresh —
    /// because a native session is an AUTH object rather than a district
    /// resource.
    ///
    /// ⚠️ `revoke-all` IS A SIBLING OF `devices`, NOT A CHILD OF IT. The
    /// per-device revoke is `devices/revoke`; the account-wide one is
    /// `revoke-all`, one level up. Inventing `devices/revoke-all` to make them
    /// look like a pair would 404.
    private static let nativeAuth = ["api", "auth", "native"]
    static let nativeDevices = nativeAuth + ["devices"]
    static let nativeDevicesRevoke = nativeDevices + ["revoke"]
    static let nativeRevokeAll = nativeAuth + ["revoke-all"]
}
