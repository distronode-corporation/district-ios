import Foundation

/// `GET /api/district/workspace/persona/options?workspaceId=` — the vocabularies
/// a persona form is ALLOWED to offer.
///
/// ⛔ WHY THIS ROUTE EXISTS, BECAUSE IT EXPLAINS EVERY DECISION BELOW AND EVERY
/// DECISION ON THE SCREEN. `PATCH workspace/persona` COERCES rather than rejects:
/// an unrecognised `modelId` is silently rewritten to `deepgram-pipeline`, and an
/// unrecognised `voice` is stored verbatim and then replaced by the agent's own
/// fallback at synthesis time. Both answer **200**. So a native client offering
/// free text — or a hardcoded Swift list that has drifted — does not fail; it
/// produces a persona nobody chose, in a voice nobody picked, with nothing
/// anywhere reporting it. The web form never has that problem because it derives
/// its pickers from the same modules this route reads.
///
/// ⛔ SO A FAILED READ MAKES THE FORM READ-ONLY AND MUST NEVER FALL BACK TO A
/// BUILT-IN CATALOGUE. A fallback list is precisely the drifting second copy the
/// route was built to retire, and it would drift invisibly: every value it offered
/// would still be accepted, stored and then quietly substituted.
///
/// ⛔ IT IS KEYED ON THE WORKSPACE'S REGION, NOT THE SERVING ORIGIN'S. Each
/// engine's label states where its audio is actually processed, which is a public
/// claim about residency — so one workspace's answer may never be cached and shown
/// for another, and ``region`` is carried here rather than derived so a screen can
/// say which region it is describing.
///
/// ⚠️ EVERY LIST IS THE SERVER'S, INCLUDING THE DEFAULTS. ``PersonaDefaults`` holds
/// the same constants the web form starts from; a literal copied into Swift would
/// be a number that drifts with nothing comparing the two, which is the exact
/// failure `TEMPERATURE_DEFAULT` was exported to prevent on the web side.
public struct PersonaOptionsResponse: Codable, Sendable, Equatable {
    public let success: Bool
    /// ⚠️ `us`, `ca`, `eu` or `apac` on the wire, carried as a STRING. This module
    /// owns no region enum, and the value is display-and-comparison only.
    public let region: String
    /// ⛔ EVERY ENGINE, INCLUDING THE OUT-OF-REGION ONES. See
    /// ``PersonaEngineOption/inRegion``.
    public let engines: [PersonaEngineOption]
    public let languages: PersonaLanguageCatalog
    /// ⛔ ENGINE × LANGUAGE, NOT ENGINE. See ``PersonaVoiceCatalog``.
    public let voices: [PersonaVoiceCatalog]
    /// ⚠️ GEMINI LIVE ONLY, which is why it is a top-level field rather than a
    /// per-engine one: the chained pipelines have no TTS stage to posture. A form
    /// that showed this picker for every engine would offer a setting with no
    /// effect and no error.
    public let voiceStyles: [PersonaLabelledValue]
    public let defaults: PersonaDefaults
}

/// One voice engine, and the answer lengths it offers.
public struct PersonaEngineOption: Codable, Sendable, Equatable {
    /// The `modelId` this engine is saved as.
    public let id: String
    /// ⚠️ IT CARRIES THE RESIDENCY CLAIM ("… — US (processed in your region)"), so
    /// it is shown verbatim rather than reduced to a product name. Shortening it is
    /// how a form stops saying where the audio goes.
    public let label: String
    /// ⛔ `false` MEANS SELECTABLE-LOOKING AND NOT SELECTABLE. The route publishes
    /// every engine so the label can say what each one would mean; offering an
    /// out-of-region engine in a picker would make a data-residency decision on a
    /// settings screen, silently, with a 200. Render it disabled WITH its label —
    /// hiding it would leave the operator unable to see why their region has fewer
    /// choices than a colleague's.
    public let inRegion: Bool
    /// ⛔ PER ENGINE, EVEN THOUGH THE LIST IS THE SAME ONE TODAY. The chosen level
    /// is persisted under `aiPersona.responseLength[modelId]`, so it is an engine's
    /// property rather than the workspace's; a client that read one flat list would
    /// have nowhere to hang the per-engine value the save route merges.
    public let responseLengths: [PersonaLabelledValue]
}

/// One `value`/`label` pair, for a picker.
///
/// ⛔ THE VALUE IS THE WIRE VALUE AND IS NEVER LOCALISED OR TIDIED. It is what the
/// save route matches against its own whitelist; a display string sent in its place
/// is coerced rather than refused.
public struct PersonaLabelledValue: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        value
    }

    public let value: String
    public let label: String
}

/// The two language lists, and which engine uses which.
///
/// ⛔ TWO LISTS AND THE SHORTER ONE IS NOT A SUBSET. Deepgram publishes `nl-NL` and
/// `it-IT` and does NOT publish `hi-IN`; the general list is the other way round.
/// A form that showed one list for every engine would offer Hindi on Deepgram — a
/// language whose voice catalogue is empty, so the picker below it would be blank
/// and the save would store a language the engine cannot speak.
public struct PersonaLanguageCatalog: Codable, Sendable, Equatable {
    /// ⛔ USED FOR `deepgram-pipeline` AND NOTHING ELSE. That asymmetry is the
    /// contract, not an accident of today's catalogue: only Deepgram's voices vary
    /// by language.
    public let deepgram: [PersonaLabelledValue]
    public let general: [PersonaLabelledValue]
}

/// The voices one engine offers in one language.
///
/// ⛔ PUBLISHED PER (ENGINE, LANGUAGE) PAIR EVEN THOUGH ONLY DEEPGRAM'S LIST
/// ACTUALLY VARIES. That means a client looks voices up the same way for every
/// engine, and the day a second engine gains a per-language catalogue nothing on
/// the wire or in this type has to change.
///
/// ⚠️ A PAIR WITH NO ENTRY IS A REAL ANSWER AND MEANS "no voices for that
/// combination", not "the read failed". It happens whenever a stored persona names
/// a language its engine does not publish — which existing rows genuinely do, since
/// the save route never refused one.
public struct PersonaVoiceCatalog: Codable, Sendable, Equatable {
    public let engine: String
    public let language: String
    /// ⚠️ ALWAYS GROUPED ON THE WIRE, EVEN WHEN THE SOURCE LIST IS FLAT. Gemini
    /// Live's five voices arrive as one group labelled "Voices" rather than as a
    /// second top-level shape, so a client needs one decoder.
    public let groups: [PersonaVoiceGroup]
}

/// One heading in a voice picker.
public struct PersonaVoiceGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        label
    }

    public let label: String
    public let options: [PersonaLabelledValue]
}

/// What a field starts at when the workspace has never chosen.
///
/// ⛔ THESE ARE THE SERVER'S OWN CONSTANTS AND NOT A CLIENT'S GUESS. They are what
/// the web form initialises from, published on the wire precisely so the two cannot
/// drift; a Swift literal here would be a second source with nothing comparing it.
public struct PersonaDefaults: Codable, Sendable, Equatable {
    /// The starting voice for each engine, keyed by `modelId`.
    ///
    /// ⚠️ THE EN-US STARTING POINT ONLY. For Deepgram it is superseded by
    /// ``voiceByDeepgramLanguage`` the moment a language is chosen.
    public let voiceByEngine: [String: String]
    /// ⛔ IT WINS FOR DEEPGRAM, AND THAT IS THE ONE ORDERING RULE ON THIS TYPE.
    /// Switching language on Deepgram changes the voice, because the previous
    /// voice's id encodes its language (`aura-2-asteria-en` cannot speak Italian)
    /// and the save route would store it anyway.
    public let voiceByDeepgramLanguage: [String: String]
    /// ⚠️ One level (`concise`), not a per-engine map: it is what an engine with no
    /// stored level starts at.
    public let responseLength: String
    /// ⚠️ Clamped to `0...1` server-side. The wire value is a JSON number and is
    /// decoded as `Double` rather than as a string, unlike the STORED persona's
    /// `temperature`, which existing rows carry as either.
    public let temperature: Double
}
