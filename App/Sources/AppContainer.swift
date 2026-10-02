import DistrictAuthCore
import DistrictData
import DistrictNetwork
import Foundation
import UIKit

/// The object graph, wired by hand.
///
/// ⛔ EXACTLY ONE ``TokenRefreshCoordinator`` EXISTS PER PROCESS AND IT IS HELD
/// HERE. This is security-load-bearing, not tidiness. The server's refresh
/// rotation is mandatory and single-use: a refresh token presented twice is
/// indistinguishable from a stolen one being replayed, so `rotateNativeSession`
/// revokes the ENTIRE token family and signs the user out on every device in the
/// chain, logging `[auth] Native refresh replay detected`. The coordinator's
/// single-flight gate is what stops two concurrent 401s both refreshing with the
/// same token — and a SECOND coordinator would mean a second gate, each unaware
/// of the other, which is that failure mode with the guard present and useless.
/// ⚠️ So there is no factory method here, no `static let shared`, and no second
/// construction site: the app builds one of these in `DistrictApp` and passes it
/// down. The Kotlin client makes the identical call in its own `AppContainer`.
///
/// ⚠️ `@MainActor` BECAUSE THE UI OWNS IT, NOT BECAUSE THE WORK IS. Everything
/// underneath is an actor or a `Sendable` value, so a feature that needs
/// ``api`` off the main actor can copy it — `ApiClient` is a struct.
@MainActor
final class AppContainer {
    /// The single coordinator. See the ⛔ on the type.
    let coordinator: TokenRefreshCoordinator

    /// The authenticated API client, with the session bearer wired.
    let api: ApiClient

    /// The login flow. Holds the PKCE verifier for one attempt, in memory.
    let login: WebAuthLoginController

    /// The Guideline 4.8 door. Holds one attempt's nonce, in memory.
    /// ⚠️ A SIBLING OF ``login``, NOT A REPLACEMENT: both end at the same
    /// ``coordinator`` and answer the same `LoginOutcome`. See the type.
    let appleLogin: AppleSignInController

    /// This installation's opaque id, as sent on token exchange.
    let deviceId: String

    /// The one origin this client talks to.
    ///
    /// ⛔ EXPOSED SO A HAND-OFF INTO THE WEB DASHBOARD IS DERIVED RATHER THAN
    /// HARDCODED. The marketplace's "open this on the web" link is the first of these
    /// and the Kotlin client states the rule on its own `marketplaceWebUrl`: a build
    /// pointed at a staging host must hand off to THAT host's dashboard rather than
    /// sending the operator to production to spend money. A literal in a feature file
    /// would silently do the second.
    ///
    /// ⚠️ IT IS THE VALUE THIS CONTAINER WAS BUILT WITH, not a second copy of the
    /// default. ``ApiClient`` and ``SchedulingSSOClient`` already take it by value;
    /// this is the same URL, kept so a screen can name a page rather than a route.
    /// ⛔ It is NOT a credential and nothing may authenticate against it: a page
    /// opened from here is opened in the user's own browser session, which this app
    /// neither holds nor may supply. See ``SafariView``.
    let baseURL: URL

    // ── Repositories ─────────────────────────────────────────────────────────
    //
    // ⚠️ `let`s ON THE CONTAINER, CONSTRUCTED ONCE, AND NEVER BUILT AT A CALL SITE.
    // Each is a `struct` wrapping the single ``ApiClient``, so one per feature would
    // cost nothing in memory and would still be wrong: the client carries the two
    // credential closures, and a repository built from a second `ApiClient` would
    // reach a second `TokenRefreshCoordinator`. Threading the container is what keeps
    // that impossible to write by accident.
    //
    // ⚠️ CONSTRUCTED IN `init` AFTER `api`, because they take it by value.

    /// Workspaces this account may operate on, and the roster of one.
    let workspaces: WorkspaceRepository

    /// Who answers a call, and whether THIS person can be rung for one.
    ///
    /// ⛔ NOT PART OF ``workspaces`` DESPITE THE SHARED PATH PREFIX: the seam is the SCOPE.
    /// `workspace/availability` writes the CALLER'S OWN membership row and takes no identity
    /// to do it with. See the ⛔ on ``CallHandlingRepository``.
    let callHandling: CallHandlingRepository

    /// The overview, and the EFFECTIVE role for the caller.
    let overview: OverviewRepository

    let calls: CallsRepository

    let contacts: ContactsRepository

    /// Who this account has blocked.
    ///
    /// ⛔ THE ONLY MUTABLE OBSERVABLE ON THIS CONTAINER, AND IT IS HERE RATHER THAN IN
    /// AN `@Environment` BECAUSE FOUR SCREENS IN THREE TABS READ IT. Guideline 1.2
    /// asks that blocking a caller take their content out of view immediately; the
    /// screen that performs the block (a thread) and the one that must stop showing it
    /// (the inbox list) hold different models. ⚠️ A cache, not an authority. See the
    /// type.
    let blockedContacts: BlockedContactsStore

    let inbox: InboxRepository

    /// The account's signed-in installs, and the two ways to end one.
    ///
    /// ⚠️ ACCOUNT-SCOPED, NOT WORKSPACE-SCOPED, unlike the five above it. A
    /// native session belongs to a USER and a device belongs to a person across
    /// every workspace they hold, so nothing here takes a `workspaceId` and the
    /// Devices screen stays reachable when no workspace resolves at all.
    let devices: DevicesRepository

    /// This installation's push registration, and the memory behind it.
    ///
    /// ⚠️ ACCOUNT-SCOPED LIKE ``devices``, AND A DIFFERENT SURFACE FROM IT DESPITE
    /// THE NAME. ``devices`` is `/api/auth/native/devices/…`, session management on
    /// a public proxy prefix; this is `/api/district/devices/…`, push registration
    /// behind the default-deny middleware. The two 404 each other.
    ///
    /// ⚠️ THE ONLY REPOSITORY HERE THAT TAKES SOMETHING BESIDES ``api``. Its
    /// ``PushTokenMemory`` is `UserDefaults`-backed and lives in `App/`, because
    /// `DistrictData` cannot see a store; every decision taken FROM that value is
    /// in the repository, on the tier with tests.
    let pushTokens: PushTokenRepository

    /// The analytics window and the two metered-usage reads.
    ///
    /// ⚠️ ONE REPOSITORY FOR THREE READS THAT FAIL INDEPENDENTLY, which is a
    /// property of its SIGNATURES rather than of its shape: each method answers its
    /// own `Result`, so the screen can hold a usage failure inside one card while
    /// the analytics figures stay up. See ``AnalyticsRepository``.
    let analytics: AnalyticsRepository

    /// The workspace's booking pages: the tenancy's state, and the one call that
    /// provisions one.
    let scheduling: SchedulingRepository

    /// The seventy-five catalogued scheduling admin operations.
    ///
    /// ⛔ A SEPARATE REPOSITORY FROM ``scheduling`` EVEN THOUGH BOTH ARE "SCHEDULING",
    /// AND THE SPLIT IS THE SERVER'S. ``scheduling`` talks to District's own
    /// `scheduling/status` and `scheduling/enable` — is there a tenancy, make one — while
    /// this one posts an `op` NAME to `scheduling/admin`, which proxies into the
    /// scheduler's own API through an allowlist. They have different routes, different
    /// failure vocabularies (``ApiError`` against ``SchedulingAdminError``) and different
    /// role rules. Folding them would give one type two error models.
    ///
    /// ⚠️ IT TAKES NO `reportUnknownOp`, WHICH MEANS IT TRAPS IN A DEBUG BUILD. That is
    /// the default and it is right here: a **400 `unknown_op`** means
    /// ``SchedulingAdminOp`` and the server's `ADMIN_OPS` have diverged, which is a
    /// programmer error nothing a user does can cause and nothing they can act on. See
    /// the ⛔ on ``SchedulingAdminRepository/init(client:reportUnknownOp:)``.
    let schedulingAdmin: SchedulingAdminRepository

    /// Recording downloads, and the image uploads the write stage will need.
    ///
    /// ⛔ ITS OWN TYPE BECAUSE ITS TWO CALLS ARE NOT `op` POSTS. A download is a **302**
    /// whose `Location` is a presigned URL, and an upload is `multipart/form-data`;
    /// neither fits `perform(_:workspaceId:params:as:)`, which posts JSON and decodes an
    /// envelope. ⚠️ It shares the one ``ApiClient`` with everything else, so the redirect
    /// policy and the token refresh are the same ones.
    let schedulingAdminMedia: SchedulingAdminMediaRepository

    /// The hand-off into the scheduler's own admin.
    ///
    /// ⛔ NOT A REPOSITORY, AND NOT BUILT ON ``api``, BECAUSE ITS ROUTE ANSWERS A
    /// 302 RATHER THAN A JSON BODY. `GET /api/district/scheduling/sso` is fetched
    /// with redirects DISABLED and its `Location` handed to a browser sheet;
    /// following it here would spend a single-use, 60-second credential on a
    /// transport the user never sees. `DistrictNetwork` deliberately does not
    /// carry the endpoint — see the ⛔ at the top of
    /// `DistrictEndpoints+Scheduling.swift` — so this is the App-side half of that
    /// decision.
    ///
    /// ⚠️ IT SHARES THE ONE ``URLSessionHTTPTransport`` AND THE ONE
    /// ``TokenRefreshCoordinator`` with ``api``, which is the property that
    /// matters: a second transport would be a second redirect policy and a second
    /// coordinator would be a second single-flight gate.
    let schedulingSSO: SchedulingSSOClient

    /// Minting the hand-off URL that replaced the retired scheduler console.
    ///
    /// ⚠️ BUILT ON ``api``, UNLIKE ``schedulingSSO``. The SSO route answers a 302 and
    /// needs redirects DISABLED, which is why that one carries its own transport; this
    /// one answers ordinary JSON and belongs on the ordinary client.
    let schedulingHandoff: SchedulingHandoffClient

    /// Placing one outbound call. ⛔ Never retried; see the ⛔ on the type.
    let dial: DialRepository

    /// Answering one inbound call.
    ///
    /// ⛔ A SEPARATE REPOSITORY FROM ``dial`` EVEN THOUGH BOTH END IN A LiveKit
    /// CREDENTIAL, AND THE SPLIT IS THE SERVER'S OWN. Keeping them apart means a
    /// screen that answers cannot dial and a screen that dials cannot answer; the
    /// reasoning is on ``InboundCallRepository``.
    let inboundCalls: InboundCallRepository

    /// The workspace knowledge base: what the agent may answer FROM, and where.
    ///
    /// ⛔ ITS OWN REPOSITORY RATHER THAN MORE ``workspaces``, AND THE ROLE CONTRACT
    /// IS THE REASON. Every workspace-settings call excludes `viewer` server-side
    /// INCLUDING the config read; here the READS admit one and only the writes
    /// exclude them. One repository whose calls disagree about who may make them is
    /// how a UI gate ends up derived from the wrong rule.
    let knowledge: KnowledgeRepository

    /// The workspace's outbound carrier accounts: one read, five writes on one path,
    /// and a credential probe on a sibling.
    ///
    /// ⛔ SAME SPLIT, SAME REASON, AS ``knowledge``: the read admits a viewer and
    /// every write excludes one. ⛔ And nothing here may be retried — a save with no
    /// `accountId` mints a fresh account inside the transaction, and the probe makes
    /// a live authenticated call to a third party per request.
    let messaging: MessagingRepository

    /// The platform half of a call: CallKit, the audio session, and the engine for
    /// the call in progress.
    ///
    /// ⛔ ONE PER PROCESS, FOR THE SAME CLASS OF REASON AS ``coordinator``, and
    /// ``CallStack``'s own ⛔ carries the detail: `CXProvider` is
    /// one per app by Apple's rule, so a second one puts a duplicate entry in the
    /// system's own call surfaces and leaks the first. The engine underneath it is
    /// one per CALL and is built and dropped by ``CallStack/beginCall()`` and
    /// ``CallStack/endCall()``; the two lifetimes are why that type exists rather
    /// than a constructor at a call site.
    ///
    /// ⚠️ IT IS ALSO WHAT KEEPS THE DIALER'S MODEL ALIVE ACROSS A POP. The model
    /// installs itself as ``CallStack/onSystemRequest`` for the length of one call,
    /// so a screen dismissed mid-call leaves the call running under CallKit with an
    /// owner still driving it, and the claim is dropped on every terminal path. See
    /// the ⛔ on ``DialerModel``.
    ///
    /// ⚠️ NAMED `callStack` RATHER THAN `calls`, WHICH IS TAKEN by the call-log
    /// repository above. They are unrelated: one reads rows, this one holds a live
    /// telephone call.
    let callStack: CallStack

    /// District HQ: one turn of the console, and the write it proposes.
    ///
    /// ⛔ ITS `confirm` IS THE ONE REPOSITORY CALL ON THIS CONTAINER THAT EXECUTES AN
    /// ARBITRARY WRITE (a persona change, a deletion, a routing replacement, a real
    /// email or SMS to a customer). Nothing may retry it and nothing may call it with
    /// an assembled proposal; the signature takes an ``HqPendingWrite`` that can only
    /// have come out of a prompt response, which is what makes the two-step honest.
    let hq: HQRepository

    /// The meetings archive: the workspace's rooms history and one meeting's record.
    ///
    /// ⚠️ READS ONLY, AND THE SPLIT FROM ``rooms`` BELOW IS THAT TYPE'S OWN ⛔. Neither
    /// route here carries a `success` envelope and neither mints anything.
    let meetings: MeetingsRepository

    /// The credential that joins one `meet_` room.
    ///
    /// ⛔ A SEPARATE REPOSITORY FROM ``meetings`` BECAUSE ``MeetingsRepository`` SAYS SO
    /// IN ITS OWN ⛔: joining is a capability, not a read, and it does not belong on the
    /// type that reads the archive. Every call mints a fresh twelve-hour guest invite
    /// that grants publish rights to whoever holds it, so the surface that can hand one
    /// out is one file rather than a method on a reader.
    let rooms: RoomsRepository

    /// The automation monitor: the workflow list, one workflow's runs, and the
    /// always-on SDR campaign.
    ///
    /// ⚠️ FOUR ROUTES THAT FAIL INDEPENDENTLY, like ``analytics`` and for the same
    /// reason: each method answers its own `Result`, so a campaign read that failed
    /// cannot blank a workflow list that answered.
    let workflows: WorkflowsRepository

    /// The phone-number marketplace: the carrier's inventory, and the lines this
    /// workspace already has.
    ///
    /// ⛔ READ ONLY, AND THE TYPE HAS NO WRITE METHOD TO CALL. Purchase, release and
    /// configure routes exist server-side and are deliberately not modelled: buying a
    /// number creates a recurring carrier charge, releasing one takes a live line out
    /// of service, and a released number cannot be reclaimed. The app lists, the web
    /// installs. See the ⛔ on ``NumbersRepository``.
    ///
    /// ⚠️ TWO UNRELATED ROUTES BEHIND ONE SCREEN THAT FAIL SEPARATELY, like
    /// ``analytics`` and ``workflows``: each method answers its own `Result`, so a
    /// carrier inventory search that failed cannot blank an owned-number list that
    /// answered.
    let numbers: NumbersRepository

    /// The plan we own, and the invoices Stripe owns.
    ///
    /// ⛔ TWO READS THAT FAIL INDEPENDENTLY, like ``analytics`` and ``workflows``, and here
    /// the independence is availability rather than tidiness: one read touches our own
    /// columns and the other touches a third party, so the common failure is one-sided by
    /// construction. See ``BillingRepository``.
    ///
    /// ⛔ IT HAS NO WRITES AND MUST NOT GAIN ANY. `POST /api/billing` cancels
    /// subscriptions, changes plans and detaches cards; offering any of that in-app
    /// breaches App Store Review Guideline 3.1.3(b), and so would surfacing a portal URL
    /// for a screen to open.
    let billing: BillingRepository

    /// This workspace's own support requests **with Distronode**.
    ///
    /// ⛔ NOT ``desk``, AND THE TWO MUST NEVER BE REACHED FOR INTERCHANGEABLY. This is
    /// the tenant writing to US (`district/support/*`); ``desk`` is the tenant's own
    /// customers writing to THEM (`district/desk/*`). They share every noun — requests,
    /// threads, replies, a close — and differ by one path segment, so the property names
    /// are most of what separates them at a call site.
    ///
    /// ⚠️ THE REPLY FIELD DIFFERS TOO AND IT IS A SILENT 400: support replies take
    /// `body`, desk replies take `message`. Both are pinned byte-exact in
    /// `EndpointTableTests`.
    let support: SupportRepository

    /// District Desk: the tenant's OWN customers' ticket queue.
    ///
    /// ⛔ NOT ``support``. See the ⛔ above; the direction is reversed.
    ///
    /// ⚠️ `deskEnabled` is `Bool?` and **null is not false** — it means the question
    /// could not be asked. Three states, three screens; rendering null as "off" tells a
    /// tenant their desk is disabled when the read merely failed.
    let desk: DeskRepository

    private let store: any TokenStore

    /// The single sign-out orchestrator. See the ⛔ on the type: it owns the
    /// order of the sign-out steps and the revoke outbox that survives a 503.
    let signOutCoordinator: SignOutCoordinator

    /// - Parameter microphone: the permission ``callStack`` asks through. ⚠️ A PARAMETER RATHER THAN A
    ///   SEAM RESOLVED INSIDE, because this initialiser is against `function_body_length`'s 60 and a
    ///   parameter costs its body nothing. Only a test passes one.
    init(baseURL: URL = ApiClient.productionBaseURL, microphone: any MicrophoneAccess = LiveMicrophoneAccess()) {
        let transport = URLSessionHTTPTransport()
        // ⛔ THE TOKEN STORE IS RESOLVED, NOT CONSTRUCTED HERE. See ``AppContainerSeam``.
        let seam = AppContainerSeam.resolve(baseURL: baseURL)
        let store = seam.store
        let deviceId = seam.deviceId
        let baseURL = seam.baseURL
        let auth = AppNativeAuthClient(baseURL: baseURL, transport: transport)
        // ⚠️ `auth` AS THE REVOKE CLIENT TOO, so a successor that lands after a sign-out
        // is revoked at once rather than waiting in the outbox for the next launch.
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: auth, revokeClient: auth)

        // ⚠️ Locals first, then the stored properties, because the two closures
        // below capture the VALUES rather than `self` — a container that
        // captured itself in its own client would be a retain cycle holding the
        // only token store in the process.
        self.store = store
        self.coordinator = coordinator
        self.deviceId = deviceId
        self.baseURL = baseURL

        // ⚠️ AFTER THE COORDINATOR EXISTS, never before. A no-op in Release.
        seam.adopt(coordinator)

        // ⚠️ THE SAME `store`, `coordinator` AND `auth` INSTANCES, NOT NEW ONES.
        // A sign-out that revoked through a second client would still work; one
        // that wiped a second coordinator would leave the real one holding a
        // live access token after the user signed out.
        // ⚠️ ON ONE LINE BECAUSE A WRAPPED CALL COSTS A LINE PER ARGUMENT and this
        // initialiser is against `function_body_length`'s 60. 106 chars, inside `--maxwidth 120`.
        signOutCoordinator = SignOutCoordinator(coordinator: coordinator, store: store, revokeClient: auth)

        // ⛔ THE BEARER IS SUPPLIED THROUGH AN ASYNC CLOSURE, NOT AN INTERCEPTOR.
        // Acquiring a token may mean waiting behind the coordinator's
        // single-flight refresh, which is asynchronous; the Kotlin client paid
        // for that lesson with an OkHttp interceptor that had to `runBlocking`
        // on a dispatcher thread the refresh itself needed.
        //
        // ⚠️ EVERY NON-`available` OUTCOME BECOMES nil, AND `ApiClient` TURNS nil
        // INTO A LOCAL 401 rather than sending an unauthenticated request. The
        // DISTINCTION between "signed out" and "could not check" is not lost —
        // it is the UI's job to ask the coordinator directly (see
        // `SessionModel`), because a request-path closure has nowhere to put
        // it.
        api = ApiClient(
            baseURL: baseURL,
            transport: transport,
            accessToken: Self.bearer(coordinator),
            rejectedToken: Self.rejected(coordinator)
        )

        // ⚠️ EVERY ONE OF THEM SHARES THE ONE `api` ABOVE, which is the point. See
        // the ⚠️ on the stored properties. (Stated without a count on purpose: the
        // number changes with every feature and a count in a comment goes stale.)
        workspaces = WorkspaceRepository(client: api)
        callHandling = CallHandlingRepository(client: api)
        overview = OverviewRepository(client: api)
        calls = CallsRepository(client: api)
        contacts = ContactsRepository(client: api)
        // ⚠️ FROM THE ONE `contacts` ABOVE, never a fresh repository. Same rule as
        // every other line here; see the ⚠️ on the stored properties.
        blockedContacts = BlockedContactsStore(contacts: contacts)
        inbox = InboxRepository(client: api)
        devices = DevicesRepository(client: api)
        pushTokens = PushTokenRepository(client: api, memory: UserDefaultsPushTokenMemory())

        analytics = AnalyticsRepository(client: api)
        scheduling = SchedulingRepository(client: api)
        // ⛔ AN UNKNOWN OP IS A PROGRAMMER ERROR: THE CLIENT'S CATALOGUE AND THE
        // SERVER'S HAVE DIVERGED. It traps in a debug build so whoever caused it
        // finds it, and does nothing in release, where the screen shows the generic
        // sentence instead. The package takes this as a required argument; see its
        // initialiser.
        schedulingAdmin = SchedulingAdminRepository(client: api) { op in
            assertionFailure("The server does not know the scheduling admin op '\(op.rawValue)'.")
        }
        schedulingAdminMedia = SchedulingAdminMediaRepository(client: api)
        schedulingHandoff = SchedulingHandoffClient(client: api)

        // ⚠️ THE SAME `transport` AND THE SAME `coordinator` AS `api` ABOVE, and
        // the bearer closure is the same shape for the same reason: acquiring a
        // token may mean waiting behind the coordinator's single-flight refresh,
        // which is asynchronous. See the ⛔ on `api`.
        schedulingSSO = SchedulingSSOClient(
            baseURL: baseURL,
            transport: transport,
            accessToken: Self.bearer(coordinator)
        )

        knowledge = KnowledgeRepository(client: api)
        messaging = MessagingRepository(client: api)

        dial = DialRepository(client: api)
        inboundCalls = InboundCallRepository(client: api)

        meetings = MeetingsRepository(client: api)
        rooms = RoomsRepository(client: api)

        hq = HQRepository(client: api)
        workflows = WorkflowsRepository(client: api)
        numbers = NumbersRepository(client: api)

        billing = BillingRepository(client: api)
        support = SupportRepository(client: api)
        desk = DeskRepository(client: api)

        // ⚠️ THE ONE THING HERE THAT IS NOT BUILT FROM `api`, because it holds no
        // credential and makes no request: it is CallKit plus the device's audio
        // session. It is cheap to construct (a `CXProvider` and a coordinator) and
        // it registers nothing with the OS until a call is started or reported.
        callStack = CallStack(microphone: microphone)

        // ⚠️ THROUGH A STATIC HELPER RATHER THAN INLINE, AND ONLY BECAUSE OF THE LINE
        // BUDGET. See `AppContainerCredentials.swift`: a wrapped call costs a line per
        // argument, and this initialiser is against `function_body_length`'s 60.
        login = Self.loginController(baseURL: baseURL, auth: auth, coordinator: coordinator, deviceId: deviceId)
        appleLogin = Self.appleController(auth: auth, coordinator: coordinator, deviceId: deviceId)
    }
}
