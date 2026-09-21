import AVFoundation
import Observation
import UIKit

/// Whether a "Speaker on / Speaker off" control means anything on this device, right now.
///
/// ⛔ A DEVICE WITH NO EARPIECE PLAYS A CALL THROUGH ITS SPEAKER WHATEVER THE TOGGLE SAYS.
/// Turning the speaker "off" is `overrideOutputAudioPort(.none)`, which hands the route
/// back to the category, and on hardware with no built-in receiver the category's own
/// answer is the loudspeaker. A button reading "Speaker off" there is a false statement
/// about where the audio is going, and pressing it does nothing audible.
///
/// ⛔ WHETHER THERE IS AN EARPIECE IS TAKEN AS A HARDWARE FACT, NEVER INFERRED FROM A
/// ROUTE. The audio route cannot tell "no earpiece" apart from "the user sent calls to the
/// speaker": Settings > Accessibility > Touch > Call Audio Routing = Speaker puts every
/// call on the loudspeaker with no override from this app, so a route-based inference
/// would read that phone as earpiece-less and take its toggle away from exactly the
/// person who needs it to get the call back to the ear. The fact is supplied to
/// ``AudioOutputs`` once, from ``AudioOutputs/shared``; the rule itself stays pure.
enum SpeakerToggleRule {
    /// Whether to draw the toggle at all.
    ///
    /// ⛔ ALWAYS ON A DEVICE WITH AN EARPIECE, whatever the route says: there, "Speaker
    /// off" is always a real place for the audio to go.
    ///
    /// ⛔ ALWAYS WHILE THE SPEAKER IS REQUESTED, so there is a way back. Somebody who turned
    /// it on with headphones in and then unplugged them is on the speaker with nothing
    /// meaningful left to switch, but hiding the control would leave the override stuck
    /// for the next headset.
    ///
    /// ⚠️ WITH NO EARPIECE THE TOGGLE STILL MATTERS WHILE THE AUDIO IS GOING ELSEWHERE: with
    /// a headset or a car in, "Speaker on" moves the call out of them and "Speaker off" is
    /// true. It is hidden only while the built-in speaker is where the audio already is,
    /// and while nothing at all is reported.
    static func offersToggle(
        hasReceiver: Bool,
        output: AVAudioSession.Port?,
        speakerRequested: Bool
    ) -> Bool {
        if speakerRequested || hasReceiver {
            return true
        }
        guard let output else { return false }
        return output != .builtInSpeaker
    }
}

/// Where the device's audio is going, observable by the screens that draw a speaker
/// control, together with whether the hardware has an earpiece at all.
///
/// ⚠️ ONE PER PROCESS BECAUSE THE HARDWARE IS. It is fed by ``AudioSessionCoordinator``,
/// which observes every route change in the process from launch, and read by the call
/// and meeting screens, which have no other path to the audio session and should not
/// grow one.
@MainActor
@Observable
final class AudioOutputs {
    /// ⛔ THE ONLY PLACE IN THE APP THAT READS `userInterfaceIdiom`, AND IT IS READ HERE
    /// AS A HARDWARE CAPABILITY, NOT AS A LAYOUT DECISION. Everywhere else the app lays
    /// itself out from size classes and available width (a narrow iPad window gets the
    /// phone layout), and the source scan that bans the idiom exempts this file alone.
    /// No iPad has a built-in receiver and every iPhone has one; AVFoundation has no API
    /// that lists a device's outputs, only the one in use, so the device family is the
    /// only first-hand statement of that fact available to an app.
    ///
    /// ⚠️ SEEDED WITH THE ROUTE IN USE AT LAUNCH, so a headset already plugged in counts
    /// before the first route change is heard.
    static let shared = AudioOutputs(
        hasReceiver: UIDevice.current.userInterfaceIdiom != .pad,
        output: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
    )

    /// Whether the device has an earpiece. Fixed for the life of the process.
    let hasReceiver: Bool

    /// Where audio was going at the last route change, if anywhere.
    private(set) var output: AVAudioSession.Port?

    init(hasReceiver: Bool, output: AVAudioSession.Port? = nil) {
        self.hasReceiver = hasReceiver
        self.output = output
    }

    /// ⚠️ WRITTEN ONLY WHEN IT CHANGES. `@Observable` notifies on every assignment, equal
    /// or not, and a route notification that moves nothing should not re-render every
    /// screen reading this.
    func record(outputs: [AVAudioSession.Port]) {
        let first = outputs.first
        if first != output {
            output = first
        }
    }

    /// ``SpeakerToggleRule/offersToggle(hasReceiver:output:speakerRequested:)`` over the
    /// hardware and the last recorded route.
    func offersSpeakerToggle(speakerRequested: Bool) -> Bool {
        SpeakerToggleRule.offersToggle(hasReceiver: hasReceiver, output: output, speakerRequested: speakerRequested)
    }
}
