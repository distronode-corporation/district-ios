import Foundation

/// The persona form's vocabularies, and the credential for auditioning one.
///
/// ⛔ THESE TWO ARE WHY THE PERSONA FORM CAN BE EDITED FROM A PHONE AT ALL. Every
/// field on `PATCH workspace/persona` beyond the three free-text ones is drawn
/// from a server-side registry and COERCES rather than rejects: an unrecognised
/// `modelId` becomes `deepgram-pipeline`, an unrecognised `voice` is stored
/// verbatim and then quietly replaced by the agent's own fallback at synthesis
/// time. Both answer 200 and nothing anywhere reports the substitution. So the
/// choice was never "validate client-side or not" — it was "offer free text and
/// produce a persona nobody chose, or read the catalogue the web derives its own
/// pickers from". This is the second.
///
/// ⛔ AND THE PREVIEW IS A REAL, BILLED CALL. `persona/preview-token` mints a
/// LiveKit credential for an end-to-end encrypted `preview_<workspaceId>_<uuid>`
/// room that the voice agent joins and answers in, on the workspace's own
/// pipeline and the workspace's own media node. Nothing about it is a dry run.
public extension DistrictEndpoints {
    /// The engines, languages, voices, voice styles, answer lengths and defaults
    /// this workspace's persona form may offer.
    ///
    /// ⛔ REGION-KEYED, AND THE REGION IS THE WORKSPACE'S RATHER THAN THE SERVING
    /// ORIGIN'S. Each engine is labelled with where its audio is actually
    /// processed, which is a public claim about residency; keying on whichever
    /// origin answered would tell an EU customer their audio stays in the EU
    /// because a Frankfurt node happened to take the request. A client must
    /// therefore never cache one workspace's answer and render it for another.
    ///
    /// ⛔ `inRegion: false` IS SELECTABLE-LOOKING AND MUST NOT BE OFFERED AS ONE.
    /// The route publishes every engine so the label can say what each one would
    /// mean; a picker that let an operator choose an out-of-region engine would
    /// make a residency decision on a settings screen, silently, with a 200.
    ///
    /// ⚠️ A READ, AND STILL RATE LIMITED — 60/min per WORKSPACE. Generous on
    /// purpose (a client may legitimately refetch when the engine changes) but not
    /// unbounded, so it belongs on a screen's load rather than on a keystroke.
    ///
    /// ⚠️ IT EXCLUDES `viewer` SERVER-SIDE, the same bar the save route sets and
    /// the same one `workspace/config` sets: a viewer may not read the
    /// configuration surface they cannot change.
    static func personaOptions(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .personaOptions,
            .get,
            DistrictPaths.workspacePersonaOptions,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Mint a credential for one persona preview session.
    ///
    /// ⛔ BILLABLE, NOT IDEMPOTENT, AND NOTHING IN THIS CLIENT MAY RETRY IT. Every
    /// token is an invitation for the voice agent to join a room and start burning
    /// STT/LLM/TTS minutes; the route is capped at **10/min per workspace** and
    /// that ceiling is the only thing bounding a retry loop, because the spend
    /// lands downstream in the agent rather than in the handler.
    ///
    /// ⛔ IT CARRIES THE **UNSAVED** FORM, WHICH IS THE WHOLE POINT OF THE ROUTE.
    /// The agent reads this blob out of the token metadata for any `preview_*`
    /// room, so the audition is of what is on screen rather than of what is
    /// stored — a persona can be heard before it is committed to the workspace
    /// every caller reaches. A client that sent the SAVED persona instead would
    /// answer a different question convincingly.
    ///
    /// ⛔ THE SERVER SANITISES AND THIS TYPE MIRRORS THE SANITISER EXACTLY. Unknown
    /// keys are DROPPED rather than passed through, and `modelId` is coerced to
    /// `deepgram-pipeline` when it is not a known pipeline id — deliberately
    /// matching `workspace/persona`'s contract rather than inventing a second one.
    /// Sending a key the sanitiser does not read is inert today, which is exactly
    /// how a form field becomes an agent input later without anyone deciding.
    ///
    /// ⚠️ A nil FIELD IS DROPPED AND THAT MEANS SOMETHING DIFFERENT HERE THAN ON
    /// THE SAVE ROUTE. There is no stored row to merge against: an absent key
    /// leaves the agent on its own per-field fallback for this session only, and
    /// nothing is persisted either way.
    ///
    /// ⚠️ THE BODY NESTS UNDER `formData`, unlike every other write on this
    /// surface. The route reads `{ workspaceId, formData }` and answers **400
    /// "Missing workspaceId or formData"** for a flattened body — which reads as a
    /// broken client rather than as a shape mismatch.
    static func previewToken(workspaceId: String, form: PersonaPreviewForm) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .personaPreviewToken,
            .post,
            DistrictPaths.workspacePersonaPreviewToken,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("formData", form.rendered()),
            ]))
        )
    }
}

/// The persona a preview session auditions, as the route's sanitiser reads it.
///
/// ⛔ A TYPE RATHER THAN TEN PARAMETERS, for the reason ``RegulatoryDocumentUpload``
/// and ``MessagingAccountDraft`` are types: seven of these fields are `String?` and
/// at that shape a transposition at a call site COMPILES — auditioning a persona
/// whose greeting is its personality, in a voice that is actually a language tag.
///
/// ⛔ THE FIELD LIST IS THE SERVER'S `PREVIEW_STRING_FIELDS` PLUS THE THREE TYPED
/// ONES, AND IT IS NOT THE SAVE ROUTE'S LIST. The preview sanitiser reads `name`,
/// `voice`, `greeting`, `personality`, `voiceStyle`, `language`, `responseLength`,
/// `modelId`, `temperature` and `preemptiveTts` — and `responseLength` here is a
/// bare STRING for the engine being auditioned rather than the per-engine map the
/// stored row holds. `dgiEnabled` is absent because the preview does not enrich.
///
/// ⚠️ `connectors` AND `agentMedia` ARE ALSO READ BY THE SANITISER AND ARE
/// DELIBERATELY NOT MODELLED. Both are arrays this client has no editor for (the
/// agent media library is out of scope by decision), and a field sent empty is not
/// the same as one left alone.
public struct PersonaPreviewForm: Sendable, Equatable {
    public var name: String?
    public var greeting: String?
    public var personality: String?
    /// ⚠️ A pipeline-registry voice id, not a display name.
    public var voice: String?
    public var language: String?
    /// ⛔ COERCED TO `deepgram-pipeline` BY THE SERVER when it is not a known
    /// pipeline id. The preview then runs on an engine nobody chose, with a 200 —
    /// which is why this value must come from ``PersonaOptionsResponse/engines``.
    public var modelId: String?
    /// ⚠️ ONE LEVEL FOR THE ENGINE BEING AUDITIONED, not the stored per-engine map.
    public var responseLength: String?
    public var temperature: Double?
    /// ⚠️ Gemini Live only. Ignored by the other engines, which have no TTS stage
    /// to posture.
    public var voiceStyle: String?
    /// ⛔ PAID SPECULATIVE SYNTHESIS. The agent reads it as
    /// `bool(persona_data.get("preemptiveTts"))`, so a truthy STRING would switch
    /// it on — which is why this is a `Bool?` and why the sanitiser refuses
    /// anything else.
    public var preemptiveTts: Bool?

    public init(
        name: String? = nil,
        greeting: String? = nil,
        personality: String? = nil,
        voice: String? = nil,
        language: String? = nil,
        modelId: String? = nil,
        responseLength: String? = nil,
        temperature: Double? = nil,
        voiceStyle: String? = nil,
        preemptiveTts: Bool? = nil
    ) {
        self.name = name
        self.greeting = greeting
        self.personality = personality
        self.voice = voice
        self.language = language
        self.modelId = modelId
        self.responseLength = responseLength
        self.temperature = temperature
        self.voiceStyle = voiceStyle
        self.preemptiveTts = preemptiveTts
    }

    /// ⚠️ THROUGH ``JSONValue/object(_:)``, so a nil field is ABSENT rather than an
    /// explicit null. The sanitiser type-checks every key it reads, so a null would
    /// be dropped anyway — sending one would simply be a larger body saying the
    /// same thing, and the house rule on this surface is that nil means "not on the
    /// wire".
    func rendered() -> JSONValue {
        .object([
            ("name", .optional(name)),
            ("greeting", .optional(greeting)),
            ("personality", .optional(personality)),
            ("voice", .optional(voice)),
            ("language", .optional(language)),
            ("modelId", .optional(modelId)),
            ("responseLength", .optional(responseLength)),
            ("temperature", temperature.map { JSONValue.number($0) }),
            ("voiceStyle", .optional(voiceStyle)),
            ("preemptiveTts", preemptiveTts.map { JSONValue.bool($0) }),
        ])
    }
}
