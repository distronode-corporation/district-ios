@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The persona form's language and answer-length rules, which are correctness rules rather
/// than layout ones.
///
/// ⛔ EVERY ASSERTION HERE IS ABOUT A FAILURE THAT ANSWERS 200. `PATCH workspace/persona`
/// COERCES rather than rejects, and a `responseLength` sent without a `modelId` is
/// discarded outright. Nothing reports any of it.
///
/// ⛔ AND NONE OF THEM MAY MOVE THE ENGINE. The engine, the voice and the tuning are the
/// Voice Studio's; this form only ever sends the STORED engine id, beside an answer length.
///
/// ⚠️ THE CATALOGUE IS DECODED FROM JSON RATHER THAN BUILT, because `PersonaOptions`'
/// memberwise initialisers are internal to `DistrictModel` and because decoding is what
/// the app does. Three engines, two language lists and three voice pairs carry every
/// asymmetry the rules turn on.
final class PersonaIdentityDraftTests: XCTestCase {
    // MARK: - Hydration

    /// ⛔ A WORKSPACE THAT HAS NEVER CHOSEN SHOWS NOTHING CHOSEN, AND IS NOT DIRTY.
    func testAnUnconfiguredPersonaOpensUnsetAndClean() throws {
        let draft = try Self.draft(persona: "{}")
        XCTAssertEqual(draft.modelId, "")
        XCTAssertEqual(draft.values.language, "")
        XCTAssertEqual(draft.values.voice, "")
        XCTAssertEqual(draft.values.responseLength, "concise")
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.write, PersonaIdentityWrite())
    }

    func testAStoredPersonaOpensOnItsOwnValues() throws {
        let draft = try Self.draft(persona: Self.storedPersona)
        XCTAssertEqual(draft.modelId, "deepgram-pipeline")
        XCTAssertEqual(draft.values.language, "it-IT")
        XCTAssertEqual(draft.values.voice, "aura-2-melia-it")
        // ⛔ The level is the STORED engine's own entry of the per-engine map.
        XCTAssertEqual(draft.values.responseLength, "detailed")
        XCTAssertFalse(draft.isDirty)
    }

    /// ⚠️ A STORED ENGINE WITH NO STORED VOICE OPENS ON THE PUBLISHED DEFAULT, which is not an
    /// edit: a blank voice saved as `""` would be a cleared one.
    func testAMissingVoiceOpensOnThePublishedDefault() throws {
        let draft = try Self.draft(persona: #"{"modelId":"deepgram-pipeline","language":"en-US"}"#)
        XCTAssertEqual(draft.values.voice, "aura-2-asteria-en")
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - What the pickers offer

    /// ⛔ THE SHORT LIST IS NOT A SUBSET OF THE LONG ONE, and the list is the STORED engine's.
    func testTheLanguagesAreTheStoredEnginesOwn() throws {
        XCTAssertEqual(try Self.draft(persona: Self.storedPersona).languages.map(\.value), ["en-US", "it-IT"])
        let gemini = try Self.draft(persona: #"{"modelId":"gemini-live-2.5-flash-native-audio"}"#)
        XCTAssertEqual(gemini.languages.map(\.value), ["en-US", "hi-IN"])
        XCTAssertEqual(gemini.responseLengths.map(\.value), ["concise", "balanced", "detailed"])
    }

    func testAnEngineTheCatalogueDoesNotCarryOffersNoLevels() throws {
        let draft = try Self.draft(persona: #"{"modelId":"retired-pipeline"}"#)
        XCTAssertTrue(draft.responseLengths.isEmpty)
    }

    // MARK: - What moving one control does to the others

    /// ⛔ THE LANGUAGE MOVES THE VOICE FOR THE LANGUAGE-KEYED ENGINE ONLY. A Deepgram voice id
    /// encodes its own language and cannot speak another.
    func testTheLanguageMovesTheVoiceOnlyForTheLanguageKeyedEngine() throws {
        var deepgram = try Self.draft(persona: Self.storedPersona)
        deepgram.selectLanguage("en-US")
        XCTAssertEqual(deepgram.values.voice, "aura-2-asteria-en")

        var gemini = try Self.draft(persona: #"{"modelId":"gemini-live-2.5-flash-native-audio","voice":"Kore"}"#)
        gemini.selectLanguage("hi-IN")
        XCTAssertEqual(gemini.values.voice, "Kore")
    }

    /// ⚠️ A LANGUAGE WITH NO PUBLISHED VOICE LEAVES THE VOICE ALONE rather than clearing it.
    func testALanguageWithNoPublishedVoiceLeavesTheVoiceAlone() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.selectLanguage("nl-NL")
        XCTAssertEqual(draft.values.voice, "aura-2-melia-it")
    }

    // MARK: - What a save may name

    /// ⛔ ONLY WHAT CHANGED, AND NEVER AN ENGINE OF ITS OWN.
    func testALanguageChangeNamesTheLanguageAndTheVoiceItMoved() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.selectLanguage("en-US")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.write, PersonaIdentityWrite(language: "en-US", voice: "aura-2-asteria-en"))
    }

    /// ⛔ `responseLength` NEVER TRAVELS ALONE: it carries the STORED engine id as its key.
    func testTheAnswerLengthCarriesTheStoredEngine() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.selectResponseLength("concise")
        XCTAssertEqual(draft.write, PersonaIdentityWrite(modelId: "deepgram-pipeline", responseLength: "concise"))
        draft.selectResponseLength("detailed")
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.write, PersonaIdentityWrite())
    }

    /// ⛔ AND IT IS DROPPED OUTRIGHT WHEN THERE IS NO ENGINE TO KEY IT ON.
    func testTheAnswerLengthIsNotSentWithoutAnEngine() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectResponseLength("detailed")
        XCTAssertEqual(draft.write, PersonaIdentityWrite())
    }

    /// ⛔ A VOCABULARY FIELD IS NEVER CLEARED TO `""`.
    func testAnEmptiedLanguageIsNotSentAsAClear() throws {
        var draft = try Self.draft(persona: #"{"modelId":"gemini-live-2.5-flash-native-audio","language":"en-US"}"#)
        draft.selectLanguage("")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.write.language)
    }

    // MARK: - The preview form

    /// ⛔ THE FORM AS IT STANDS PLUS THE STORED ENGINE SETTINGS: the preview merges against
    /// nothing, so an omitted engine key would audition the agent's own fallback.
    func testThePreviewCarriesTheFormAndTheStoredEngine() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.selectLanguage("en-US")
        let form = draft.previewForm(name: "Ada", greeting: "", personality: "Warm")
        XCTAssertEqual(form.name, "Ada")
        XCTAssertNil(form.greeting)
        XCTAssertEqual(form.language, "en-US")
        XCTAssertEqual(form.voice, "aura-2-asteria-en")
        XCTAssertEqual(form.modelId, "deepgram-pipeline")
        XCTAssertEqual(form.responseLength, "detailed")
        XCTAssertEqual(form.temperature, 0.2)
        XCTAssertEqual(form.voiceStyle, "en-GB-Studio-B")
        XCTAssertEqual(form.preemptiveTts, true)

        let unset = try Self.draft(persona: "{}").previewForm(name: "", greeting: "", personality: "")
        XCTAssertEqual(unset.temperature, 0.7)
        XCTAssertNil(unset.voiceStyle)
        XCTAssertEqual(unset.preemptiveTts, false)
    }

    // MARK: - Fixtures

    private static func draft(persona json: String) throws -> PersonaIdentityDraft {
        try PersonaIdentityDraft(
            persona: JSONDecoder().decode(AiPersona.self, from: Data(json.utf8)),
            options: JSONDecoder().decode(PersonaOptionsResponse.self, from: Data(catalogue.utf8))
        )
    }

    private static let storedPersona = #"""
    {"name":"Ada","greeting":"Thanks for calling.","personality":"Warm",
     "voice":"aura-2-melia-it","language":"it-IT","modelId":"deepgram-pipeline",
     "responseLength":{"deepgram-pipeline":"detailed","gemini-live-2.5-flash-native-audio":"balanced"},
     "temperature":0.2,"voiceStyle":"en-GB-Studio-B","preemptiveTts":true}
    """#

    /// ⚠️ THREE ENGINES, TWO OF THEM IN REGION, AND THE TWO LANGUAGE LISTS DELIBERATELY
    /// DISAGREE — `it-IT` on Deepgram only, `hi-IN` on the general list only. Every rule
    /// under test turns on one of those asymmetries.
    private static let catalogue = #"""
    {"success":true,"region":"us",
     "engines":[
       {"id":"gemini-live-2.5-flash-native-audio","label":"Gemini 2.5 Live — US (processed in your region)",
        "inRegion":true,"responseLengths":[{"value":"concise","label":"Concise"},
        {"value":"balanced","label":"Balanced"},{"value":"detailed","label":"Detailed"}]},
       {"id":"deepgram-pipeline","label":"Deepgram Pipeline — US (processed in your region)",
        "inRegion":true,"responseLengths":[{"value":"concise","label":"Concise"},
        {"value":"balanced","label":"Balanced"},{"value":"detailed","label":"Detailed"}]},
       {"id":"elevenlabs-pipeline","label":"ElevenLabs Pipeline — EU (processed outside your region)",
        "inRegion":false,"responseLengths":[{"value":"concise","label":"Concise"}]}],
     "languages":{"deepgram":[{"value":"en-US","label":"English (US)"},{"value":"it-IT","label":"Italian"}],
                  "general":[{"value":"en-US","label":"English (US)"},{"value":"hi-IN","label":"Hindi"}]},
     "voices":[
       {"engine":"gemini-live-2.5-flash-native-audio","language":"en-US",
        "groups":[{"label":"Voices","options":[{"value":"Puck","label":"Puck"},{"value":"Kore","label":"Kore"}]}]},
       {"engine":"deepgram-pipeline","language":"en-US",
        "groups":[{"label":"Feminine","options":[{"value":"aura-2-asteria-en","label":"Asteria"}]}]},
       {"engine":"deepgram-pipeline","language":"it-IT",
        "groups":[{"label":"Feminine","options":[{"value":"aura-2-melia-it","label":"Melia"}]}]}],
     "voiceStyles":[{"value":"en-GB-Studio-B","label":"British studio"}],
     "defaults":{"voiceByEngine":{"gemini-live-2.5-flash-native-audio":"Puck",
                                  "deepgram-pipeline":"aura-2-asteria-en",
                                  "elevenlabs-pipeline":"pNInz6obpgDQGcFmaJgB"},
                 "voiceByDeepgramLanguage":{"en-US":"aura-2-asteria-en","it-IT":"aura-2-melia-it"},
                 "responseLength":"concise","temperature":0.7}}
    """#
}
