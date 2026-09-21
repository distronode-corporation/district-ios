import DistrictModel
import DistrictNetwork
import Foundation

/// The persona's seven vocabulary-backed fields, as one editor holds them.
///
/// ⛔ EVERY STRING HERE IS A WIRE VALUE AND `""` MEANS "NOBODY HAS EVER CHOSEN",
/// WHICH IS NOT THE SAME AS A CLEARED FIELD AND IS NEVER SENT AS ONE. The three
/// free-text fields next door work the other way round — an empty greeting is a
/// deliberate clear and reaches the wire as `""` — but a vocabulary field cleared to
/// an empty string would be STORED, and the agent would then fall back to a voice,
/// an engine or a language nobody picked, with a 200 and nothing reporting it. So
/// this form can set one of these and can change one of these; it cannot unset one.
/// See ``PersonaEngineWrite``.
struct PersonaEngineValues: Equatable {
    /// The engine. ⚠️ `""` until a workspace has chosen one; the SERVER coerces an
    /// unknown id to `deepgram-pipeline` at save time, which is exactly why this
    /// client will not put that literal on screen as though somebody chose it.
    var modelId: String
    var language: String
    var voice: String
    /// ⛔ THE LEVEL FOR ``modelId`` ONLY. The stored row keys it per engine, so this
    /// is a value that moves when the engine picker moves.
    var responseLength: String
    var temperature: Double
    /// ⚠️ Read by Gemini Live and ignored by every chained pipeline.
    var voiceStyle: String
    /// ⚠️ Meaningless to Gemini Live, which does not speculate ahead of its own
    /// audio. Ignored there rather than refused.
    var preemptiveTts: Bool
}

/// The persona form's non-text half: what it shows, what changing one control does
/// to the others, and which fields a save may name.
///
/// ⛔ A VALUE TYPE WITH NO CONTAINER AND NO REPOSITORY, SO EVERY RULE ON THIS SCREEN
/// IS REACHABLE FROM A TEST. Which languages an engine offers, which voice a language
/// switch lands on, whether the style picker appears and whether a field is dirty are
/// each a correctness rule rather than a layout one — the save route COERCES instead
/// of refusing, so a rule implemented in a `body` is a rule nothing can check and a
/// wrong answer nothing reports.
///
/// ⛔ IT CANNOT BE BUILT WITHOUT ``PersonaOptionsResponse``, WHICH IS THE POINT. There
/// is no built-in catalogue to fall back to and there must never be one: every value
/// a stale Swift list offered would still be accepted, stored and then silently
/// substituted. A failed options read leaves this nil and the screen read-only.
///
/// ⚠️ IT HOLDS THE STORED ROW because ``responseLength`` is keyed by engine: moving
/// the engine picker has to produce the NEW engine's saved level rather than carrying
/// the old engine's across, and only the row knows that.
struct PersonaEngineDraft {
    let options: PersonaOptionsResponse

    /// What the operator sees and edits.
    var values: PersonaEngineValues

    /// What the server held when this form opened.
    ///
    /// ⛔ NOT MERELY `stored`, BECAUSE THREE FIELDS OPEN ON A PUBLISHED DEFAULT RATHER
    /// THAN ON A STORED VALUE. A workspace that has never chosen a temperature shows
    /// `defaults.temperature`, and comparing that against `nil` would mark the field
    /// dirty before anybody touched it — which on a dirty-field save means writing a
    /// number nobody chose.
    ///
    /// ⚠️ ``PersonaEngineValues/responseLength`` MOVES WITH THE ENGINE PICKER. See
    /// ``selectEngine(_:)``.
    private(set) var baseline: PersonaEngineValues

    private let stored: AiPersona?

    init(persona: AiPersona?, options: PersonaOptionsResponse) {
        self.options = options
        stored = persona
        let start = PersonaEngineDraft.hydrate(persona, options)
        baseline = start
        values = start
    }

    // MARK: - What the pickers offer

    /// ⛔ EVERY ENGINE, INCLUDING THE OUT-OF-REGION ONES, WHICH THE PICKER RENDERS
    /// DISABLED WITH THEIR LABELS. Hiding them would leave an operator unable to see
    /// why their region has fewer choices than a colleague's; offering them would make
    /// a data-residency decision on a settings screen, silently, with a 200.
    var engines: [PersonaEngineOption] {
        options.engines
    }

    /// ⛔ THE DEEPGRAM LIST OR THE GENERAL ONE, AND THE SHORT ONE IS NOT A SUBSET.
    var languages: [PersonaLabelledValue] {
        options.languages(forEngine: PersonaEngineDraft.wire(values.modelId))
    }

    /// ⚠️ EMPTY IS A REAL ANSWER — a stored persona can name a language its engine
    /// does not publish, and the honest rendering is an empty picker with the existing
    /// value still shown.
    var voiceGroups: [PersonaVoiceGroup] {
        options.voiceGroups(
            engine: PersonaEngineDraft.wire(values.modelId),
            language: PersonaEngineDraft.wire(values.language)
        )
    }

    /// ⚠️ EMPTY FOR AN ENGINE THE CATALOGUE DOES NOT CARRY, which hides the picker
    /// rather than offering a level the route is about to discard.
    var responseLengths: [PersonaLabelledValue] {
        options.responseLengths(forEngine: PersonaEngineDraft.wire(values.modelId))
    }

    /// ⚠️ Gemini Live only. See ``capabilities``.
    var voiceStyles: [PersonaLabelledValue] {
        options.voiceStyles
    }

    var capabilities: PersonaEngineCapabilities {
        PersonaEngineCapabilities(engineId: PersonaEngineDraft.wire(values.modelId))
    }

    /// Whether the selected voice is one this engine and language publish.
    ///
    /// ⛔ ASKED SO THE SCREEN CAN SAY SO, NEVER SO IT CAN CORRECT IT. An id the
    /// catalogue has dropped is still what the workspace is speaking in today, and
    /// substituting it silently would change the agent's voice on the next save.
    var voiceIsOffCatalogue: Bool {
        guard !values.voice.isEmpty else { return false }
        return !options.voiceExists(
            values.voice,
            engine: PersonaEngineDraft.wire(values.modelId),
            language: PersonaEngineDraft.wire(values.language)
        )
    }

    // MARK: - What moving one control does to the others

    /// Choose an engine.
    ///
    /// ⛔ THREE OTHER FIELDS MOVE WITH IT AND EACH IS A CORRECTNESS RULE. The answer
    /// LENGTH is stored per engine, so it becomes the new engine's own saved level
    /// (carrying the old engine's across is how a tenant's terse pipeline silently
    /// retunes the realtime brain). The VOICE becomes the new engine's published
    /// starting voice, because a voice id belongs to one engine and the save route
    /// would store the mismatch happily. The LANGUAGE is dropped when the new engine
    /// does not publish it — Deepgram carries `nl-NL` and `it-IT` and no `hi-IN`.
    ///
    /// ⛔ THE DROPPED LANGUAGE IS LEFT EMPTY RATHER THAN REPLACED WITH A GUESS. The
    /// web picks `en-US`; nothing on the wire publishes a default language, so
    /// choosing one here would be a literal that drifts with nothing comparing it.
    /// Empty renders as "Not set" beside an empty voice list, which is visible before
    /// anything is saved and is the operator's decision to make.
    ///
    /// ⚠️ ``PersonaEngineValues/voiceStyle`` AND `preemptiveTts` ARE LEFT ALONE even
    /// when the new engine hides their control. Hiding a control means this form stops
    /// OFFERING the setting, not that it silently rewrites what the workspace stored.
    mutating func selectEngine(_ engineId: String) {
        values.modelId = engineId
        if !values.language.isEmpty, !offersLanguage(values.language, engine: engineId) {
            values.language = ""
        }
        if let voice = options.defaultVoice(engine: engineId, language: PersonaEngineDraft.wire(values.language)) {
            values.voice = voice
        }
        // ⛔ THE BASELINE MOVES TOO, AND THAT IS WHAT MAKES "dirty" MEAN ANYTHING HERE.
        // The stored level for the NEW engine is what a save would be compared against;
        // leaving the baseline on the old engine's level would report a field as
        // changed because the engine changed, and send it.
        let level = storedResponseLength(for: engineId)
        values.responseLength = level
        baseline.responseLength = level
    }

    /// Choose a language.
    ///
    /// ⛔ IT MOVES THE VOICE FOR THE LANGUAGE-KEYED ENGINE AND FOR NOTHING ELSE. A
    /// Deepgram voice id encodes its own language (`aura-2-asteria-en` cannot speak
    /// Italian) and the route would store the mismatch with a 200; every other engine
    /// speaks its whole catalogue in any language it carries.
    ///
    /// ⚠️ A PUBLISHED DEFAULT THAT DOES NOT EXIST LEAVES THE VOICE ALONE rather than
    /// clearing it. nil means "the server published no default for this combination",
    /// which is not an error and is not a reason to unset what the workspace speaks in.
    mutating func selectLanguage(_ language: String) {
        values.language = language
        guard capabilities.languageSelectsVoice else { return }
        if let voice = options.defaultVoice(
            engine: PersonaEngineDraft.wire(values.modelId),
            language: PersonaEngineDraft.wire(language)
        ) {
            values.voice = voice
        }
    }

    // MARK: - What a save may name

    /// Which fields differ from what the server holds.
    ///
    /// ⚠️ TEMPERATURE IS COMPARED WITH A TOLERANCE, not with `!=`. The slider produces
    /// its value by arithmetic on a `Double`, so dragging to 0.7 and back can land on
    /// 0.7000000000000001 — which is not a change anybody made and would be written as
    /// one.
    var changes: PersonaEngineChanges {
        PersonaEngineChanges(
            modelId: values.modelId != baseline.modelId,
            language: values.language != baseline.language,
            voice: values.voice != baseline.voice,
            responseLength: values.responseLength != baseline.responseLength,
            temperature: abs(values.temperature - baseline.temperature) > PersonaEngineDraft.temperatureEpsilon,
            voiceStyle: values.voiceStyle != baseline.voiceStyle,
            preemptiveTts: values.preemptiveTts != baseline.preemptiveTts
        )
    }

    /// The seven arguments a `savePersona` call may carry, nil where nothing is sent.
    ///
    /// ⛔ `responseLength` NEVER TRAVELS ALONE. The route stores the level under
    /// `aiPersona.responseLength[modelId]` and refuses to guess at the stored engine,
    /// so a request without an accepted `modelId` writes NOTHING and answers 200 — the
    /// operator's edit vanishes with a success banner over it. The engine id therefore
    /// rides along whether or not it changed, and the level is dropped outright when
    /// there is no engine to key it on.
    ///
    /// ⛔ AN EMPTY VOCABULARY FIELD IS NEVER SENT. See the ⛔ on ``PersonaEngineValues``.
    var write: PersonaEngineWrite {
        let changed = changes
        let engine = PersonaEngineDraft.wire(values.modelId)
        let level = changed.responseLength ? PersonaEngineDraft.wire(values.responseLength) : nil
        let sendsLevel = level != nil && engine != nil
        return PersonaEngineWrite(
            modelId: (changed.modelId || sendsLevel) ? engine : nil,
            language: changed.language ? PersonaEngineDraft.wire(values.language) : nil,
            voice: changed.voice ? PersonaEngineDraft.wire(values.voice) : nil,
            responseLength: sendsLevel ? level : nil,
            temperature: changed.temperature ? values.temperature : nil,
            voiceStyle: changed.voiceStyle ? PersonaEngineDraft.wire(values.voiceStyle) : nil,
            preemptiveTts: changed.preemptiveTts ? values.preemptiveTts : nil
        )
    }

    /// The persona a preview session auditions.
    ///
    /// ⛔ THE FORM AS IT STANDS, DIRTY FIELDS AND ALL, WHICH IS THE WHOLE POINT OF THE
    /// PREVIEW ROUTE. The agent reads this blob out of the token metadata for a
    /// `preview_*` room, so sending the SAVED persona instead would answer a different
    /// question convincingly.
    ///
    /// ⚠️ AN EMPTY FIELD IS OMITTED RATHER THAN SENT AS `""`. There is no stored row to
    /// merge against here: an absent key leaves the agent on its own per-field fallback
    /// for this session, while `""` would audition a persona with a blank name.
    func previewForm(name: String, greeting: String, personality: String) -> PersonaPreviewForm {
        PersonaPreviewForm(
            name: PersonaEngineDraft.wire(name),
            greeting: PersonaEngineDraft.wire(greeting),
            personality: PersonaEngineDraft.wire(personality),
            voice: PersonaEngineDraft.wire(values.voice),
            language: PersonaEngineDraft.wire(values.language),
            modelId: PersonaEngineDraft.wire(values.modelId),
            responseLength: PersonaEngineDraft.wire(values.responseLength),
            temperature: values.temperature,
            voiceStyle: PersonaEngineDraft.wire(values.voiceStyle),
            preemptiveTts: values.preemptiveTts
        )
    }

    // MARK: - Internals

    /// ⚠️ 0.0005, AN ORDER OF MAGNITUDE UNDER THE 0.1 STEP THE SLIDER MOVES IN, so a
    /// real one-step change is never mistaken for float noise and float noise is never
    /// mistaken for a change.
    private static let temperatureEpsilon = 0.0005

    private func offersLanguage(_ language: String, engine: String) -> Bool {
        options.languages(forEngine: engine).contains { $0.value == language }
    }

    /// ⚠️ THE STORED LEVEL FOR ONE ENGINE, falling back to the server's published
    /// default rather than to a Swift literal.
    private func storedResponseLength(for engineId: String) -> String {
        stored?.responseLength?[engineId] ?? options.defaults.responseLength
    }

    private static func hydrate(_ persona: AiPersona?, _ options: PersonaOptionsResponse) -> PersonaEngineValues {
        let modelId = persona?.modelId ?? ""
        let language = persona?.language ?? ""
        let fallbackVoice = options.defaultVoice(engine: wire(modelId), language: wire(language))
        return PersonaEngineValues(
            modelId: modelId,
            language: language,
            voice: persona?.voice ?? fallbackVoice ?? "",
            responseLength: persona?.responseLength?[modelId] ?? options.defaults.responseLength,
            temperature: persona?.temperature ?? options.defaults.temperature,
            voiceStyle: persona?.voiceStyle ?? "",
            preemptiveTts: persona?.preemptiveTts == true
        )
    }

    /// `""` is this form's "never chosen"; the wire has no such value.
    private static func wire(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

/// Which of the seven differ from what the server holds.
struct PersonaEngineChanges: Equatable {
    var modelId = false
    var language = false
    var voice = false
    var responseLength = false
    var temperature = false
    var voiceStyle = false
    var preemptiveTts = false

    var isEmpty: Bool {
        !(modelId || language || voice || responseLength || temperature || voiceStyle || preemptiveTts)
    }
}

/// The seven vocabulary arguments of one `savePersona` call.
///
/// ⚠️ A TYPE RATHER THAN SEVEN OPTIONALS AT A CALL SITE, for the reason
/// ``PersonaPreviewForm`` is one: five of them are `String?` and at that shape a
/// transposition COMPILES — saving a language into the voice field, which the route
/// stores verbatim and the agent then falls back from.
struct PersonaEngineWrite: Equatable {
    var modelId: String?
    var language: String?
    var voice: String?
    var responseLength: String?
    var temperature: Double?
    var voiceStyle: String?
    var preemptiveTts: Bool?
}
