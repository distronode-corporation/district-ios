@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The Voice Studio screen model: the read, the single-flight save that always reads back,
/// and what the screen says about each outcome.
///
/// ⚠️ THE STUDIO'S RULES ARE TESTED IN `district-core-swift` (`VoiceStudio*Tests`), against
/// the service's own fixture. What is tested here is the routing: who may edit, what a save
/// sends, and which of the five outcomes the screen reports.
///
/// ⚠️ THE BODY IS A MINIMAL STUDIO, NOT THE CONTRACT FIXTURE: the fixture lives with the
/// models in district-core-swift, and this one only has to decode. A realtime engine is held,
/// so a voice change is exactly one pending key.
final class VoiceStudioModelTests: XCTestCase {
    @MainActor
    private func makeModel(_ transport: SettingsTransport, role: WorkspaceRole? = .agency) -> VoiceStudioModel {
        VoiceStudioModel(
            repository: VoiceStudioRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            workspaceId: "ws_1",
            role: role
        )
    }

    private func withVoice(_ voice: String) -> (VoiceStudioState) -> VoiceStudioState {
        { state in
            var next = state
            next.engine = state.engine.withVoice(voice)
            return next
        }
    }

    // MARK: - The read

    @MainActor
    func testTheReadOpensACleanStudio() async {
        let model = makeModel(SettingsTransport([VoiceStudioTestBody.studio(voice: "Puck")]))
        await model.loadStudio()
        XCTAssertEqual(model.session?.held.engine.voice, "Puck")
        XCTAssertFalse(model.canSave)
        XCTAssertTrue(model.canEdit)
    }

    /// ⛔ A FAILED READ IS A RETRY AND NOTHING EDITABLE.
    @MainActor
    func testAFailedReadOffersNothingToEdit() async {
        let model = makeModel(SettingsTransport([#"{"error":"Down"}"#], status: 503))
        await model.loadStudio()
        guard case let .failed(failure) = model.load else { return XCTFail("expected a failed read") }
        XCTAssertEqual(failure.message.isEmpty, false)
        XCTAssertNil(model.session)
        XCTAssertFalse(model.canEdit)
    }

    /// ⚠️ A CONTROL THAT WAS NOT DRAWN IS NOT A BOUNDARY: a viewer's edit is refused here too.
    @MainActor
    func testAViewerCannotEdit() async {
        let model = makeModel(SettingsTransport([VoiceStudioTestBody.studio(voice: "Puck")]), role: .viewer)
        await model.loadStudio()
        model.updateHeld(withVoice("Kore"))
        XCTAssertEqual(model.session?.held.engine.voice, "Puck")
        XCTAssertFalse(model.canSave)
    }

    // MARK: - The save

    /// ⛔ ONLY THE CHANGED KEY GOES, AND THE STUDIO IS READ BACK BEFORE "SAVED" IS SAID.
    @MainActor
    func testASaveSendsTheChangedKeyAndReadsBack() async {
        let transport = SettingsTransport([
            VoiceStudioTestBody.studio(voice: "Puck"),
            #"{"success":true}"#,
            VoiceStudioTestBody.studio(voice: "Kore"),
        ])
        let model = makeModel(transport)
        await model.loadStudio()
        model.updateHeld(withVoice("Kore"))
        XCTAssertTrue(model.canSave)
        await model.saveChanges()

        XCTAssertEqual(transport.bodies, [#"{"voice":"Kore","workspaceId":"ws_1"}"#])
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        XCTAssertEqual(model.session?.isDirty, false)
        XCTAssertEqual(transport.paths.last, "/api/district/workspace/persona/voice-studio")
    }

    /// ⛔ A 200 WHOSE RE-READ DOES NOT HOLD WHAT WAS SENT IS NOT "SAVED".
    @MainActor
    func testARereadThatDisagreesIsAMismatch() async {
        let transport = SettingsTransport([
            VoiceStudioTestBody.studio(voice: "Puck"),
            #"{"success":true}"#,
            VoiceStudioTestBody.studio(voice: "Puck"),
        ])
        let model = makeModel(transport)
        await model.loadStudio()
        model.updateHeld(withVoice("Kore"))
        await model.saveChanges()
        guard case .mismatch = model.save else { return XCTFail("expected a mismatch, got \(model.save)") }
        XCTAssertEqual(model.session?.held.engine.voice, "Puck")
    }

    /// ⛔ THE WRITE LANDED AND ONLY THE READ BACK FAILED: THE EDITS ARE NOT CALLED UNSAVED.
    @MainActor
    func testAFailedRereadIsSavedButStale() async {
        let transport = SettingsTransport([VoiceStudioTestBody.studio(voice: "Puck"), #"{"success":true}"#])
        let model = makeModel(transport)
        await model.loadStudio()
        model.updateHeld(withVoice("Kore"))
        await model.saveChanges()
        guard case .savedButStale = model.save else { return XCTFail("expected saved-but-stale, got \(model.save)") }
    }

    /// ⛔ A REFUSED CHAIN WROTE NOTHING; THE EDITS SURVIVE AND THE SERVER'S SENTENCE IS SHOWN.
    @MainActor
    func testARefusedChainKeepsTheEditsAndSaysWhy() async {
        let refused = #"{"success":false,"error":"That voice chain cannot be saved.","code":"invalid_engine_mix"}"#
        let transport = SettingsTransport(responses: [
            (200, VoiceStudioTestBody.studio(voice: "Puck")),
            (400, refused),
        ])
        let model = makeModel(transport)
        await model.loadStudio()
        model.updateHeld(withVoice("Kore"))
        await model.saveChanges()
        guard case let .failed(failure) = model.save else { return XCTFail("expected a refusal, got \(model.save)") }
        XCTAssertEqual(failure.message, "That voice chain cannot be saved.")
        XCTAssertEqual(model.session?.held.engine.voice, "Kore")
        XCTAssertEqual(model.session?.isDirty, true)
        // ⚠️ Nothing was read back: a refusal is not followed by the read.
        XCTAssertEqual(transport.paths.count, 2)
    }

    @MainActor
    func testARefusalWithNoSentenceUsesTheAppsOwn() {
        XCTAssertEqual(VoiceStudioModel.failure(.invalidEngineMix(nil)).message, VoiceStudioCopy.invalidEngineMix)
        XCTAssertEqual(
            VoiceStudioModel.failure(.modelUnavailableInRegion(" ")).message,
            VoiceStudioCopy.modelUnavailableInRegion
        )
        XCTAssertEqual(
            VoiceStudioModel.failure(.failed(.transport("offline"))).action,
            FailureText.Action.retry
        )
    }

    // MARK: - Words

    func testAMeterNeverSaysAboutWhenAStageIsMissing() throws {
        let labels = try VoiceStudioTestBody.labels()
        XCTAssertEqual(VoiceStudioMeterHeadline.local(ms: 850, atLeast: true).text(labels), "At least 850 ms")
        XCTAssertEqual(VoiceStudioMeterHeadline.local(ms: 970, atLeast: false).text(labels), "About 970 ms")
        XCTAssertEqual(VoiceStudioMeterHeadline.none.text(labels), labels.notMeasured)
        XCTAssertEqual(VoiceStudioMeterHeadline.server("Environ 970 ms").text(labels), "Environ 970 ms")
        XCTAssertEqual(VoiceStudioLatencyText.none.text(labels), labels.notMeasured)
        XCTAssertEqual(VoiceStudioLatencyText.milliseconds(90).text(labels), "90 ms")
        XCTAssertEqual(VoiceStudioLatencyText.server("Lab: 150 ms").text(labels), "Lab: 150 ms")
    }

    func testTheChangeCountIsSingularForOne() {
        XCTAssertEqual(VoiceStudioCopy.basedOn("Fastest", changes: 1), "Based on Fastest, 1 change")
        XCTAssertEqual(VoiceStudioCopy.basedOn("Fastest", changes: 2), "Based on Fastest, 2 changes")
    }

    func testAChannelsToneIsDecorationOverItsName() {
        XCTAssertEqual(VoiceStudioChannel.tone("stable"), .success)
        XCTAssertEqual(VoiceStudioChannel.tone("preview"), .warning)
        XCTAssertEqual(VoiceStudioChannel.tone("legacy"), .neutral)
    }
}

/// A minimal Voice Studio body: every required key, a realtime engine held, empty lists.
enum VoiceStudioTestBody {
    static func studio(voice: String) -> String {
        #"""
        {"success":true,"region":"us","locale":"en","language":"en-US","previewAllowed":true,
         "labels":\#(labelsJSON),
         "current":{"modelId":"gemini-live-2.5-flash-native-audio","engineMix":null,"preemptiveTts":false,
          "temperature":0.7,"bilingual":false,"voiceStyle":null,"recipeId":"realtime","tier":"stable",
          "fields":{"modelId":"gemini-live-2.5-flash-native-audio","voice":"\#(voice)","engineMix":null,
           "preemptiveTts":null,"temperature":0.7,"bilingual":null,"voiceStyle":null},
          "chain":{"kind":"realtime","engineMix":null,"realtimeModelId":"gemini-live-2.5-flash-native-audio",
           "voice":"\#(voice)","blocks":[],"residency":{"inRegion":true,"text":"Stays here.","legsOut":[]}}},
         "latency":{"ms":null,"atLeast":false,"text":"Not measured yet","note":null,"stages":[],"eou":null,
          "sourceText":"Measured on live calls.","measuredThrough":"2026-10-03","measuredDays":30},
         "recipeIds":[],"recipes":[],
         "catalog":{"presets":[],"stt":[],"turn":{"detector":{"label":"Turn detector","where":"In the agent"},
          "ear":{"label":"Flux end of turn"},"latency":null},"llm":[],"tts":[],"realtime":[]},
         "voices":[],"advanced":[]}
        """#
    }

    static func labels() throws -> VoiceStudioLabels {
        try JSONDecoder().decode(VoiceStudioLabels.self, from: Data(labelsJSON.utf8))
    }

    private static let labelsJSON = #"""
    {"heading":"Voice Studio","description":"d","tierLabel":"Models","tierStable":"Stable",
     "tierLatest":"Latest","tierDescription":"t","recipesLabel":"Starting point","defaultBadge":"Default",
     "reset":"Reset","chainLabel":"Signal chain","editLeg":"Part to edit","edit":"Edit",
     "meterHeading":"Time to first word","meterDescription":"m","residencyHeading":"r",
     "allInRegion":"a","leavesRegion":"l","providerLabel":"Vendor","modelLabel":"Model",
     "locationLabel":"Location","voiceLabel":"Voice","voicePlaceholder":"Choose a voice",
     "listen":"Listen","stopListening":"Stop","advanced":"Advanced","interruptions":"Interruptions",
     "notMeasured":"Not measured yet","previewNote":"p","save":"Save voice settings",
     "saved":"Voice settings saved.","saveFailed":"Voice settings were not saved.",
     "unsaved":"Unsaved changes","allSaved":"All changes saved",
     "legs":{"stt":"Ear","turn":"Turn-taking","llm":"Brain","tts":"Voice"},
     "stages":{"eou":"End of turn","llm_ttft":"Brain, first word","tts_ttfb":"Voice, first sound",
      "realtime_ttft":"Model, first sound"},
     "channels":{"stable":"Stable","latest":"Latest","preview":"Preview","legacy":"Legacy"}}
    """#
}
