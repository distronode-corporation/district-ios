import Foundation

/// The rules a persona picker follows, expressed once and on the tier that has
/// tests.
///
/// ⛔ HERE RATHER THAN IN THE VIEW, BECAUSE EVERY ONE OF THEM IS A CORRECTNESS RULE
/// AND NOT A LAYOUT ONE. Which languages an engine offers, which voice a language
/// switch lands on, whether a style picker appears at all — each is a claim the
/// SERVER will not contradict, because the save route coerces instead of refusing.
/// A rule implemented in a `body` is a rule no Linux test can reach.
public extension PersonaOptionsResponse {
    /// ⛔ THE ONE ENGINE WHOSE CATALOGUES ARE KEYED BY LANGUAGE, named once. The
    /// server states the same asymmetry in its own route; restating it in a view
    /// would put "which languages" and "which voices" in two places that can
    /// disagree.
    static let languageKeyedEngine = "deepgram-pipeline"

    /// The engines an operator may actually choose.
    ///
    /// ⚠️ NOT WHAT THE PICKER SHOWS. The picker shows every engine and DISABLES the
    /// rest, so the label can say why; this is what a selection is validated
    /// against. See ``PersonaEngineOption/inRegion``.
    var selectableEngines: [PersonaEngineOption] {
        engines.filter(\.inRegion)
    }

    func engine(_ id: String?) -> PersonaEngineOption? {
        guard let id else { return nil }
        return engines.first { $0.id == id }
    }

    /// The languages one engine offers.
    ///
    /// ⛔ THE SHORT LIST IS NOT A SUBSET OF THE LONG ONE. See
    /// ``PersonaLanguageCatalog``: Deepgram has `nl-NL` and `it-IT` and no `hi-IN`.
    /// An engine this client has never heard of gets the general list, which is
    /// what the server's own ternary does.
    func languages(forEngine engineId: String?) -> [PersonaLabelledValue] {
        engineId == Self.languageKeyedEngine ? languages.deepgram : languages.general
    }

    /// The voice groups for one engine in one language.
    ///
    /// ⚠️ AN EMPTY ARRAY IS A REAL ANSWER. A stored persona can name a language its
    /// engine does not publish — the save route never refused one — and the honest
    /// rendering is an empty picker with the existing value still shown, never a
    /// silent substitution.
    func voiceGroups(engine engineId: String?, language: String?) -> [PersonaVoiceGroup] {
        guard let engineId, let language else { return [] }
        return voices.first { $0.engine == engineId && $0.language == language }?.groups ?? []
    }

    /// Whether `voice` appears anywhere in that engine-and-language catalogue.
    ///
    /// ⛔ THE QUESTION A FORM MUST ASK BEFORE IT DECIDES A STORED VALUE IS STALE,
    /// and the answer must not drive a silent correction: an id the catalogue has
    /// dropped is still what the workspace is speaking in today.
    func voiceExists(_ voice: String?, engine engineId: String?, language: String?) -> Bool {
        guard let voice else { return false }
        return voiceGroups(engine: engineId, language: language)
            .contains { group in group.options.contains { $0.value == voice } }
    }

    /// The voice to land on after an engine or language change.
    ///
    /// ⛔ DEEPGRAM'S PER-LANGUAGE MAP WINS, AND THAT ORDER IS THE WHOLE FUNCTION. A
    /// Deepgram voice id encodes its own language (`aura-2-asteria-en` cannot speak
    /// Italian) and the save route would store the mismatch happily, so switching
    /// language has to move the voice with it. Every other engine keeps one
    /// starting voice per engine and its language picker does not touch it.
    ///
    /// ⚠️ nil MEANS "THE SERVER PUBLISHED NO DEFAULT FOR THIS COMBINATION", which
    /// is not the same as an error and not the same as an empty string. A caller
    /// leaves the field as it was rather than clearing it — clearing it would be a
    /// save that stores `""` and makes the agent fall back to a voice nobody chose.
    func defaultVoice(engine engineId: String?, language: String?) -> String? {
        guard let engineId else { return nil }
        if engineId == Self.languageKeyedEngine, let language {
            return defaults.voiceByDeepgramLanguage[language]
        }
        return defaults.voiceByEngine[engineId]
    }

    /// The answer lengths one engine offers.
    ///
    /// ⚠️ EMPTY FOR AN ENGINE THE CATALOGUE DOES NOT CARRY, which hides the picker
    /// rather than showing three options that would be saved under a `modelId` the
    /// route is about to coerce.
    func responseLengths(forEngine engineId: String?) -> [PersonaLabelledValue] {
        engine(engineId)?.responseLengths ?? []
    }
}

/// What the persona form's non-text controls do for one engine.
///
/// ⛔ A TYPE RATHER THAN THREE BOOLEANS SCATTERED THROUGH A VIEW, because two of
/// the three are the difference between a control that works and a control that
/// silently does nothing. `voiceStyle` is read only by Gemini Live (the chained
/// pipelines have no TTS stage to posture) and `preemptiveTts` is meaningless to it
/// (a realtime engine does not speculate ahead of its own audio), so each is a
/// setting the other engine will accept, store and ignore — with a 200.
public struct PersonaEngineCapabilities: Sendable, Equatable {
    /// ⛔ THE GEMINI LIVE ENGINE ID, AND IT IS SPELLED OUT RATHER THAN DERIVED. The
    /// options payload marks no engine as realtime, and inferring it from the
    /// substring "gemini" would classify a future chained Gemini pipeline wrongly
    /// in the one direction that shows a picker with no effect.
    public static let geminiLiveEngine = "gemini-live-2.5-flash-native-audio"

    /// ⚠️ Gemini Live only. See the type note.
    public let showsVoiceStyle: Bool
    /// ⚠️ Every engine EXCEPT Gemini Live, mirroring the web form's own condition.
    public let showsPreemptiveTts: Bool
    /// Whether switching language should move the voice with it.
    public let languageSelectsVoice: Bool

    public init(engineId: String?) {
        let isGemini = engineId == Self.geminiLiveEngine
        showsVoiceStyle = isGemini
        // ⚠️ TRUE FOR A nil ENGINE, deliberately: an unloaded or unrecognised engine
        // is treated as a chained pipeline, which is what the web's `!==` comparison
        // does and what every engine but one actually is.
        showsPreemptiveTts = !isGemini
        languageSelectsVoice = engineId == PersonaOptionsResponse.languageKeyedEngine
    }
}
