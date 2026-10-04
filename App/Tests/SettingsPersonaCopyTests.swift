@testable import DistrictAI
import XCTest

/// The sentences the persona form, the preview and the routing editor say.
///
/// ⛔ A STALE REFUSAL IS WORSE THAN NO SENTENCE: an operator reads it, believes it, and
/// goes looking for a browser. "chosen from lists this app cannot see", "They cannot be
/// edited in this app" and "Rules cannot be added in this app" all describe things this
/// app does, so these are `not.toContain`-shaped assertions: a copy-paste that revives
/// one of them fails here rather than shipping.
///
/// ⚠️ WORDING TESTS EARN THEIR KEEP ONLY WHERE THE WORDING IS THE PRODUCT. What is
/// pinned below is never a phrasing preference — it is the four places where the
/// sentence is the only thing standing between an operator and a charge, a deletion, or
/// a belief about where their audio is processed.
final class SettingsPersonaCopyTests: XCTestCase {
    /// ⛔ THE RETIRED REFUSALS, BY SUBSTRING.
    func testNothingStillClaimsThePersonaCannotBeEditedHere() {
        let live = [
            SettingsCopy.personaReadOnlyNote,
            SettingsCopy.routingNote,
            SettingsCopy.routingEmptyBody,
            SettingsCopy.personaVoiceStudioNote,
        ]
        for sentence in live {
            XCTAssertFalse(sentence.contains("cannot be changed in this app"), sentence)
            XCTAssertFalse(sentence.contains("cannot be edited in this app"), sentence)
            XCTAssertFalse(sentence.contains("cannot be added in this app"), sentence)
            XCTAssertFalse(sentence.contains("lists this app cannot see"), sentence)
        }
    }

    /// ⛔ THE PREVIEW SAYS IT IS A REAL CALL AND THAT IT COSTS, BEFORE IT IS PRESSED. The
    /// token invites the agent into a room and starts burning speech and model minutes;
    /// a button labelled "Preview" with no sentence beside it is a charge nobody was
    /// told about.
    func testThePreviewSaysItIsARealChargeableCall() {
        XCTAssertTrue(SettingsCopy.previewIntro.contains("real call"))
        XCTAssertTrue(SettingsCopy.previewIntro.contains("charged"))
    }

    /// ⛔ THE TWO REFUSALS NAME WHAT IS HOLDING THE AUDIO. A greyed-out button with no
    /// reason is the "never render a failure as an absence" rule broken on the control
    /// that spends money.
    func testTheRefusalsSayWhatIsHoldingTheDevice() {
        XCTAssertTrue(SettingsCopy.previewBusyCall.contains("call on this device"))
        XCTAssertTrue(SettingsCopy.previewBusyRoom.contains("room on this device"))
        XCTAssertFalse(SettingsCopy.previewCooldown.isEmpty)
    }

    /// ⛔ THE PERSONA FORM SAYS WHERE THE VOICE WENT. It no longer shows the engine, the
    /// voice or the tuning, and without the sentence it reads as a persona with no voice.
    func testThePersonaFormSaysTheVoiceIsInVoiceStudio() {
        XCTAssertTrue(SettingsCopy.personaVoiceStudioNote.contains("Voice Studio"))
        XCTAssertTrue(SettingsCopy.personaVoiceStudioNote.contains("workspace settings"))
    }

    /// ⛔ BOTH WHOLESALE-REPLACE SAVES SAY SO, AND SO DOES THE CONFIRMATION THAT GUARDS
    /// THE EMPTY ONE. The routes answer `{"success":true}` for a deletion of everything.
    func testTheWholesaleReplaceIsStatedAndTheEmptySaveIsConfirmed() {
        XCTAssertTrue(SettingsCopy.routingNote.contains("replaces the whole list"))
        XCTAssertTrue(SettingsCopy.directoryNote.contains("replaces the whole list"))
        XCTAssertTrue(SettingsCopy.routingEmptyConfirm.contains("no undo"))
    }

    /// ⛔ THE AVATAR IS DESCRIBED AS A CHARGED FEATURE THAT IS SET UP ELSEWHERE, and the
    /// sentence names nowhere in particular: App Store Review Guideline 3.1.1 is why no
    /// sentence on this surface names the website.
    func testTheAvatarRowIsAStatusAndNamesNoOtherStore() {
        XCTAssertTrue(SettingsCopy.personaAvatarNote.contains("charged"))
        for sentence in [SettingsCopy.personaAvatarNote, SettingsCopy.personaOptionsFailedNote] {
            XCTAssertFalse(sentence.lowercased().contains("website"), sentence)
            XCTAssertFalse(sentence.lowercased().contains("distronode.com"), sentence)
        }
    }

    /// ⛔ THE ANSWER LENGTH SAYS IT IS PER ENGINE. It is the one control whose value
    /// changes when a different picker moves, and an operator who did not know that reads
    /// it as the form losing their edit.
    func testTheAnswerLengthSaysItIsSavedPerEngine() {
        XCTAssertTrue(SettingsCopy.personaAnswerLengthNote.contains("each engine"))
    }

    /// ⛔ AND THE READ-ONLY FALLBACK EXPLAINS ITSELF RATHER THAN LOOKING LIKE A PRODUCT
    /// DECISION — including the half that matters, which is that the three text fields
    /// can still be saved.
    func testTheFallbackPanelExplainsWhatCanStillBeDone() {
        XCTAssertTrue(SettingsCopy.personaOptionsFailedNote.contains("greeting"))
        XCTAssertTrue(SettingsCopy.personaOptionsFailedNote.contains("publishes"))
    }
}
