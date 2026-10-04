@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// After a persona language save, a chain of the member's own is fitted to the new language:
/// read before the save, read again after it, and moved only when the service no longer
/// accepts it.
///
/// ⚠️ THE RULES OF THE MOVE ARE TESTED IN `district-core-swift` (`VoiceStudioRefitTests`),
/// against the service's own fixture. What is tested here is the routing: when the Studio is
/// read at all, what the screen says, and that a refused save starts nothing.
final class PersonaRefitTests: XCTestCase {
    /// A chain of the member's own as the Studio stores it.
    private static let mix = #"""
    {"v":1,"stt":{"provider":"deepgram","model":"flux-general-en","language":null,"location":null},
     "llm":{"model":"gemini-2.5-flash","location":"auto","thinking":"off","temperature":null},
     "tts":{"provider":"deepgram","model":"aura-2","voice":"aura-2-asteria-en","speed":null,"location":null},
     "turn":{"minDelay":null,"maxDelay":null,"eotThreshold":null},"preemptiveTts":false}
    """#

    private static func config(modelId: String) -> String {
        #"{"success":true,"config":{"aiPersona":{"modelId":"\#(modelId)","language":"en-US"}}}"#
    }

    private static let options = #"""
    {"success":true,"region":"us",
     "engines":[{"id":"custom-pipeline","label":"Your chain","inRegion":true,"responseLengths":[]},
       {"id":"gemini-live-2.5-flash-native-audio","label":"Gemini 2.5 Live","inRegion":true,"responseLengths":[]}],
     "languages":{"deepgram":[{"value":"en-US","label":"English (US)"}],
                  "general":[{"value":"en-US","label":"English (US)"},{"value":"fr-CA","label":"French (Canada)"}]},
     "voices":[],"voiceStyles":[],
     "defaults":{"voiceByEngine":{},"voiceByDeepgramLanguage":{},"responseLength":"concise","temperature":0.7}}
    """#

    private static let saved = #"{"success":true}"#

    @MainActor
    private func makeModel(_ transport: SettingsTransport) -> PersonaModel {
        let client = ApiClient(baseURL: ApiClient.productionBaseURL, transport: transport, accessToken: { "t" })
        return PersonaModel(
            workspaces: WorkspaceRepository(client: client),
            voiceStudio: VoiceStudioRepository(client: client),
            workspaceId: "ws_1",
            role: .agency
        )
    }

    /// Load the form for `modelId`, move the language to French, and save.
    @MainActor
    private func saveFrench(_ transport: SettingsTransport) async -> PersonaModel {
        let model = makeModel(transport)
        await model.loadConfig()
        model.editIdentity { $0.selectLanguage("fr-CA") }
        await model.saveChanges()
        return model
    }

    private func studioPaths(_ transport: SettingsTransport) -> Int {
        transport.paths.filter { $0 == "/api/district/workspace/persona/voice-studio" }.count
    }

    // MARK: - When the Studio is read

    /// ⛔ A PRESET ENGINE HAS NO CHAIN OF ITS OWN TO FIT: the Studio is not read.
    @MainActor
    func testAPresetEngineReadsNoStudio() async {
        let preset = "gemini-live-2.5-flash-native-audio"
        let transport = SettingsTransport([
            Self.config(modelId: preset), Self.options, Self.saved, Self.config(modelId: preset),
        ])
        let model = await saveFrench(transport)
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        XCTAssertEqual(studioPaths(transport), 0)
        XCTAssertNil(model.refit)
    }

    /// A chain that still fits the new language: read before and after, nothing sent, nothing
    /// said.
    @MainActor
    func testAChainThatStillFitsSaysNothing() async {
        let studio = VoiceStudioTestBody.custom(engineMix: Self.mix)
        let transport = SettingsTransport([
            Self.config(modelId: "custom-pipeline"), Self.options,
            studio, Self.saved, Self.config(modelId: "custom-pipeline"), studio,
        ])
        let model = await saveFrench(transport)
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        XCTAssertEqual(studioPaths(transport), 2)
        XCTAssertNil(model.refit)
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertTrue(transport.bodies.first?.contains(#""language":"fr-CA""#) == true, "\(transport.bodies)")
    }

    /// A chain the service no longer accepts, with no model in the catalogue that speaks the
    /// language: said, and nothing sent.
    @MainActor
    func testAChainWithNothingToMoveToIsSaid() async {
        let transport = SettingsTransport([
            Self.config(modelId: "custom-pipeline"), Self.options,
            VoiceStudioTestBody.custom(engineMix: Self.mix), Self.saved,
            Self.config(modelId: "custom-pipeline"),
            VoiceStudioTestBody.custom(engineMix: "null"),
        ])
        let model = await saveFrench(transport)
        XCTAssertEqual(model.refit, .finished(.noFit))
        XCTAssertEqual(model.refit?.line, PersonaRefitState.noFitLine)
        XCTAssertEqual(transport.bodies.count, 1)
    }

    /// ⛔ A STUDIO THAT COULD NOT BE READ BEFORE THE SAVE IS SAID, not skipped.
    @MainActor
    func testAStudioThatCouldNotBeReadIsSaid() async {
        let transport = SettingsTransport(responses: [
            (200, Self.config(modelId: "custom-pipeline")), (200, Self.options),
            (503, #"{"error":"Down"}"#), (200, Self.saved),
            (200, Self.config(modelId: "custom-pipeline")),
        ])
        let model = await saveFrench(transport)
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        guard case .finished(.failed) = model.refit else {
            return XCTFail("expected a failure, got \(String(describing: model.refit))")
        }
        XCTAssertTrue(model.refit?.line?.hasPrefix(PersonaRefitState.failedLine) == true)
    }

    /// ⛔ A REFUSED LANGUAGE SAVE STARTS NO REFIT.
    @MainActor
    func testARefusedSaveStartsNothing() async {
        let transport = SettingsTransport(responses: [
            (200, Self.config(modelId: "custom-pipeline")), (200, Self.options),
            (200, VoiceStudioTestBody.custom(engineMix: Self.mix)), (400, #"{"error":"Invalid language"}"#),
        ])
        let model = await saveFrench(transport)
        guard case .failed = model.save else { return XCTFail("expected a failed save, got \(model.save)") }
        XCTAssertNil(model.refit)
        XCTAssertEqual(transport.paths.count, 4)
    }

    // MARK: - What the screen says

    @MainActor
    func testEachOutcomeHasItsLine() {
        XCTAssertEqual(PersonaRefitState.running.line, PersonaRefitState.runningLine)
        XCTAssertTrue(PersonaRefitState.running.isRunning)
        XCTAssertNil(PersonaRefitState.finished(.fits).line)
        XCTAssertEqual(PersonaRefitState.finished(.refitted).line, PersonaRefitState.refittedLine)
        XCTAssertEqual(PersonaRefitState.finished(.notSeen).line, PersonaRefitState.notSeenLine)
        XCTAssertFalse(PersonaRefitState.finished(.refitted).isRunning)
        XCTAssertEqual(
            PersonaRefitState.finished(.failed(.invalidEngineMix("That voice chain cannot be saved."))).line,
            "\(PersonaRefitState.failedLine) That voice chain cannot be saved."
        )
    }
}
