// ⚠️ `@testable` FOR THE MEMBERWISE INITIALISERS AND FOR NOTHING ELSE. These DTOs
// are `public struct`s with `public let` members, so their synthesised memberwise
// initialiser is INTERNAL — a plain import can decode one and cannot build one. The
// real decode is proven against the real fixture in `ContractFixtureTests`; what is
// built here are deliberately small catalogues shaped to make each lookup rule fail
// loudly if it is reversed. `ApiErrorTests` and `PushPayloadTests` do the same.
@testable import DistrictModel
import Foundation
import XCTest

/// The persona catalogue, decoded and then READ.
///
/// ⛔ THE DECODE IS NOT THE INTERESTING HALF AND IS NOT TESTED HERE. `ContractFixtureTests`
/// already runs the real 2,970-line fixture through `StrictDecodeVerifier`, which
/// re-encodes and compares key sets per path — a stronger assertion than anything this
/// file could write by hand. What is untested by that is the set of RULES a picker
/// follows, every one of which the server will decline to contradict: `PATCH
/// workspace/persona` coerces an unknown engine and stores an unknown voice verbatim,
/// both with a 200.
///
/// ⚠️ THE FIXTURES BELOW ARE DELIBERATELY SMALL AND DELIBERATELY NOT THE REAL
/// CATALOGUE. Pinning `aura-2-asteria-en` here would recreate the drifting second
/// catalogue the options route exists to retire; what is pinned is the SHAPE of the
/// lookups, against values chosen to make each rule fail loudly if it is reversed.
final class PersonaOptionsTests: XCTestCase {
    // MARK: - Fixtures

    private static let deepgram = PersonaOptionsResponse.languageKeyedEngine
    private static let gemini = PersonaEngineCapabilities.geminiLiveEngine

    private func option(_ value: String) -> PersonaLabelledValue {
        PersonaLabelledValue(value: value, label: "label-\(value)")
    }

    private func engine(_ id: String, inRegion: Bool) -> PersonaEngineOption {
        PersonaEngineOption(
            id: id,
            label: "label-\(id)",
            inRegion: inRegion,
            responseLengths: [option("concise"), option("balanced")]
        )
    }

    private func catalogue(
        engines: [PersonaEngineOption]? = nil,
        voices: [PersonaVoiceCatalog]? = nil
    ) -> PersonaOptionsResponse {
        PersonaOptionsResponse(
            success: true,
            region: "us",
            engines: engines ?? [
                engine(Self.deepgram, inRegion: true),
                engine(Self.gemini, inRegion: true),
                engine("cartesia-pipeline", inRegion: false),
            ],
            languages: PersonaLanguageCatalog(
                // ⚠️ NEITHER LIST IS A SUBSET OF THE OTHER, which is the shape of the
                // real catalogues (`nl-NL`/`it-IT` are Deepgram-only, `hi-IN` is not on
                // Deepgram at all) and the reason a single shared list would be wrong.
                deepgram: [option("en-US"), option("nl-NL")],
                general: [option("en-US"), option("hi-IN")]
            ),
            voices: voices ?? [
                PersonaVoiceCatalog(
                    engine: Self.deepgram,
                    language: "en-US",
                    groups: [PersonaVoiceGroup(label: "Feminine", options: [option("dg-en-1")])]
                ),
                PersonaVoiceCatalog(
                    engine: Self.deepgram,
                    language: "nl-NL",
                    groups: [PersonaVoiceGroup(label: "Dutch", options: [option("dg-nl-1")])]
                ),
                PersonaVoiceCatalog(
                    engine: Self.gemini,
                    language: "en-US",
                    groups: [PersonaVoiceGroup(label: "Voices", options: [option("Puck"), option("Kore")])]
                ),
            ],
            voiceStyles: [option("en-GB-Studio-B")],
            defaults: PersonaDefaults(
                voiceByEngine: [Self.deepgram: "dg-en-1", Self.gemini: "Puck"],
                voiceByDeepgramLanguage: ["en-US": "dg-en-1", "nl-NL": "dg-nl-1"],
                responseLength: "concise",
                temperature: 0.7
            )
        )
    }

    // MARK: - Which engines may be chosen

    /// ⛔ THE OUT-OF-REGION ENGINE IS PUBLISHED AND NOT SELECTABLE, which is the
    /// whole reason both accessors exist. A picker that filtered the list would
    /// leave an operator unable to see why their region offers fewer choices; a
    /// picker that offered it would make a residency decision on a settings screen
    /// with a 200 and no error.
    func testEveryEngineIsPublishedAndOnlyTheInRegionOnesAreSelectable() {
        let options = catalogue()
        XCTAssertEqual(options.engines.count, 3)
        XCTAssertEqual(options.selectableEngines.map(\.id), [Self.deepgram, Self.gemini])
    }

    func testAnUnknownEngineIdResolvesToNothingRatherThanToTheFirst() {
        XCTAssertNil(catalogue().engine("langchain-pipeline"))
        XCTAssertNil(catalogue().engine(nil))
        XCTAssertEqual(catalogue().engine(Self.gemini)?.id, Self.gemini)
    }

    // MARK: - Which languages

    /// ⛔ THE TWO LISTS DIFFER IN BOTH DIRECTIONS. Showing the general list on
    /// Deepgram offers Hindi, whose Deepgram voice catalogue is empty — so the voice
    /// picker below it would be blank and the save would store a language the engine
    /// cannot speak.
    func testDeepgramGetsItsOwnLanguageListAndEverythingElseGetsTheGeneralOne() {
        let options = catalogue()
        XCTAssertEqual(options.languages(forEngine: Self.deepgram).map(\.value), ["en-US", "nl-NL"])
        XCTAssertEqual(options.languages(forEngine: Self.gemini).map(\.value), ["en-US", "hi-IN"])
    }

    /// ⚠️ AN ENGINE THIS BUILD HAS NEVER HEARD OF GETS THE GENERAL LIST, matching the
    /// server's own ternary rather than answering nothing.
    func testAnUnknownEngineGetsTheGeneralLanguageList() {
        XCTAssertEqual(catalogue().languages(forEngine: "who-knows").map(\.value), ["en-US", "hi-IN"])
        XCTAssertEqual(catalogue().languages(forEngine: nil).map(\.value), ["en-US", "hi-IN"])
    }

    // MARK: - Which voices

    func testVoicesAreLookedUpByEngineAndLanguageTogether() {
        let options = catalogue()
        XCTAssertEqual(
            options.voiceGroups(engine: Self.deepgram, language: "nl-NL").flatMap { $0.options.map(\.value) },
            ["dg-nl-1"]
        )
        XCTAssertEqual(
            options.voiceGroups(engine: Self.gemini, language: "en-US").flatMap { $0.options.map(\.value) },
            ["Puck", "Kore"]
        )
    }

    /// ⛔ A PAIR WITH NO CATALOGUE IS EMPTY, NOT A FALLBACK TO THE ENGINE'S OTHER
    /// LANGUAGE. A stored persona genuinely can name a language its engine does not
    /// publish — the save route never refused one — and quietly showing another
    /// language's voices is how an operator picks one that cannot speak theirs.
    func testAnUnpublishedPairHasNoVoicesRatherThanTheWrongOnes() {
        XCTAssertTrue(catalogue().voiceGroups(engine: Self.gemini, language: "hi-IN").isEmpty)
        XCTAssertTrue(catalogue().voiceGroups(engine: Self.deepgram, language: nil).isEmpty)
        XCTAssertTrue(catalogue().voiceGroups(engine: nil, language: "en-US").isEmpty)
    }

    func testVoiceExistenceIsAskedOfTheEngineAndLanguageInPlay() {
        let options = catalogue()
        XCTAssertTrue(options.voiceExists("dg-nl-1", engine: Self.deepgram, language: "nl-NL"))
        // ⛔ THE SAME ID UNDER A DIFFERENT LANGUAGE IS NOT PRESENT, which is what makes
        // this a real check rather than a membership test against the whole corpus.
        XCTAssertFalse(options.voiceExists("dg-nl-1", engine: Self.deepgram, language: "en-US"))
        XCTAssertFalse(options.voiceExists(nil, engine: Self.deepgram, language: "en-US"))
    }

    // MARK: - Which voice a switch lands on

    /// ⛔ THE PER-LANGUAGE MAP WINS FOR DEEPGRAM. A Deepgram voice id encodes its own
    /// language — `dg-en-1` cannot speak Dutch — and the save route stores the
    /// mismatch happily, so switching language has to move the voice with it.
    func testDeepgramTakesItsDefaultFromTheLanguageAndNotFromTheEngine() {
        let options = catalogue()
        XCTAssertEqual(options.defaultVoice(engine: Self.deepgram, language: "nl-NL"), "dg-nl-1")
        XCTAssertEqual(options.defaultVoice(engine: Self.deepgram, language: "en-US"), "dg-en-1")
    }

    /// ⚠️ EVERY OTHER ENGINE KEEPS ONE STARTING VOICE, so its language picker does not
    /// touch the voice.
    func testEveryOtherEngineTakesItsDefaultFromTheEngineWhateverTheLanguage() {
        let options = catalogue()
        XCTAssertEqual(options.defaultVoice(engine: Self.gemini, language: "en-US"), "Puck")
        XCTAssertEqual(options.defaultVoice(engine: Self.gemini, language: "hi-IN"), "Puck")
    }

    /// ⛔ nil IS "THE SERVER PUBLISHED NO DEFAULT", NEVER `""`. A caller leaves the
    /// field alone; clearing it would save an empty string and drop the agent onto a
    /// voice nobody chose.
    func testNoPublishedDefaultAnswersNilRatherThanAnEmptyString() {
        let options = catalogue()
        XCTAssertNil(options.defaultVoice(engine: "cartesia-pipeline", language: "en-US"))
        XCTAssertNil(options.defaultVoice(engine: Self.deepgram, language: "hi-IN"))
        XCTAssertNil(options.defaultVoice(engine: nil, language: "en-US"))
    }

    // MARK: - Answer lengths

    func testAnswerLengthsComeFromTheEngineAndAreEmptyForAnUnknownOne() {
        let options = catalogue()
        XCTAssertEqual(options.responseLengths(forEngine: Self.deepgram).map(\.value), ["concise", "balanced"])
        XCTAssertTrue(options.responseLengths(forEngine: "langchain-pipeline").isEmpty)
        XCTAssertTrue(options.responseLengths(forEngine: nil).isEmpty)
    }

    // MARK: - What each engine's controls do

    /// ⛔ THE TWO FLAGS ARE OPPOSITES AND NEITHER IS "the engine supports it". Both
    /// engines ACCEPT both fields and one of the two ignores each — with a 200 — so a
    /// control shown to the wrong engine is a setting that silently does nothing.
    func testTheStyleAndSpeculationControlsBelongToOppositeEngines() {
        let gemini = PersonaEngineCapabilities(engineId: Self.gemini)
        XCTAssertTrue(gemini.showsVoiceStyle)
        XCTAssertFalse(gemini.showsPreemptiveTts)

        let chained = PersonaEngineCapabilities(engineId: Self.deepgram)
        XCTAssertFalse(chained.showsVoiceStyle)
        XCTAssertTrue(chained.showsPreemptiveTts)
    }

    /// ⚠️ A nil OR UNRECOGNISED ENGINE IS TREATED AS A CHAINED PIPELINE, which is what
    /// the web's `!==` comparison does and what every engine but one actually is.
    func testAnUnknownEngineIsTreatedAsChainedRatherThanAsRealtime() {
        let unknown = PersonaEngineCapabilities(engineId: nil)
        XCTAssertFalse(unknown.showsVoiceStyle)
        XCTAssertTrue(unknown.showsPreemptiveTts)
        XCTAssertFalse(unknown.languageSelectsVoice)
    }

    func testOnlyDeepgramLetsALanguageChoiceMoveTheVoice() {
        XCTAssertTrue(PersonaEngineCapabilities(engineId: Self.deepgram).languageSelectsVoice)
        XCTAssertFalse(PersonaEngineCapabilities(engineId: Self.gemini).languageSelectsVoice)
    }

    // MARK: - The routing rule vocabularies

    /// ⛔ THE RULE VOICE LIST IS DERIVED FROM THE GEMINI LIVE CATALOGUE RATHER THAN
    /// HARDCODED. The web form holds those five names in a literal; the sibling
    /// literal beside it (its MODEL list) went stale and made an engine unreachable
    /// from a rule, which is the argument for deriving both.
    func testRoutingVoicesComeFromTheRealtimeCatalogue() {
        XCTAssertEqual(catalogue().routingVoices().map(\.value), ["Puck", "Kore"])
    }

    /// ⚠️ EMPTY IS A REAL ANSWER: a rule's stored voice is then shown as-is and cannot
    /// be changed, which is honest rather than offering a substitute.
    func testRoutingVoicesAreEmptyWhenTheRealtimeEngineIsAbsent() {
        let withoutGemini = catalogue(voices: [
            PersonaVoiceCatalog(
                engine: Self.deepgram,
                language: "en-US",
                groups: [PersonaVoiceGroup(label: "Feminine", options: [option("dg-en-1")])]
            ),
        ])
        XCTAssertTrue(withoutGemini.routingVoices().isEmpty)
    }

    /// ⛔ A RULE MAY NAME ANY ENGINE, INCLUDING AN OUT-OF-REGION ONE, AND THE FILTER IS
    /// THE CALLER'S. The web's rule form shows no region badge at all; this returns the
    /// unfiltered list so the two screens cannot disagree about what exists.
    func testRoutingEnginesAreNotPreFilteredByRegion() {
        XCTAssertEqual(catalogue().routingEngines().count, 3)
    }

    // MARK: - Identifiable

    /// The two `Identifiable` conformances exist so SwiftUI pickers can key rows without a
    /// wrapper type. They are one line each and were the only lines in this module nothing
    /// executed, which is what dropped `DistrictModel` under its floor (99% at the time).
    func testPickerRowsAreIdentifiedByTheirWireValueAndGroupsByTheirLabel() {
        XCTAssertEqual(option("aura-2-asteria-en").id, "aura-2-asteria-en")
        let group = PersonaVoiceGroup(label: "Aura 2", options: [option("a"), option("b")])
        XCTAssertEqual(group.id, "Aura 2")
        XCTAssertEqual(group.options.map(\.id), ["a", "b"])
    }
}
