import Foundation

/// `GET /api/district/workspace/config?workspaceId=` — the read a native
/// mutation form must hydrate from BEFORE it is allowed to save.
///
/// ⛔ WHY THIS ROUTE EXISTS AT ALL, BECAUSE IT EXPLAINS EVERY DECISION BELOW. The
/// web settings page is a server component: it reads the workspace row during
/// render and threads it into each form as props, so every form opens
/// pre-hydrated. A phone has no SSR and no such prop, and three of the save
/// routes it must reach are WHOLESALE REPLACE rather than merge —
/// `workspace/directory` writes `callDirectory: callDirectory || []`,
/// `workspace/routing-rules` replaces the whole array, and `workspace/tools`
/// replaces `toolConfig.allowedTools`. A form that opened empty and saved would
/// not "save nothing": it would DELETE the transfer directory the voice agent
/// routes live callers through, or the agent's tool allowlist. So a save is only
/// ever built on top of a SUCCESSFUL load of this.
///
/// ⛔ AND THE ROLE GATE IS NARROWER THAN ITS SIBLINGS. Every other read on this
/// surface (`workspace/usage`, `workspace/list`) admits `viewer`; this one
/// answers 403, because ``WorkspaceConfig/callDirectory`` is the list of staff
/// PHONE NUMBERS the agent transfers live callers to. A viewer has no mutation
/// form to hydrate, so admitting them would hand out internal numbers for no
/// functional gain.
public struct WorkspaceConfigResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ OPTIONAL ONLY BECAUSE A MALFORMED RESPONSE MUST NOT CRASH THE SCREEN.
    /// The route always emits it, so nil here is contract drift rather than a
    /// state — and the right handling is to report a load failure, never to hand
    /// a form an empty config to save from, which is the exact failure this
    /// whole read prevents.
    public let config: WorkspaceConfig?
}

/// The workspace settings row, redacted.
///
/// ⛔ THE KEY SET IS IDENTICAL WHETHER THE WORKSPACE IS CONFIGURED OR BRAND NEW,
/// AND THAT IS WHY THIS SURFACE NEEDED SO MANY ALLOWLIST ENTRIES. The route
/// NULLS a missing optional rather than dropping the key, so
/// `district-workspace-config-sparse.json` carries seven explicit nulls where
/// the configured fixture carries values. Both branches are gated.
///
/// ⛔ NULL AND EMPTY ARE DIFFERENT ANSWERS HERE AND CONFLATING THEM IS
/// DESTRUCTIVE. A nil ``toolConfig`` means "never configured", which the web
/// reads as EVERY TOOL ON (`initialData || AVAILABLE_TOOLS.map(t => t.id)`); an
/// empty ``ToolConfig/allowedTools`` means "explicitly none". Through a route
/// that replaces the array wholesale, a client that read the first as the second
/// would switch every capability off for an operator who opened the screen to
/// look at it.
///
/// ⚠️ FOUR FIELDS ARE OPAQUE ``WireJSON`` AND THEY STAY THAT WAY. `routingRules`
/// holds two different row shapes in one array today; both it and `callDirectory`
/// are written by routes that validate with a zod `.passthrough()`, so a typed
/// model would drop every unmodelled key on a round trip through a route that
/// writes back exactly what it receives. `messagingConfig` and `campaignSettings`
/// have no native form at all. Opaque means "carried, never rewritten", which is
/// the only safe state for a value whose key set nothing bounds.
public struct WorkspaceConfig: Codable, Sendable {
    /// nil for a workspace nobody has configured.
    public let aiPersona: AiPersona?
    /// ⚠️ nil means NEVER CONFIGURED, which is not an empty allowlist. See the
    /// ⛔ on the type.
    public let toolConfig: ToolConfig?
    /// ⛔ Replaced wholesale by `workspace/routing-rules`. Opaque.
    public let routingRules: WireJSON?
    /// ⛔ Replaced wholesale by `workspace/directory`. Staff numbers. Opaque.
    public let callDirectory: WireJSON?
    /// ⚠️ Opaque and read-only — already narrowed server-side by
    /// `redactWorkspaceSecrets`.
    public let messagingConfig: WireJSON?
    /// ⚠️ Opaque and read-only. No native form edits campaign settings.
    public let campaignSettings: WireJSON?
    /// ⚠️ A COLUMN, NOT A `toolConfig` KEY, even though `workspace/tools` PATCH
    /// is what writes it. Carried for display only.
    public let creatorCellNumber: String?
    public let plan: String?
    /// ⛔ MIXED CASE, LIKE ``WorkspaceEntry/subscriptionTier``. Lowercase before
    /// comparing.
    public let subscriptionTier: String?
    /// ⚠️ An ISO-8601 STRING. This module owns no date parsing.
    public let updatedAt: String?
}

/// `Workspace.aiPersona` — what the voice agent renders into every system
/// prompt.
///
/// ⛔ EVERY FIELD IS MODELLED, AND THE SPLIT THAT MATTERS IS NO LONGER "four
/// editable, the rest read-only". `PATCH workspace/persona` merges per field
/// (`x !== undefined ? x : existing`), so an omitted key is preserved and the
/// safe native form sends ONLY what the operator actually changed. What decides
/// whether a field may be OFFERED is where its value comes from:
///
///   * ✏️ FREE TEXT — ``name``, ``greeting``, ``personality``, plus the
///     ``dgiEnabled`` consent flag. Stored verbatim, no vocabulary behind them.
///   * 🎛️ DRAWN FROM A SERVER-SIDE VOCABULARY — ``voice``, ``language``,
///     ``modelId``, ``responseLength``, ``temperature``, ``voiceStyle`` and
///     ``preemptiveTts``. Every one of them COERCES rather than rejects: an
///     unrecognised `modelId` is silently rewritten to `deepgram-pipeline`, an
///     unrecognised `voice` is stored verbatim and the agent then speaks in a
///     voice nobody chose, and a `responseLength` without a `modelId` is
///     discarded — all with a 200 and no error anywhere.
///   * 🔒 NOT WRITTEN BY ANY NATIVE CLIENT — the avatar block below.
///
/// ⛔ THE MIDDLE GROUP IS EDITABLE THROUGH PICKERS FED BY THE SERVER. The hazard is
/// not "a phone edits these"; it is "a client offers a value nothing checked", which free text and a hardcoded Swift
/// list do equally. `GET workspace/persona/options` publishes exactly the
/// catalogue the web derives its own pickers from, so a native form can offer the
/// same values and a failed read leaves the controls showing what is stored —
/// never a built-in list, which would be the drifting second copy the route
/// exists to retire.
///
/// They are all MODELLED rather than dropped because the strict gate compares key
/// sets: "the phone leaves the AVATAR alone" is checkable here rather than being
/// a claim about code nobody reads.
public struct AiPersona: Codable, Sendable {
    /// ✏️ Editable. Free text, no server-side vocabulary.
    public let name: String?
    /// ✏️ Editable. The agent's opening line.
    public let greeting: String?
    /// ✏️ Editable. Rendered into the system prompt.
    public let personality: String?
    /// ✏️ Editable — the external-lead-enrichment opt-in the published
    /// sub-processor list promises is OFF by default.
    ///
    /// ⛔ ONLY AN EXPLICIT BOOLEAN CHANGES IT SERVER-SIDE; a non-boolean is
    /// IGNORED rather than coerced, and still answers 200. ⚠️ nil is NOT
    /// `false`: it means the workspace has never answered, which renders as off
    /// but must not be SENT as false unless the operator actually toggled it.
    public let dgiEnabled: Bool?
    /// 🎛️ Chosen from `persona/options`. A pipeline-registry voice id, stored
    /// verbatim when it is unknown and then replaced by the agent at synthesis time.
    public let voice: String?
    /// 🎛️ Chosen from `persona/options`, whose two lists are NOT subsets of each
    /// other; engine-constrained (nova-3 carries only en-US and es-ES).
    public let language: String?
    /// 🎛️ Chosen from `persona/options`. Selects the CALL BRAIN, and an unknown
    /// value coerces silently — which is why no client may offer a list of its own.
    public let modelId: String?
    /// 🎛️ Per-ENGINE spoken-turn length, keyed by ``modelId``. ⛔ The route only
    /// writes it when BOTH arrive together and both are valid, so a client sends
    /// the pair or neither; sending one without the other writes nothing and
    /// answers 200, and sending a mismatched pair silently retunes the wrong
    /// engine.
    public let responseLength: [String: String]?
    /// 🎛️ Clamped to 0...1 server-side; its starting value is published by
    /// `persona/options` rather than restated by a client.
    public let temperature: Double?
    /// 🎛️ Chosen from `persona/options`. Capped at 100 characters server-side, and
    /// read by the realtime engine only — the chained pipelines store and ignore it.
    public let voiceStyle: String?
    /// 🎛️ Paid speculative synthesis, and meaningless to the realtime engine. ⛔ The
    /// agent reads it as `bool(...)`, so only a real boolean may ever be sent.
    public let preemptiveTts: Bool?
    /// 🔒 The avatar form's territory, and the one group no native client writes.
    /// ⛔ Turning video on starts a billable Tavus stream, which App Store Review
    /// Guideline 3.1.3(b) and this module both decline; the phone shows it as a
    /// STATUS.
    public let videoEnabled: Bool?
    /// 🔒 Read-only: `inherit`, or the realtime id that turns vision on.
    public let videoModelId: String?
    /// 🔒 Read-only: a Tavus face id, validated against the gallery server-side.
    public let replicaId: String?
    /// 🔒 Read-only, and ⛔ REGION-KEYED SERVER-SIDE: an EU workspace gets the
    /// disclosure PAL (EU AI Act). An explicit value in a request body still
    /// wins, which is precisely why no client of ours ever sends one.
    public let personaId: String?
    /// 🔒 Read-only.
    public let videoVoice: String?
    /// 🔒 Read-only.
    public let videoResolution: String?
    /// 🔒 Read-only.
    public let videoBackgroundUrl: String?
    /// 🔒 Read-only.
    public let videoRecording: Bool?
}

/// `Workspace.toolConfig` — what the agent may DO on a call, and the accounts it
/// does it through.
///
/// ⛔ ``allowedTools`` IS THE ONE FIELD ON THIS WHOLE SURFACE WRITTEN WHOLESALE.
/// Every other key here is merged per field by `PATCH workspace/tools`, so
/// omitting it preserves it — but `allowedTools` is set to exactly what arrived,
/// and omitting it is a 400 rather than a no-op. That asymmetry is why this is a
/// DTO rather than another opaque blob: the loaded list has to be carried back
/// with its ORDER AND CONTENT intact.
public struct ToolConfig: Codable, Sendable {
    /// ⛔ nil MEANS ABSENT, WHICH MEANS "EVERY TOOL IS ON", NOT "NO TOOL IS ON".
    /// The web form reads it as `initialData || AVAILABLE_TOOLS.map(t => t.id)`,
    /// so a brand-new workspace has every capability enabled without ever having
    /// stored a list. Reading nil as an empty allowlist and saving through the
    /// wholesale-replace route would switch the agent off entirely for an
    /// operator who opened the screen to look at it. ⚠️ And an empty list is a
    /// real, different answer: the operator turned everything off on purpose.
    public let allowedTools: [String]?
    /// ⚠️ Read-only here — merged server-side, so an omitted key preserves it.
    /// ⛔ Sending `""` would CLEAR it, which is why nothing here sends it.
    public let calendarId: String?
    /// ⚠️ Read-only. `google` or `microsoft` server-side; free text on the wire.
    public let calendarProvider: String?
    /// ⚠️ Read-only, and displayed: it is the observable prerequisite for the
    /// `transfer_to_agent` capability.
    public let supportPhoneNumber: String?
    /// ⚠️ Read-only. Same clearing hazard as ``calendarId``.
    public let customEmailDomain: String?
    /// ⚠️ Read-only. Same clearing hazard.
    public let customEmailSenderName: String?
}

// ⛔ THERE IS NO `WorkspaceConfigSaveResponse` HERE, AND THAT IS THE ANSWER
// RATHER THAN AN OMISSION. All four workspace-settings writes (`workspace/persona`
// PATCH, `workspace/tools` PATCH, `workspace/directory` PATCH and
// `workspace/routing-rules` POST) answer exactly `{"success": true}`, which is
// what ``SuccessResponse`` already is. `district-persona-patch.json`,
// `district-tools-patch.json`, `district-routing-patch.json` and
// `district-directory-patch.json` are therefore gated against that type in
// `ImplementedFixtures`, the same way the push pair and the bare acknowledgements
// are. See the ⛔ at the foot of `DeviceResponses.swift`: a bespoke struct with
// identical members would prove nothing the shared one does not, and would read as
// though the bodies were known to differ.
//
// ⚠️ SHARING IS SAFE ONLY BECAUSE THE GATE PINS EACH FIXTURE SEPARATELY. The day
// one of those routes grows a key, ITS fixture fails and the other three do not,
// and the answer then is to split a real type out to here rather than to widen
// ``SuccessResponse``. The Kotlin client reached the same behaviour under a
// different name (one `WorkspaceConfigSaveResponse` shared by the same routes) and
// wrote the same caveat. ⚠️ `district-directory-patch.json` was already gated
// against ``SuccessResponse`` on this side before the other three arrived, which
// is what settles it: a new type for three of the four siblings would have left
// one surface described two ways.
//
// ⛔ AND NONE OF THE FOUR ECHOES THE UPDATED CONFIG, WHICH IS WHY A SAVE HAS TO BE
// FOLLOWED BY A RE-READ OF ``WorkspaceConfigResponse``. There is no body to adopt,
// so a client that assumed one would keep rendering its own optimistic edit as
// though the server had confirmed it, and the NEXT save (through a route that
// replaces its stored array wholesale) would then be built on a client-side
// belief. ⚠️ The re-read is allowed to fail without the save having failed, and
// collapsing those two into one outcome is the dangerous direction: an operator
// told the save did not land will change the form back and save again, from state
// that is now stale. `knowledge-mode` is the one write on this surface that
// escapes all of it, because it echoes the stored config.
