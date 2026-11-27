@testable import DistrictAI
import DistrictData
import XCTest

/// What the Voice Studio save card and the persona preview say for each refusal and each way
/// a preview ends.
final class SettingsVoiceAndPreviewScopeTests: XCTestCase {
    // MARK: - Voice Studio refusals

    /// The service's sentence is carried when it sends one.
    @MainActor
    func testARefusalWithASentenceCarriesIt() {
        let mix = VoiceStudioModel.failure(.invalidEngineMix("That voice is not offered on that model"))
        XCTAssertEqual(mix.message, "That voice is not offered on that model")
        let region = VoiceStudioModel.failure(.modelUnavailableInRegion("Not in Frankfurt"))
        XCTAssertEqual(region.message, "Not in Frankfurt")
    }

    /// ⚠️ ABSENT OR BLANK, THE SCREEN'S OWN SENTENCE STANDS IN, and neither refusal offers a
    /// retry: sending the same mix again is refused again.
    @MainActor
    func testABlankOrAbsentSentenceFallsBackAndOffersNoRetry() {
        for message in [nil, "", "   \n"] {
            let mix = VoiceStudioModel.failure(.invalidEngineMix(message))
            XCTAssertEqual(mix.message, VoiceStudioCopy.invalidEngineMix)
            guard case .none = mix.action else { return XCTFail("an invalid mix is not retryable") }
            let region = VoiceStudioModel.failure(.modelUnavailableInRegion(message))
            XCTAssertEqual(region.message, VoiceStudioCopy.modelUnavailableInRegion)
            guard case .none = region.action else { return XCTFail("a region refusal is not retryable") }
        }
    }

    // MARK: - How a preview ends

    @MainActor
    func testEachEndingHasItsOwnSentence() {
        XCTAssertEqual(PersonaPreviewView.endingText(.stopped), SettingsCopy.previewEnded)
        // ⛔ NEVER THE SDK'S OWN REASON: a remote drop says the same sentence with or without one.
        XCTAssertEqual(PersonaPreviewView.endingText(.droppedRemotely(reason: nil)), SettingsCopy.previewDropped)
        XCTAssertEqual(
            PersonaPreviewView.endingText(.droppedRemotely(reason: "PARTICIPANT_REMOVED")),
            SettingsCopy.previewDropped
        )
        XCTAssertEqual(PersonaPreviewView.endingText(.yielded(.telephoneCall)), SettingsCopy.previewYieldedToCall)
        XCTAssertEqual(PersonaPreviewView.endingText(.yielded(.sessionEnded)), SettingsCopy.previewEnded)
        XCTAssertEqual(PersonaPreviewView.endingText(.yielded(.workspaceChanged)), SettingsCopy.previewEnded)
    }
}
