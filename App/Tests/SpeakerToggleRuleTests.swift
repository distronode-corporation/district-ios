import AVFoundation
@testable import DistrictAI
import XCTest

/// Whether a speaker toggle is drawn, decided from a stated earpiece and fabricated routes
/// rather than from the simulator's audio hardware, which is neither a phone's nor a
/// tablet's.
final class SpeakerToggleRuleTests: XCTestCase {
    private typealias Port = AVAudioSession.Port

    private let everyOutput: [Port?] = [
        .builtInReceiver, .builtInSpeaker, .headphones, .bluetoothHFP, .bluetoothA2DP, .usbAudio, .carAudio, nil,
    ]

    /// ⛔ A DEVICE WITH AN EARPIECE KEEPS ITS TOGGLE ON EVERY ROUTE, including the built-in
    /// speaker nobody asked for: that is a phone whose calls are routed to the speaker by
    /// an accessibility setting, and "Speaker off" is how its owner gets the call back to
    /// the ear.
    func test_IOS_SPEAKER_01_anEarpieceKeepsTheToggleOnEveryRoute() {
        for output in everyOutput {
            for requested in [false, true] {
                XCTAssertTrue(
                    SpeakerToggleRule.offersToggle(hasReceiver: true, output: output, speakerRequested: requested),
                    "\(output?.rawValue ?? "none") requested=\(requested)"
                )
            }
        }
    }

    /// ⛔ NO EARPIECE, AUDIO ON THE SPEAKER: THE TOGGLE IS GONE, because "Speaker off"
    /// would be false.
    func test_IOS_SPEAKER_02_noEarpieceOnTheSpeakerHidesTheToggle() {
        XCTAssertFalse(SpeakerToggleRule.offersToggle(
            hasReceiver: false,
            output: .builtInSpeaker,
            speakerRequested: false
        ))
        XCTAssertFalse(SpeakerToggleRule.offersToggle(hasReceiver: false, output: nil, speakerRequested: false))
    }

    /// ⚠️ NO EARPIECE BUT A HEADSET IN: THE TOGGLE STILL MOVES THE CALL, so it stays.
    func test_IOS_SPEAKER_03_noEarpieceWithAHeadsetKeepsTheToggle() {
        for output in [Port.headphones, .bluetoothHFP, .bluetoothA2DP, .usbAudio, .carAudio] {
            XCTAssertTrue(
                SpeakerToggleRule.offersToggle(hasReceiver: false, output: output, speakerRequested: false),
                output.rawValue
            )
        }
    }

    /// ⛔ WHILE THE SPEAKER IS REQUESTED THE TOGGLE STAYS, so the override can be undone.
    func test_IOS_SPEAKER_04_aRequestedSpeakerAlwaysHasAWayBack() {
        for output in everyOutput {
            XCTAssertTrue(
                SpeakerToggleRule.offersToggle(hasReceiver: false, output: output, speakerRequested: true),
                output?.rawValue ?? "none"
            )
        }
    }

    /// The observable carries the stated earpiece unchanged and follows the routes.
    @MainActor
    func test_IOS_SPEAKER_05_theRecordedStateFollowsTheRoutes() {
        let tablet = AudioOutputs(hasReceiver: false)
        XCTAssertFalse(tablet.offersSpeakerToggle(speakerRequested: false), "nothing reported yet")
        tablet.record(outputs: [.headphones])
        XCTAssertTrue(tablet.offersSpeakerToggle(speakerRequested: false))
        tablet.record(outputs: [.builtInSpeaker])
        XCTAssertEqual(tablet.output, .builtInSpeaker)
        XCTAssertFalse(tablet.offersSpeakerToggle(speakerRequested: false))
        XCTAssertTrue(tablet.offersSpeakerToggle(speakerRequested: true))

        let phone = AudioOutputs(hasReceiver: true)
        phone.record(outputs: [.builtInSpeaker])
        XCTAssertTrue(phone.offersSpeakerToggle(speakerRequested: false))
        XCTAssertTrue(phone.hasReceiver)
    }
}
