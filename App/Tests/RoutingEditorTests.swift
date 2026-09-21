@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The routing editor, asserted on the BYTES it sends.
///
/// ⛔ THE BYTES ARE THE ONLY PLACE THE ANSWER IS. `POST workspace/routing-rules`
/// REPLACES the stored array wholesale, its per-rule schema is `.passthrough()`, and the
/// column is `Json` holding two different row shapes today — so "was this rule carried
/// through unchanged" is a question about the encoded document, not about a typed model
/// anybody could inspect. A row rebuilt from the six keys this form owns would strip the
/// rest and be answered **200**: a silent deletion INSIDE somebody's rule.
///
/// ⚠️ THE EDITOR IS BUILT OVER A STUB TRANSPORT RATHER THAN AN `AppContainer`, which is
/// what the repository-taking initialiser exists for. Constructing a container in a unit
/// test would build the process's one token coordinator and resolve a keychain store to
/// ask a question about JSON.
@MainActor
final class RoutingEditorTests: XCTestCase {
    // MARK: - Hydration

    /// ⛔ A ROW THIS BUILD CANNOT READ IS SHOWN AND IS NOT DROPPED. The committed fixture
    /// carries `{id, match, action, target}` rows that the web's own rule builder does
    /// not edit either; they are live rules the agent evaluates today.
    func testItOpensEveryStoredRowIncludingTheOnesItCannotRead() async {
        let model = Self.model(Self.transport())
        await model.loadConfig()
        XCTAssertEqual(model.drafts?.count, 2)
        XCTAssertEqual(model.drafts?.first?.isRecognised, true)
        XCTAssertEqual(model.drafts?.last?.isRecognised, false)
        XCTAssertFalse(model.notEditable)
    }

    /// ⛔ A STORED VALUE THAT IS NOT AN ARRAY OF OBJECTS IS A THIRD STATE, NOT A FAILURE.
    /// Rows written before the server validated that column can hold anything.
    func testAValueThisClientCannotModelIsNotEditedAtAll() async {
        let model = Self.model(Self.transport(rules: #"["a string"]"#))
        await model.loadConfig()
        XCTAssertNil(model.drafts)
        XCTAssertTrue(model.notEditable)
    }

    /// ⚠️ AN ABSENT COLUMN IS AN EMPTY LIST, not an unreadable one.
    func testAWorkspaceWithNoRulesOpensOnAnEmptyEditor() async {
        let model = Self.model(Self.transport(rules: "null"))
        await model.loadConfig()
        XCTAssertEqual(model.drafts?.count, 0)
        XCTAssertFalse(model.notEditable)
    }

    // MARK: - The round trip

    /// ⛔ THE UNEDITED ROWS GO BACK EXACTLY AS THEY ARRIVED, KEYS THIS BUILD DOES NOT
    /// MODEL INCLUDED. `sector` is not one of the six the form owns, and the second row
    /// has none of them at all.
    func testEveryStoredRowSurvivesASaveByteForByte() async {
        let transport = Self.transport()
        let model = Self.model(transport)
        await model.loadConfig()
        await model.saveRules()

        let body = try? XCTUnwrap(transport.bodies.last)
        XCTAssertEqual(body?.contains(#""sector":"fintech""#), true, "an unmodelled key was dropped")
        XCTAssertEqual(body?.contains(#""action":"answer""#), true, "an unrecognised row was rewritten")
        XCTAssertEqual(body?.contains(#""target":"sales""#), true)
    }

    /// ⛔ AN EDIT OVERWRITES THE SIX KEYS THE FORM OWNS AND NOTHING ELSE.
    func testAnEditRewritesOnlyTheFieldsTheFormOwns() async {
        let transport = Self.transport()
        let model = Self.model(transport)
        await model.loadConfig()
        let id = try? XCTUnwrap(model.drafts?.first?.id)
        model.edit(id ?? 0) { $0.value = "logistics" }
        await model.saveRules()

        let body = try? XCTUnwrap(transport.bodies.last)
        XCTAssertEqual(body?.contains(#""value":"logistics""#), true)
        XCTAssertEqual(body?.contains(#""sector":"fintech""#), true)
    }

    /// ⛔ A ROW THIS BUILD CANNOT READ IS NOT OFFERED AN EDITOR, and the model refuses
    /// the write rather than relying on the view not to draw one. An editor over it would
    /// have to invent six keys and stamp them beside the four it could not read.
    func testAnUnrecognisedRowCannotBeEdited() async {
        let model = Self.model(Self.transport())
        await model.loadConfig()
        let id = try? XCTUnwrap(model.drafts?.last?.id)
        model.edit(id ?? 0) { $0.value = "nope" }
        XCTAssertEqual(model.drafts?.last?.value, "")
    }

    /// ⛔ AN ADDED ROW THAT WAS NEVER FILLED IN IS DROPPED, AND ONLY THAT. A row from the
    /// server is never blank by that test, because it carries its source — dropping one
    /// would be a deletion nobody asked for through a route that replaces the array.
    func testAnAbandonedNewRowIsNotSentAndTheStoredOnesStillAre() async {
        let transport = Self.transport()
        let model = Self.model(transport)
        await model.loadConfig()
        model.addRule()
        await model.saveRules()

        let body = try? XCTUnwrap(transport.bodies.last)
        // ⚠️ The two stored rows and nothing else. `industry` appears in the first row's
        // own `field`, so the count of `"operator"` keys is what distinguishes them.
        XCTAssertEqual(body?.components(separatedBy: #""operator""#).count, 2)
    }

    /// ⚠️ A NEW ROW OPENS ON THE WEB'S OWN DEFAULTS, so a rule created on one platform
    /// and opened on the other does not look as though somebody changed it.
    func testANewRowStartsOnTheWebsDefaults() async {
        let model = Self.model(Self.transport())
        await model.loadConfig()
        model.addRule()
        XCTAssertEqual(model.drafts?.last?.field, "industry")
        XCTAssertEqual(model.drafts?.last?.ruleOperator, "contains")
        XCTAssertEqual(model.drafts?.last?.voice, "Puck")
        XCTAssertTrue(model.drafts?.last?.isIncomplete == true)
    }

    /// ⛔ SAVING NOTHING DELETES EVERY RULE, AND THE SCREEN ASKS FIRST — on what WOULD BE
    /// SENT rather than on whether the list looks empty, because a screen of abandoned
    /// blank rows saves as empty too.
    func testAnEmptySaveIsRecognisedAsOne() async {
        let model = Self.model(Self.transport())
        await model.loadConfig()
        XCTAssertFalse(model.wouldSaveEmpty)
        for draft in model.drafts ?? [] {
            model.removeRule(draft.id)
        }
        XCTAssertTrue(model.wouldSaveEmpty)
        model.addRule()
        XCTAssertTrue(model.wouldSaveEmpty, "an abandoned new row is not a rule")
    }

    // MARK: - The vocabularies

    /// ⛔ THE RULE VOICES ARE DERIVED FROM THE CATALOGUE, NEVER RESTATED. The web
    /// hardcodes five names; its MODEL list beside them was hand-written the same way,
    /// never gained a later engine, and a rule could not select one the persona form and
    /// the agent both supported.
    func testTheRuleVoicesComeFromTheRealtimeEnginesPublishedCatalogue() async {
        let model = Self.model(Self.transport())
        await model.loadConfig()
        XCTAssertEqual(model.ruleVoices.map(\.value), ["Puck", "Kore"])
        XCTAssertEqual(model.ruleEngines.count, 2)
    }

    /// ⛔ A FAILED CATALOGUE READ DOES NOT TAKE THE SCREEN WITH IT AND DOES NOT PRODUCE A
    /// BUILT-IN LIST. The rules stay editable; the voice and engine pickers fall back to
    /// showing what is stored.
    func testTheEditorSurvivesACatalogueThatDidNotLoad() async {
        let transport = SettingsTransport([Self.config()], status: 200)
        let model = Self.model(transport)
        await model.loadConfig()
        XCTAssertEqual(model.drafts?.count, 2)
        XCTAssertTrue(model.ruleVoices.isEmpty)
        XCTAssertTrue(model.ruleEngines.isEmpty)
        XCTAssertTrue(model.canSave)
    }

    /// ⚠️ A VIEWER NEVER REACHES THIS SCREEN, and the model gates the writes anyway: a
    /// control that was not drawn is not a boundary.
    func testAViewerCanChangeNothing() async {
        let model = Self.model(Self.transport(), role: .viewer)
        await model.loadConfig()
        model.addRule()
        model.edit(0) { $0.value = "nope" }
        XCTAssertEqual(model.drafts?.count, 2)
        XCTAssertEqual(model.drafts?.first?.value, "fintech")
        XCTAssertFalse(model.canSave)
    }

    // MARK: - Fixtures

    private static func model(_ transport: SettingsTransport, role: WorkspaceRole = .agency) -> RoutingModel {
        RoutingModel(workspaces: .settingsTest(transport), workspaceId: "ws_1", role: role)
    }

    /// ⚠️ THE QUEUE IS THE WHOLE CONVERSATION: the config read, the catalogue read, the
    /// save's own `{"success":true}`, and the re-read every save on this surface makes
    /// because the write echoes nothing.
    private static func transport(rules: String = storedRules) -> SettingsTransport {
        SettingsTransport([config(rules: rules), catalogue, #"{"success":true}"#, config(rules: rules)])
    }

    private static func config(rules: String = storedRules) -> String {
        #"{"success":true,"config":{"routingRules":\#(rules)}}"#
    }

    /// ⚠️ ONE BUILDER-SHAPED ROW CARRYING AN UNMODELLED KEY, AND ONE ROW IN THE SHAPE THE
    /// COMMITTED FIXTURE ACTUALLY HOLDS. Both halves are what this editor has to survive.
    private static let storedRules = #"""
    [{"id":"rule_1","field":"industry","operator":"contains","value":"fintech",
      "voice":"Puck","model":"","instruction":"Be brief.","sector":"fintech"},
     {"id":"rule_2","match":"industry","action":"answer","target":"sales"}]
    """#

    private static let catalogue = #"""
    {"success":true,"region":"us",
     "engines":[{"id":"gemini-live-2.5-flash-native-audio","label":"Gemini 2.5 Live — US",
                 "inRegion":true,"responseLengths":[{"value":"concise","label":"Concise"}]},
                {"id":"deepgram-pipeline","label":"Deepgram Pipeline — US",
                 "inRegion":true,"responseLengths":[{"value":"concise","label":"Concise"}]}],
     "languages":{"deepgram":[{"value":"en-US","label":"English"}],
                  "general":[{"value":"en-US","label":"English"}]},
     "voices":[{"engine":"gemini-live-2.5-flash-native-audio","language":"en-US",
                "groups":[{"label":"Voices","options":[{"value":"Puck","label":"Puck"},
                                                       {"value":"Kore","label":"Kore"}]}]}],
     "voiceStyles":[{"value":"en-GB-Studio-B","label":"British studio"}],
     "defaults":{"voiceByEngine":{"deepgram-pipeline":"aura-2-asteria-en"},
                 "voiceByDeepgramLanguage":{"en-US":"aura-2-asteria-en"},
                 "responseLength":"concise","temperature":0.7}}
    """#
}
