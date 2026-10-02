@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The persona form's picker rules, which are correctness rules rather than layout
/// ones.
///
/// ⛔ EVERY ASSERTION HERE IS ABOUT A FAILURE THAT ANSWERS 200. `PATCH
/// workspace/persona` COERCES rather than rejects: an unrecognised `modelId` becomes
/// `deepgram-pipeline`, an unrecognised `voice` is stored verbatim and then replaced by
/// the agent's own fallback at synthesis time, and a `responseLength` sent without a
/// `modelId` is discarded outright. Nothing reports any of it. So a wrong answer in this
/// file is not a red screen — it is a workspace speaking in a voice nobody chose, found
/// out by a customer.
///
/// ⚠️ THE CATALOGUE IS DECODED FROM JSON RATHER THAN BUILT, because `PersonaOptions`'
/// memberwise initialisers are internal to `DistrictModel` and because decoding is what
/// the app does. The body is the committed contract fixture's shape narrowed to three
/// engines, two language lists and three voice pairs — enough to carry every asymmetry
/// the rules turn on.
final class PersonaEngineDraftTests: XCTestCase {
    // MARK: - Hydration

    /// ⛔ A WORKSPACE THAT HAS NEVER CHOSEN SHOWS NOTHING CHOSEN, AND IS NOT DIRTY. The
    /// web opens on `deepgram-pipeline`/`en-US`/`aura-2-asteria-en` literals; publishing
    /// those as a Swift default would be a second copy of three values with nothing
    /// comparing them, and on a dirty-field save it would WRITE them for an operator who
    /// only came to change the greeting.
    func testAnUnconfiguredPersonaOpensUnsetAndClean() throws {
        let draft = try Self.draft(persona: "{}")
        XCTAssertEqual(draft.values.modelId, "")
        XCTAssertEqual(draft.values.language, "")
        XCTAssertEqual(draft.values.voice, "")
        XCTAssertTrue(draft.changes.isEmpty)
        XCTAssertEqual(draft.write, PersonaEngineWrite())
    }

    /// ⚠️ THE TWO FIELDS THE SERVER DOES PUBLISH A DEFAULT FOR OPEN ON IT, and still are
    /// not dirty — which is the whole reason the baseline is a snapshot rather than the
    /// stored row.
    func testThePublishedDefaultsFillTheTwoFieldsThatNeedANumber() throws {
        let draft = try Self.draft(persona: "{}")
        XCTAssertEqual(draft.values.temperature, 0.7)
        XCTAssertEqual(draft.values.responseLength, "concise")
        XCTAssertTrue(draft.changes.isEmpty)
    }

    func testAStoredPersonaOpensOnItsOwnValues() throws {
        let draft = try Self.draft(persona: Self.storedPersona)
        XCTAssertEqual(draft.values.modelId, "deepgram-pipeline")
        XCTAssertEqual(draft.values.language, "it-IT")
        XCTAssertEqual(draft.values.voice, "aura-2-melia-it")
        XCTAssertEqual(draft.values.temperature, 0.2)
        XCTAssertEqual(draft.values.voiceStyle, "en-GB-Studio-B")
        XCTAssertTrue(draft.values.preemptiveTts)
        XCTAssertTrue(draft.changes.isEmpty)
    }

    /// ⛔ THE LEVEL IS READ FOR THE STORED ENGINE, NOT FOR WHICHEVER KEY IS FIRST. It is
    /// a per-engine map, and reading the wrong entry would show one engine's setting
    /// under another's name.
    func testTheAnswerLengthIsTheStoredEnginesOwn() throws {
        let draft = try Self.draft(persona: Self.storedPersona)
        XCTAssertEqual(draft.values.responseLength, "detailed")
    }

    // MARK: - What the pickers offer

    /// ⛔ THE SHORT LIST IS NOT A SUBSET OF THE LONG ONE. Deepgram publishes `it-IT` and
    /// no `hi-IN`; the general list is the other way round. One list for every engine
    /// would offer Hindi on Deepgram, whose voice catalogue for it is empty.
    func testEachEngineOffersItsOwnLanguageList() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("deepgram-pipeline")
        XCTAssertEqual(draft.languages.map(\.value), ["en-US", "it-IT"])
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        XCTAssertEqual(draft.languages.map(\.value), ["en-US", "hi-IN"])
    }

    func testTheVoicesAreLookedUpByEngineAndLanguageTogether() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("deepgram-pipeline")
        draft.selectLanguage("it-IT")
        XCTAssertEqual(draft.voiceGroups.flatMap { $0.options.map(\.value) }, ["aura-2-melia-it"])
        draft.selectLanguage("en-US")
        XCTAssertEqual(draft.voiceGroups.flatMap { $0.options.map(\.value) }, ["aura-2-asteria-en"])
    }

    /// ⚠️ AN EMPTY VOICE LIST IS A REAL ANSWER rather than a failed read: a stored
    /// persona can name a language its engine does not publish, and rows like that
    /// exist because the save route never refused one.
    func testAPairWithNoPublishedVoicesIsEmptyRatherThanSubstituted() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        draft.selectLanguage("hi-IN")
        XCTAssertTrue(draft.voiceGroups.isEmpty)
    }

    /// ⛔ THE STYLE PICKER IS THE REALTIME ENGINE'S AND THE PRE-EMPTIVE TOGGLE IS EVERY
    /// OTHER ENGINE'S. Each is a setting the other engine accepts, stores and IGNORES,
    /// with a 200 — a control that silently does nothing.
    func testTheTwoEngineSpecificControlsAppearForOppositeEngines() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        XCTAssertTrue(draft.capabilities.showsVoiceStyle)
        XCTAssertFalse(draft.capabilities.showsPreemptiveTts)
        draft.selectEngine("deepgram-pipeline")
        XCTAssertFalse(draft.capabilities.showsVoiceStyle)
        XCTAssertTrue(draft.capabilities.showsPreemptiveTts)
    }

    /// ⛔ AN OUT-OF-REGION ENGINE IS PUBLISHED AND IS NOT SELECTABLE. The picker draws
    /// every engine so its label can state where the audio would be processed; the
    /// selectable set is the one a selection is validated against.
    func testEveryEngineIsOfferedForDisplayAndOnlyTheInRegionOnesAreSelectable() throws {
        let draft = try Self.draft(persona: "{}")
        XCTAssertEqual(draft.engines.count, 3)
        XCTAssertEqual(
            draft.options.engines.filter(\.inRegion).map(\.id),
            ["gemini-live-2.5-flash-native-audio", "deepgram-pipeline"]
        )
    }

    // MARK: - What moving one control does to the others

    /// ⛔ THE VOICE MOVES WITH THE ENGINE. A voice id belongs to one engine, and the save
    /// route would store `Puck` under Deepgram happily.
    func testChoosingAnEngineTakesItsOwnStartingVoice() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        XCTAssertEqual(draft.values.voice, "Puck")
        draft.selectEngine("deepgram-pipeline")
        XCTAssertEqual(draft.values.voice, "aura-2-asteria-en")
    }

    /// ⛔ A LANGUAGE THE NEW ENGINE DOES NOT PUBLISH IS DROPPED AND NOT GUESSED AT. The
    /// web substitutes `en-US`; nothing on the wire publishes a default language, so the
    /// honest answer is an empty picker the operator can see.
    func testSwitchingToAnEngineThatCannotSpeakTheLanguageClearsIt() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        draft.selectLanguage("hi-IN")
        draft.selectEngine("deepgram-pipeline")
        XCTAssertEqual(draft.values.language, "")
    }

    func testSwitchingToAnEngineThatDoesSpeakTheLanguageKeepsIt() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        draft.selectLanguage("en-US")
        draft.selectEngine("deepgram-pipeline")
        XCTAssertEqual(draft.values.language, "en-US")
    }

    /// ⛔ THE LANGUAGE MOVES THE VOICE FOR THE LANGUAGE-KEYED ENGINE ONLY. A Deepgram
    /// voice id encodes its own language and cannot speak another; every other engine
    /// speaks its whole catalogue.
    func testTheLanguageMovesTheVoiceOnlyForTheLanguageKeyedEngine() throws {
        var draft = try Self.draft(persona: "{}")
        draft.selectEngine("deepgram-pipeline")
        draft.selectLanguage("it-IT")
        XCTAssertEqual(draft.values.voice, "aura-2-melia-it")

        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        draft.selectLanguage("en-US")
        draft.values.voice = "Kore"
        draft.selectLanguage("hi-IN")
        XCTAssertEqual(draft.values.voice, "Kore")
    }

    /// ⛔ THE ANSWER LENGTH SWAPS TO THE NEW ENGINE'S SAVED LEVEL AND IS NOT DIRTY FOR
    /// HAVING DONE SO. Carrying the old engine's across is how a tenant's terse pipeline
    /// silently retunes the realtime brain; reporting the swap as a change is how it
    /// gets written.
    func testTheAnswerLengthFollowsTheEngineWithoutCountingAsAnEdit() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        XCTAssertEqual(draft.values.responseLength, "detailed")
        draft.selectEngine("gemini-live-2.5-flash-native-audio")
        XCTAssertEqual(draft.values.responseLength, "balanced")
        XCTAssertFalse(draft.changes.responseLength)
        draft.selectEngine("deepgram-pipeline")
        XCTAssertEqual(draft.values.responseLength, "detailed")
        XCTAssertFalse(draft.changes.responseLength)
    }

    /// ⚠️ AN ENGINE WITH NO SAVED LEVEL FALLS BACK TO THE SERVER'S PUBLISHED DEFAULT,
    /// never to a Swift literal.
    func testAnEngineWithNoSavedLevelTakesThePublishedDefault() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.selectEngine("elevenlabs-pipeline")
        XCTAssertEqual(draft.values.responseLength, "concise")
    }

    // MARK: - What a save may name

    /// ⛔ ONLY WHAT CHANGED. The route preserves every key a request omits, so naming an
    /// untouched field is how a phone overwrites an engine choice it never showed.
    func testOnlyChangedFieldsAreNamed() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.values.temperature = 0.9
        let write = draft.write
        XCTAssertEqual(write.temperature, 0.9)
        XCTAssertNil(write.voice)
        XCTAssertNil(write.language)
        XCTAssertNil(write.modelId)
        XCTAssertNil(write.voiceStyle)
        XCTAssertNil(write.preemptiveTts)
    }

    /// ⚠️ A SLIDER DRAGGED AWAY AND BACK IS NOT AN EDIT. The value is arithmetic on a
    /// `Double`, so exact equality would report float noise as a change and write it.
    func testATemperatureReturnedToItsStartIsNotAChange() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.values.temperature = 0.2 + 0.1 - 0.1
        XCTAssertFalse(draft.changes.temperature)
        XCTAssertNil(draft.write.temperature)
    }

    /// ⛔ `responseLength` NEVER TRAVELS ALONE. The route writes it under
    /// `aiPersona.responseLength[modelId]` and refuses to guess at the stored engine, so
    /// without an accepted engine id in the SAME request it writes nothing and answers
    /// 200 — the operator's edit vanishing under a success banner.
    func testTheAnswerLengthAlwaysCarriesItsEngineEvenWhenTheEngineDidNotChange() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.values.responseLength = "concise"
        let write = draft.write
        XCTAssertEqual(write.responseLength, "concise")
        XCTAssertEqual(write.modelId, "deepgram-pipeline")
    }

    /// ⛔ AND IT IS DROPPED OUTRIGHT WHEN THERE IS NO ENGINE TO KEY IT ON, rather than
    /// sent to be silently discarded.
    func testTheAnswerLengthIsNotSentWithoutAnEngine() throws {
        var draft = try Self.draft(persona: "{}")
        draft.values.responseLength = "detailed"
        XCTAssertNil(draft.write.responseLength)
        XCTAssertNil(draft.write.modelId)
    }

    /// ⛔ A VOCABULARY FIELD IS NEVER CLEARED TO `""`. The three text fields work the
    /// other way round — an empty greeting is a deliberate clear — but an empty VOICE
    /// would be stored and the agent would fall back to one nobody chose.
    func testAnEmptiedVocabularyFieldIsNotSentAsAClear() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.values.voice = ""
        draft.values.voiceStyle = ""
        XCTAssertTrue(draft.changes.voice)
        XCTAssertNil(draft.write.voice)
        XCTAssertNil(draft.write.voiceStyle)
    }

    /// ⛔ A STORED VOICE THE CATALOGUE HAS DROPPED IS FLAGGED, NOT CORRECTED. It is what
    /// the workspace speaks in today.
    func testAVoiceOutsideTheCatalogueIsReportedRatherThanReplaced() throws {
        let draft = try Self
            .draft(persona: #"{"modelId":"deepgram-pipeline","language":"en-US","voice":"aura-2-retired-en"}"#)
        XCTAssertTrue(draft.voiceIsOffCatalogue)
        XCTAssertEqual(draft.values.voice, "aura-2-retired-en")
        XCTAssertTrue(draft.changes.isEmpty)
    }

    // MARK: - The preview form

    /// ⛔ THE FORM AS IT STANDS, DIRTY FIELDS INCLUDED, which is the whole point of the
    /// preview route: the agent reads this blob out of the token metadata, so sending
    /// the saved persona would answer a different question convincingly.
    func testThePreviewCarriesTheUnsavedFormAndOmitsWhatIsUnset() throws {
        var draft = try Self.draft(persona: Self.storedPersona)
        draft.values.temperature = 0.9
        let form = draft.previewForm(name: "Ada", greeting: "", personality: "Warm")
        XCTAssertEqual(form.name, "Ada")
        XCTAssertNil(form.greeting)
        XCTAssertEqual(form.modelId, "deepgram-pipeline")
        XCTAssertEqual(form.voice, "aura-2-melia-it")
        XCTAssertEqual(form.responseLength, "detailed")
        XCTAssertEqual(form.temperature, 0.9)
        XCTAssertEqual(form.preemptiveTts, true)
    }

    // MARK: - Fixtures

    private static func draft(persona json: String) throws -> PersonaEngineDraft {
        try PersonaEngineDraft(
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
