import DistrictModel
import DistrictNetwork
import Foundation

/// The persona fields this form edits besides the three free-text boxes.
///
/// ⛔ EVERY STRING HERE IS A WIRE VALUE AND `""` MEANS "NOBODY HAS EVER CHOSEN", WHICH IS
/// NOT THE SAME AS A CLEARED FIELD AND IS NEVER SENT AS ONE. The three free-text fields
/// next door work the other way round (an empty greeting is a deliberate clear) but a
/// vocabulary field cleared to an empty string would be STORED, and the agent would then
/// fall back to a voice or a language nobody picked, with a 200.
struct PersonaIdentityValues: Equatable {
    var language: String
    /// ⚠️ NOT A PICKER HERE. It moves only with the language, for the language-keyed
    /// engine (see ``PersonaIdentityDraft/selectLanguage(_:)``).
    var voice: String
    /// ⛔ THE LEVEL FOR THE STORED ENGINE ONLY. The stored row keys it per engine.
    var responseLength: String
}

/// The persona's language and answer length, drawn from the server's catalogue.
///
/// ⛔ THE ENGINE, VOICE, TEMPERATURE, SPEAK-SOONER AND VOICE STYLE ARE THE VOICE STUDIO'S,
/// NOT THIS FORM'S. They moved to their own screen, as they did on the web (the Studio is
/// its own tab there) and on Android, and this form neither shows nor sends them, with ONE
/// exception: changing the language of the language-keyed engine moves the voice with it,
/// because a Deepgram voice id encodes its own language (`aura-2-asteria-en` cannot speak
/// Italian) and the route would store the mismatch with a 200. ⛔ Two screens writing the
/// engine would be two baselines for one value, and the stale one would resend an engine id
/// the other had changed.
///
/// ⛔ EVERY LIST COMES FROM ``options`` AND NOTHING IS HARDCODED. The save route COERCES
/// rather than rejects, so a built-in list does not fail when it drifts; it produces a
/// persona nobody chose.
///
/// ⚠️ ``modelId`` IS THE STORED ENGINE AND IS READ-ONLY HERE. It decides which language
/// list and which answer lengths apply, and rides along on a save only when the answer
/// length changed (see ``write``).
struct PersonaIdentityDraft {
    let options: PersonaOptionsResponse
    let persona: AiPersona?

    /// What the operator sees and edits.
    private(set) var values: PersonaIdentityValues

    /// What the server held when this form opened.
    let baseline: PersonaIdentityValues

    init(persona: AiPersona?, options: PersonaOptionsResponse) {
        self.options = options
        self.persona = persona
        let modelId = persona?.modelId ?? ""
        let language = persona?.language ?? ""
        let start = PersonaIdentityValues(
            language: language,
            voice: persona?.voice
                ?? options.defaultVoice(engine: Self.wire(modelId), language: Self.wire(language))
                ?? "",
            responseLength: persona?.responseLength?[modelId] ?? options.defaults.responseLength
        )
        values = start
        baseline = start
    }

    /// The stored engine id, `""` when never set.
    var modelId: String {
        persona?.modelId ?? ""
    }

    // MARK: - What the pickers offer

    /// ⛔ THE DEEPGRAM LIST OR THE GENERAL ONE, AND THE SHORT ONE IS NOT A SUBSET.
    var languages: [PersonaLabelledValue] {
        options.languages(forEngine: Self.wire(modelId))
    }

    /// ⚠️ EMPTY FOR AN ENGINE THE CATALOGUE DOES NOT CARRY, which hides the picker rather
    /// than offering a level the route is about to discard.
    var responseLengths: [PersonaLabelledValue] {
        options.responseLengths(forEngine: Self.wire(modelId))
    }

    // MARK: - Edits

    /// Choose a language.
    ///
    /// ⛔ IT MOVES THE VOICE ONLY FOR THE LANGUAGE-KEYED ENGINE; every other engine keeps one
    /// voice per engine, and that voice is the Voice Studio's to change. ⚠️ A combination
    /// with no published default leaves the voice alone rather than clearing it.
    mutating func selectLanguage(_ language: String) {
        values.language = language
        guard PersonaEngineCapabilities(engineId: Self.wire(modelId)).languageSelectsVoice else { return }
        if let voice = options.defaultVoice(engine: Self.wire(modelId), language: Self.wire(language)) {
            values.voice = voice
        }
    }

    mutating func selectResponseLength(_ level: String) {
        values.responseLength = level
    }

    var isDirty: Bool {
        values != baseline
    }

    // MARK: - What a save may name

    /// What to send.
    ///
    /// ⛔ `responseLength` WITHOUT `modelId` IS SILENTLY DISCARDED SERVER-SIDE (it is stored
    /// under `responseLength[modelId]`), so a level change carries the STORED engine id with
    /// it. The same id as stored is a no-op for the engine itself, so this never moves the
    /// engine the Voice Studio set.
    ///
    /// ⛔ AN EMPTY VOCABULARY FIELD IS DROPPED RATHER THAN SENT: `""` would be stored.
    var write: PersonaIdentityWrite {
        let level = values.responseLength != baseline.responseLength ? Self.wire(values.responseLength) : nil
        let engine = Self.wire(modelId)
        let sendsLevel = level != nil && engine != nil
        return PersonaIdentityWrite(
            modelId: sendsLevel ? engine : nil,
            language: values.language != baseline.language ? Self.wire(values.language) : nil,
            voice: values.voice != baseline.voice ? Self.wire(values.voice) : nil,
            responseLength: sendsLevel ? level : nil
        )
    }

    /// The unsaved form, as the preview route's sanitiser reads it.
    ///
    /// ⛔ WHAT IS ON SCREEN, CHANGED OR NOT, PLUS THE STORED ENGINE SETTINGS. The preview
    /// persists nothing and merges against nothing, so an omitted key would leave the agent
    /// on its own fallback rather than on what the workspace runs.
    func previewForm(name: String, greeting: String, personality: String) -> PersonaPreviewForm {
        PersonaPreviewForm(
            name: Self.wire(name),
            greeting: Self.wire(greeting),
            personality: Self.wire(personality),
            voice: Self.wire(values.voice),
            language: Self.wire(values.language),
            modelId: Self.wire(modelId),
            responseLength: Self.wire(values.responseLength),
            temperature: persona?.temperature ?? options.defaults.temperature,
            voiceStyle: persona?.voiceStyle.flatMap { Self.wire($0) },
            preemptiveTts: persona?.preemptiveTts == true
        )
    }

    /// `""` is this form's "never chosen"; the wire has no such value.
    private static func wire(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

/// Exactly what a persona PATCH carries for this form's non-text half. Nil is left alone.
///
/// ⚠️ A TYPE RATHER THAN FOUR OPTIONALS AT A CALL SITE: all four are `String?`, and at that
/// shape a transposition COMPILES, saving a language into the voice field.
struct PersonaIdentityWrite: Equatable {
    var modelId: String?
    var language: String?
    var voice: String?
    var responseLength: String?
}
