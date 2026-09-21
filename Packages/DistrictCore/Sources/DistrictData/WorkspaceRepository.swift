import DistrictModel
import DistrictNetwork
import Foundation

/// Why a workspace list could not be produced.
///
/// ⛔ A TYPE OF ITS OWN BECAUSE "WE COULD NOT LOOK" AND "THERE IS NOTHING" MUST
/// NOT SHARE A REPRESENTATION. `GET /api/district/workspace/list` answers
/// **503 `REGIONS_DEGRADED`** rather than an empty 200 when a region is
/// unreachable, and a client that rendered either as an empty list tells a paying
/// customer their account is gone.
public enum WorkspaceListError: Error, Equatable, Sendable {
    /// At least one region could not be reached. ⚠️ The workspaces in the regions
    /// that DID answer are not returned either — the route refuses to serve a
    /// partial list, because a partial list is indistinguishable from a complete
    /// one once it reaches a screen.
    case regionsDegraded(message: String?, regions: [String])
    case api(ApiError)
}

/// A successful workspace list, and how complete it is.
///
/// ⛔ `degradedRegions` IS ALSO PRESENT ON A **200**, AND THAT IS THE HALF EVERY
/// CLIENT MISSES. A partial list — some regions answered, others did not — is a
/// success carrying a non-empty array, and it is genuinely INCOMPLETE. A client
/// that handled the array only on the 503 path would present a partial account as
/// the whole one, which is the same lie as the empty-list case wearing a green
/// status code.
public struct WorkspaceListPage: Sendable {
    /// The decoded envelope.
    public let response: WorkspaceListResponse

    /// ⚠️ READ OFF ``response``, NOT A SECOND SOURCE. Kept as a stored property
    /// only because the 503 branch carries the same array through a different
    /// type, so both outcomes answer the question the same way.
    public let degradedRegions: [String]

    /// The rows, in the server's own owned-first order.
    ///
    /// ⛔ DO NOT RE-SORT AND THEN TREAT THE NEW FIRST ELEMENT AS THE DEFAULT. The
    /// server has already applied the ordering the browser's switcher uses, and
    /// index 0 is the workspace the browser would consider active; re-sorting
    /// makes the app and the browser disagree about which tenant is in view.
    public var workspaces: [WorkspaceEntry] {
        response.workspaces
    }

    /// ⚠️ CAPTION THE LIST WHEN THIS IS TRUE. Not an error — the rows shown are
    /// real — but they are not all of them.
    public var isPartial: Bool {
        !degradedRegions.isEmpty
    }

    /// ⛔ AN EMPTY LIST WITH A NON-ZERO `inactiveCount` IS A LAPSED ACCOUNT, NOT A
    /// NEW ONE, and it is the only way to tell them apart. The two need different
    /// screens: one says "your subscription is not active", the other offers
    /// onboarding. ⛔ Neither may offer a way to PAY — billing is read-only in
    /// this app (App Store Review Guideline 3.1.3(b)), so the lapsed screen names
    /// the website and stops there.
    public var isBlockedByBilling: Bool {
        response.workspaces.isEmpty && response.inactiveCount > 0
    }

    /// Which workspace to show when the user has expressed no preference.
    ///
    /// ⛔ THE STORED DEFAULT IS AN ID TO LOOK UP, NEVER ONE TO SEND BLIND. The
    /// server echoes `defaultWorkspaceId` verbatim without cross-checking it, so
    /// it can name a workspace whose subscription has since lapsed or one the
    /// user was removed from — and sending that id on the next request earns a
    /// 403 on a screen the user has not touched. Falling back to index 0 is what
    /// the browser does.
    ///
    /// nil only when there are no workspaces at all.
    ///
    /// ⚠️ THE LOOKUP IS DELIBERATELY ONE CONDITION ON ONE LINE, NOT A TWO-CONDITION
    /// `if let`. SwiftFormat's `wrapMultilineStatementBraces` requires the opening
    /// brace of a multi-line condition to sit on its own line; SwiftLint's
    /// `opening_brace` requires it to stay on the same line. The pair is
    /// unsatisfiable for a multi-line `if` — the same standoff the
    /// `trailing_comma` note in `.swiftlint.yml` records — and a single-line
    /// condition is the one shape neither rule objects to.
    ///
    /// ⚠️ MULTI-LINE `guard` IS NOT AFFECTED, which is why it is still used freely
    /// (see `ThreadEvent.event(from:)` and `.cursor(from:)`): its brace attaches
    /// to `else`, so neither rule sees a bare condition followed by a brace. Only
    /// `if` has nothing to hang the brace on. If a multi-line `if` is ever
    /// genuinely needed, configure SwiftLint to yield rather than disabling a
    /// rule, per the `trailing_comma` precedent.
    ///
    /// ⚠️ Comparing a non-optional `id` against an optional `stored` is what makes
    /// the collapse safe: a nil default matches nothing, `first(where:)` returns
    /// nil, and the fallback below runs — exactly the previous behaviour.
    public var defaultSelection: WorkspaceEntry? {
        let stored = response.defaultWorkspaceId
        if let match = response.workspaces.first(where: { $0.id == stored }) {
            return match
        }
        return response.workspaces.first
    }
}

/// Workspaces the signed-in user may operate on, and the roster of one.
public struct WorkspaceRepository: Sendable {
    /// ⚠️ `internal` RATHER THAN `private` SINCE THE PERSONA BATCH, AND THE REASON IS
    /// SwiftLint's 500-LINE `file_length` CEILING RATHER THAN A DESIGN CHANGE. The
    /// persona methods live in `WorkspaceRepository+Persona.swift` because this file
    /// had no room left, and `private` is FILE-private — an extension in another
    /// file cannot reach it. It stays out of the public surface either way, so the
    /// seam this type is (one ``ApiClient``, no transport visible to a screen) is
    /// unchanged.
    let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Every workspace this account belongs to.
    ///
    /// ⚠️ USER-SCOPED: it takes no `workspaceId` and is the one district route
    /// guarded by `requireAuth` rather than `requireWorkspaceRole`. An account
    /// with no workspaces gets a normal empty list, which is a real answer.
    public func list() async -> Result<WorkspaceListPage, WorkspaceListError> {
        // ⛔ `sendUnmapped`, BECAUSE THE FAILURE BODY IS PART OF THE ANSWER HERE.
        // The 503 carries `degradedRegions`, and the normalised ``ApiError`` has
        // nowhere to put an array. This is the only caller of that method.
        switch await client.sendUnmapped(DistrictEndpoints.workspaceList()) {
        case let .success(response):
            guard (200 ... 299).contains(response.statusCode) else {
                return .failure(Self.classify(response))
            }
            // ⚠️ DECODED HERE RATHER THAN THROUGH ``ApiClient/send(_:as:)``,
            // which is what makes this the one typed endpoint that does not go
            // through that method. The status mapping had to be skipped to keep
            // the 503 body readable, so the 2xx decode lands on this side of the
            // branch instead.
            guard let decoded = try? JSONDecoder().decode(WorkspaceListResponse.self, from: response.body) else {
                return .failure(.api(.decoding("WorkspaceListResponse did not decode")))
            }
            switch ResponseEnvelope.affirm("WorkspaceListResponse", decoded.success, decoded) {
            case let .success(affirmed):
                return .success(WorkspaceListPage(
                    response: affirmed,
                    degradedRegions: affirmed.degradedRegions
                ))
            case let .failure(error):
                return .failure(.api(error))
            }
        case let .failure(error):
            return .failure(.api(error))
        }
    }

    /// ⛔ BRANCHES ON THE `code`, NOT ON THE STATUS ALONE. A plain 503 from an
    /// edge proxy is an ordinary outage; this one names which regions were
    /// unreachable and means the answer would have been incomplete. Branching on
    /// the message string instead would break the first time the copy is
    /// rewritten, which happens without a version bump.
    private static func classify(_ response: RawResponse) -> WorkspaceListError {
        let envelope = ApiErrorEnvelope.lenient(response.body)
        guard envelope?.code == ApiErrorCode.regionsDegraded else {
            return .api(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
        let degraded = try? JSONDecoder().decode(WorkspaceListDegradedError.self, from: response.body)
        return .regionsDegraded(message: envelope?.error, regions: degraded?.degradedRegions ?? [])
    }

    /// The roster.
    ///
    /// ⚠️ TYPED, because `MemberListResponse` is one of the nine DTOs that
    /// already exist. ⚠️ Ordered OLDEST FIRST (`createdAt asc`), the opposite of
    /// every other list in this API.
    ///
    /// ⛔ THE ENVELOPE IS AFFIRMED, LIKE EVERY READ IN `DistrictData`. A
    /// non-optional `members` rejects
    /// `{}`, which is what made the omission look harmless; it does nothing at all
    /// about a well-formed `{"success":false,"members":[…]}`, and
    /// ``ResponseEnvelope/affirm(_:_:_:)`` records that this surface answers
    /// exactly that with a **200** whenever a handler falls into its own error
    /// branch after the headers are written.
    ///
    /// ⛔ AND NOTHING DOWNSTREAM COMPENSATED, unlike the `unreadCount` case fixed
    /// the same day. `MembersModel.readRoster` assigns `.ready(response.members)`
    /// with no flag check and the view draws `.ready([])` as an empty roster: a
    /// workspace containing nobody, the person reading the screen included, which
    /// cannot be true, because a real roster always contains at least the person
    /// reading it.
    public func members(workspaceId: String) async -> Result<MemberListResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.members(workspaceId: workspaceId),
            as: MemberListResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MemberListResponse", $0.success, $0) }
    }

    /// Add one member.
    ///
    /// ⛔ AGENCY-ONLY SERVER-SIDE, WHICH IS NARROWER THAN `WorkspaceRole.canMutate`
    /// — that property mirrors the wider `["agency","client"]` allow-list used
    /// everywhere else. Gate this on `.agency` explicitly.
    ///
    /// ⚠️ 409 `member_exists` is not a server fault; branch on
    /// `ApiErrorEnvelope.code`.
    public func addMember(
        workspaceId: String,
        email: String,
        role: WorkspaceRole?
    ) async -> Result<MemberMutationResponse, ApiError> {
        await client.send(
            DistrictEndpoints.addMember(workspaceId: workspaceId, email: email, role: role?.wireValue),
            as: MemberMutationResponse.self
        )
    }

    /// Change one member's role.
    ///
    /// ⚠️ 409 `last_agency_member` when it would demote the last agency member.
    /// "This workspace would have no administrator" is not "you did something
    /// wrong", and the two deserve different sentences.
    public func changeMemberRole(
        workspaceId: String,
        email: String,
        role: WorkspaceRole
    ) async -> Result<MemberMutationResponse, ApiError> {
        await client.send(
            DistrictEndpoints.changeMemberRole(workspaceId: workspaceId, email: email, role: role.wireValue),
            as: MemberMutationResponse.self
        )
    }

    /// Remove one member.
    ///
    /// ⚠️ THE SUCCESS BODY HAS NO `member` KEY. `MemberMutationResponse.member` is
    /// optional precisely so this decodes — it is the one response a client must
    /// not fail on, since the row really is gone.
    public func removeMember(workspaceId: String, email: String) async -> Result<MemberMutationResponse, ApiError> {
        await client.send(
            DistrictEndpoints.removeMember(workspaceId: workspaceId, email: email),
            as: MemberMutationResponse.self
        )
    }

    /// Rename the workspace.
    ///
    /// ⛔ ADOPT THE ECHOED NAME, NOT THE REQUESTED ONE. The server TRIMS before it
    /// measures, so the response carries what a later read will see; adopting the
    /// string that was sent would show a name the database does not hold.
    public func rename(workspaceId: String, name: String) async -> Result<RenameResponse, ApiError> {
        await client.send(
            DistrictEndpoints.renameWorkspace(workspaceId: workspaceId, name: name),
            as: RenameResponse.self
        )
    }

    // MARK: - Workspace settings

    /// The workspace settings row, redacted: the load every mutation form on this
    /// surface has to be built from.
    ///
    /// ⛔ THIS IS THE PROP THE WEB GETS FOR FREE AND A PHONE HAS TO FETCH. The web
    /// settings page is a server component that reads the workspace row during
    /// render and threads it into each form, so every form opens pre-hydrated.
    /// Three of the saves below REPLACE their stored value wholesale, so a native
    /// form that opened empty and saved would not save nothing — it would delete
    /// the agent's tool allowlist, or every dynamic-persona rule the workspace
    /// has. A caller may only build one of those requests on a `.success` from
    /// here.
    ///
    /// ⛔ A `success: true` CARRYING NO `config` IS REPORTED AS DRIFT RATHER THAN
    /// AS AN EMPTY CONFIGURATION, which is the same call ``KnowledgeRepository``
    /// makes for a create that echoes no row and is far more load-bearing here:
    /// answering `.success` with an empty ``WorkspaceConfig`` would hand a form
    /// exactly the blank baseline this whole read exists to prevent. The route
    /// always emits the key, so nil is a contract change and not a state.
    ///
    /// ⛔ IT EXCLUDES `viewer` SERVER-SIDE, unusually for a read on this surface
    /// (`workspace/usage` and `workspace/list` both admit one), because the
    /// payload carries staff transfer numbers and the operator's own prompt. The
    /// entry point must be HIDDEN for a viewer rather than captioned, or they
    /// arrive at a 403 they cannot act on.
    ///
    /// ⚠️ A PLAIN READ WITH NO SIDE EFFECTS AND NO VENDOR CALL, by design: it
    /// cannot itself be the reason a client fails open into an empty form.
    public func config(workspaceId: String) async -> Result<WorkspaceConfig, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.workspaceConfig(workspaceId: workspaceId),
            as: WorkspaceConfigResponse.self
        )
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("WorkspaceConfigResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            guard let config = response.config else {
                return .failure(.decoding("WorkspaceConfigResponse affirmed success with no config"))
            }
            return .success(config)
        case let .failure(error):
            return .failure(error)
        }
    }

    // ⛔ EVERY SAVE ON THIS SURFACE MAY ONLY EVER BE BUILT ON A SUCCESSFUL READ OF
    // ``config(workspaceId:)``, AND THIS LAYER CANNOT ENFORCE THAT, WHICH IS WHY
    // IT IS WRITTEN DOWN HERE. ⚠️ THE PERSONA SAVE MOVED OUT OF THIS FILE INTO
    // `WorkspaceRepository+Persona.swift` WHEN IT GREW FROM FOUR FIELDS TO ELEVEN —
    // SwiftLint's 500-line ceiling, nothing deeper — and the obligation stated here
    // still covers it. `saveTools` and `saveRoutingRules` REPLACE their
    // stored value wholesale rather than merging it, so a form that opened empty
    // and saved would not save nothing: it would delete the agent's tool
    // allowlist, or every dynamic-persona rule the workspace has.
    //
    // ⛔ AND NONE OF THE THREE ECHOES THE CONFIG IT WROTE. There is no body to
    // adopt, so a caller has to RE-READ after every save; without that it would
    // keep rendering its own optimistic edit as though the server had confirmed
    // it, and the NEXT wholesale save would then be built on a client-side belief.
    // ⚠️ The re-read may fail WITHOUT the save having failed, and those two
    // outcomes must not be collapsed: an operator told the save did not land will
    // change the form back and save again, from state that is now stale.
    //
    // ⚠️ THAT READ IS TYPED: ``config(workspaceId:)`` decodes
    // `WorkspaceConfigResponse` and `.workspaceConfig` is a ``TypedEndpoints``
    // case, because a screen has to hydrate a form from it.
    //
    // ⚠️ ALL THREE EXCLUDE `viewer` SERVER-SIDE. So does the config READ, which is
    // unusual on this surface (`workspace/usage` and `workspace/list` both admit
    // viewers) and is because the payload carries staff transfer numbers and the
    // operator's own prompt. The entry point must be HIDDEN for a viewer rather
    // than captioned, or they arrive at a 403 they cannot act on.

    /// Replace the agent's capability allowlist.
    ///
    /// ⛔ `allowedTools` IS WRITTEN WHOLESALE AND IS REQUIRED. Whatever list
    /// arrives becomes the stored one, and a missing array is a **400** rather than
    /// a no-op. The caller's obligation is to send the list it LOADED with the
    /// operator's toggles applied, INCLUDING any id this client's catalog does not
    /// recognise: `transfer_to_creator` was retired in 2026 and workspaces still
    /// store it, so a list rebuilt from a hardcoded catalog would drop it on the
    /// next save.
    ///
    /// ⛔ nil `toolConfig` ON THE READ MEANS "EVERY TOOL IS ON", NOT "NO TOOL IS
    /// ON" (the web reads it as `initialData || AVAILABLE_TOOLS.map(t => t.id)`).
    /// A caller that read the first as the second and saved through here would
    /// switch every capability off for an operator who opened the screen to look
    /// at it. See ``ToolConfig/allowedTools``.
    ///
    /// ⚠️ AN EMPTY LIST IS A LEGITIMATE SAVE and is not refused here: an operator
    /// who wants no tools must be able to say so. The guard is a confirmation in
    /// the UI, not a repository second-guessing a request it was given.
    ///
    /// ⚠️ NOTHING ELSE ON `toolConfig` IS SENT, and that is what leaves it alone.
    /// The other five keys are merged per field AND written when present, so `""`
    /// would CLEAR the calendar id or the sender identity.
    public func saveTools(workspaceId: String, allowedTools: [String]) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.saveTools(workspaceId: workspaceId, allowedTools: allowedTools)
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("ToolsPatchResponse", $0.success, $0) }
            .map { _ in }
    }

    /// Replace the call transfer directory.
    ///
    /// ⛔ THE MOST DESTRUCTIVE CALL IN THIS CLIENT, AND ITS FAILURE MODE IS A 200.
    /// The handler writes `callDirectory: (callDirectory || [])`, so an empty array
    /// — or a body that simply omits the key — WIPES every human the voice agent can
    /// put a live caller through to, and answers `{success:true}`. There is no "save
    /// nothing" on this route, and there is no undo.
    ///
    /// ⛔ SO IT MAY ONLY EVER BE BUILT ON A SUCCESSFUL ``config(workspaceId:)``, AND
    /// THIS LAYER CANNOT ENFORCE THAT. The obligation on the caller is to start from
    /// the array it LOADED, apply the operator's edits, and send the whole thing
    /// back. `SettingsConfigState` is where that rule is expressed on the client:
    /// there is no case for "we could not load, here is an empty form anyway".
    ///
    /// ⛔ AND THE ROWS ARE ``JSONValue`` BECAUSE THEY MUST BE CARRIED WHOLE. The
    /// route's per-entry zod schema is `.passthrough()` and names only `name`,
    /// `phoneNumber` and `type`, while the column is `Json` and holds whatever
    /// anyone ever wrote. A request rebuilt from a typed model would strip every
    /// unmodelled key and answer 200 — a silent deletion inside a row rather than of
    /// one. Start from the loaded object and overwrite the keys the form owns.
    ///
    /// ⛔ `type` IS THE ONE KEY WORTH NAMING HERE: `"app"` makes a transfer RING THE
    /// PHONE instead of dialling a PSTN number, and the route validates it as
    /// `"pstn" | "app"` so anything else is a 400. ⚠️ ABSENT MEANS `"pstn"` AND MUST
    /// NOT BE NORMALISED TO IT ON WRITE — every entry stored today has no `type` key,
    /// every reader already treats an entry as a phone number, and writing the
    /// default in would rewrite every tenant's config to say what it already meant
    /// while making "did an operator CHOOSE pstn?" unanswerable.
    ///
    /// ⚠️ IT ANSWERS A BARE `{success:true}` LIKE ITS THREE SIBLINGS, so a save has
    /// to be followed by a re-read. See the block comment above ``savePersona``.
    ///
    /// ⚠️ IT WAS THE LAST WRITE ON THIS SURFACE WITH NO REPOSITORY METHOD, WHICH IS
    /// WHY THE NATIVE TRANSFER DIRECTORY WAS READ-ONLY. `district-directory-patch.json`
    /// has been gated against ``SuccessResponse`` since the MVP batch and nothing
    /// decoded it; this is that decode, and `.saveDirectory` moves to
    /// ``TypedEndpoints`` with it.
    public func saveDirectory(
        workspaceId: String,
        callDirectory: [JSONValue]
    ) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.saveDirectory(
            workspaceId: workspaceId,
            callDirectory: callDirectory
        )
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DirectoryPatchResponse", $0.success, $0) }
            .map { _ in }
    }

    /// Replace the dynamic-persona routing rules.
    ///
    /// ⛔ **POST, NOT PATCH**, and wholesale like the tool allowlist. An OMITTED
    /// array is a 400 (`Array.isArray` is checked), which the non-optional
    /// parameter makes unreachable; an EMPTY array is accepted and deletes every
    /// rule.
    ///
    /// ⛔ THE ROWS ARE ``JSONValue`` AND MUST BE CARRIED WHOLE. The route's per-rule
    /// zod schema is `.passthrough()` and names only `voice` and `model`, while the
    /// column is `Json` and holds whatever anyone ever wrote: the committed fixture
    /// carries rows shaped `{id, match, action, target}`, which is not the shape
    /// the web's rule builder edits at all. A request rebuilt from a typed model
    /// would strip every unmodelled key and answer 200, which is a silent deletion.
    /// Start from the loaded object and overwrite one key.
    ///
    /// ⚠️ A **400 HERE IS OFTEN A REAL, SPECIFIC REFUSAL** rather than a client
    /// fault: a workspace that restricts voices or models rejects a rule naming one
    /// outside its allow-list, BY NAME. This client cannot see either list and
    /// deliberately does not pre-validate against a guess, so that sentence is
    /// worth showing verbatim.
    ///
    /// ⚠️ ITS FAILURE BODIES CARRY NO `success` KEY (a bare `{error}`), unlike the
    /// two writes above. That costs nothing here, because ``ApiClient/send(_:as:)``
    /// maps on STATUS and the envelope check only ever runs on a 2xx, but it is the
    /// kind of asymmetry that catches a caller parsing an error body by hand.
    public func saveRoutingRules(
        workspaceId: String,
        routingRules: [JSONValue]
    ) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.saveRoutingRules(
            workspaceId: workspaceId,
            routingRules: routingRules
        )
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("RoutingRulesResponse", $0.success, $0) }
            .map { _ in }
    }
}
