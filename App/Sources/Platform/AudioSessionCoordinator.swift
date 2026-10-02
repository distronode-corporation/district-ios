import AVFoundation
import DistrictCall
import Foundation

/// Who owns `AVAudioSession` while a call is up, and what it tells the rest of the
/// app about where the audio actually went.
///
/// ⛔ CALLKIT ACTIVATES THE SESSION, THIS CONFIGURES IT, AND NEITHER HALF MAY MOVE.
/// Apple's ordering for a VoIP app is: set the CATEGORY while handling a
/// `CXStartCallAction`/`CXAnswerCallAction`, before fulfilling it, and let the system
/// ACTIVATE the session and tell you so in `provider(_:didActivate:)`. An app that
/// calls `setActive(true)` itself races CallKit for the session and the audible
/// symptom is a call that connects with no sound until something else nudges the
/// route. So there is no `setActive` anywhere in this file.
///
/// ⛔ AND IT IS THE REASON `AudioManager.shared.audioSession.isAutomaticConfiguration
/// Enabled` IS TURNED OFF IN ``LiveKitCallEngine/connect(url:token:)``. LiveKit
/// configures and activates the session by itself by default, which is correct for a
/// meeting app and wrong for a phone call: two owners, one session. Turning its
/// automation off is what makes this type the single owner, and that is also why
/// `AudioManager.shared.isSpeakerOutputPreferred` is not used here — the SDK
/// documents it as ignored once the host configures the session, so the speaker is
/// routed with `overrideOutputAudioPort` instead.
///
/// ⚠️ ONE PER PROCESS, SHARED BY THE ENGINE AND THE CALLKIT BRIDGE. ``CallStack``
/// builds it and hands the same instance to both; a second one would hold a second
/// speaker preference, and the one that answered `provider(_:didActivate:)` would not
/// be the one the in-call speaker button had written to.
///
/// ⚠️ `@unchecked Sendable` RATHER THAN AN ACTOR. Route-change notifications arrive on
/// whatever thread the audio server picked, the CallKit bridge is on the main actor
/// and the engine is nonisolated, so every member here has to be callable from all
/// three. The mutable state is three small values behind one `NSLock`; an actor would
/// make every one of those calls `await` for no benefit.
final class AudioSessionCoordinator: @unchecked Sendable {
    private let lock = NSLock()

    /// What the app ASKED the route to be. See ``CallMediaState/speakerRequested``.
    private var speakerPreferred = false

    /// Whether CallKit has told us the session is live.
    ///
    /// ⛔ `overrideOutputAudioPort` THROWS ON AN INACTIVE SESSION, so a speaker press
    /// made before `provider(_:didActivate:)` arrives is REMEMBERED here and applied
    /// at activation rather than being dropped. Dropping it would leave the toggle on
    /// screen saying speaker while the audio came out of the earpiece.
    private var sessionIsActive = false

    private var routeHandler: (@Sendable (AudioRoute) -> Void)?

    private var routeObserver: (any NSObjectProtocol)?

    init(notificationCenter: NotificationCenter = .default) {
        // ⚠️ THE OBSERVER IS INSTALLED AT CONSTRUCTION, NOT AT THE FIRST CALL. A route
        // change that happens between the dial and the join (a headset going in while
        // the credential is being fetched) is still a route change the in-call screen
        // has to draw, and there is nothing to gain by starting later.
        routeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // ⚠️ THE NOTIFICATION'S PAYLOAD IS IGNORED ON PURPOSE. Its
            // `AVAudioSessionRouteChangeReasonKey` says WHY the route changed;
            // ``AudioRoute`` is a statement about WHERE audio is going, and the
            // session's `currentRoute` is the only authority on that.
            self?.publishCurrentRoute()
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    /// Where audio is going right now, as the device reports it.
    var currentRoute: AudioRoute {
        Self.route(for: AVAudioSession.sharedInstance().currentRoute)
    }

    /// Start receiving ``AudioRoute`` changes.
    ///
    /// ⚠️ LAST WRITER WINS, AND THAT IS SAFE ONLY BECAUSE THERE IS ONE ENGINE PER
    /// CALL. ``CallEngine`` says so in its own ⛔; each engine claims this seam when it
    /// is built, and the previous engine belonged to a call that is over.
    func observeRouteChanges(_ handler: @escaping @Sendable (AudioRoute) -> Void) {
        lock.withLock { routeHandler = handler }
    }

    /// Put the session into call configuration.
    ///
    /// ⛔ CALLED FROM `provider(_:perform: CXStartCallAction)` AND
    /// `provider(_:perform: CXAnswerCallAction)`, BEFORE `fulfill()`. See the ⛔ on the
    /// type.
    ///
    /// ⚠️ `.voiceChat` RATHER THAN `.default`: it is what puts the device in
    /// communication audio mode, so the earpiece and the volume rocker behave like a
    /// call rather than like media. The Android client makes the same statement
    /// through `setAudioModeIsVoip(true)`.
    func configureForCall() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .voiceChat,
                // ⚠️ `.allowBluetoothHFP` IS THE iOS 26 SDK NAME FOR `.allowBluetooth`
                // (a rename, available since iOS 8, so nothing changes at the iOS 17
                // floor); the old spelling is a deprecation warning.
                options: [.allowBluetoothHFP, .allowBluetoothA2DP]
            )
        } catch {
            // ⚠️ DELIBERATELY UNREPORTED. A refused category change means the OS had a
            // stronger claim on the session (another call, a system alert); the person
            // holding the phone cannot act on it and the call may still be audible.
            // Nothing in this app read a stored copy of it, so none is kept.
        }
    }

    /// CallKit activated the session.
    func activate(_ session: AVAudioSession) {
        lock.withLock { sessionIsActive = true }
        applySpeakerOverride(on: session)
        publishCurrentRoute()
    }

    /// CallKit deactivated the session, or the provider reset.
    func deactivate() {
        lock.withLock {
            sessionIsActive = false
            // ⚠️ THE PREFERENCE IS CLEARED WITH THE SESSION, AND IT HAS TO BE BECAUSE
            // THIS OBJECT OUTLIVES THE CALL. `CXProvider` is one per app, so this
            // coordinator is too (see ``CallStack``), and a stale `true` would put the
            // NEXT call on the loudspeaker without anybody asking for it. ⛔ The price
            // is a mid-call deactivation (a system interruption CallKit routes through
            // here rather than through `AVAudioSession`'s own interruption
            // notification) losing the choice, which the user can undo with one press;
            // the other way round they cannot, because nothing tells them the speaker
            // is on before the callee hears the room.
            speakerPreferred = false
        }
    }

    /// Route call audio to the loudspeaker, or back to the default.
    func setSpeakerphone(_ enabled: Bool) {
        // ⚠️ THE TYPE IS STATED. `withLock` is generic over its body's result and this
        // body is multi-statement, which is exactly the shape where inference is worth
        // not relying on.
        let isActive: Bool = lock.withLock {
            speakerPreferred = enabled
            return sessionIsActive
        }
        guard isActive else { return }
        applySpeakerOverride(on: AVAudioSession.sharedInstance())
    }

    // ── Internals ────────────────────────────────────────────────────────────────

    private func applySpeakerOverride(on session: AVAudioSession) {
        let preferred = lock.withLock { speakerPreferred }
        do {
            // ⚠️ `.none` IS "STOP OVERRIDING", NOT "EARPIECE". It hands the choice back
            // to the category, which is what puts a connected headset or car back in
            // charge — the honest behaviour, and the reason ``AudioRoute`` is reported
            // separately from what was requested.
            try session.overrideOutputAudioPort(preferred ? .speaker : .none)
        } catch {
            // ⚠️ Unreported for the reason given in the category catch above.
        }
    }

    /// ⛔ THE OUTPUT IS RECORDED ON EVERY ROUTE CHANGE IN THE PROCESS, NOT ONLY DURING A
    /// CALL THIS TYPE OWNS. The observer is installed at construction and hears the
    /// meeting engine configure the session too, which is what lets a meeting's speaker
    /// control know where its audio is going. See ``SpeakerToggleRule``.
    private func publishCurrentRoute() {
        let handler = lock.withLock { routeHandler }
        handler?(currentRoute)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        Task { @MainActor in
            AudioOutputs.shared.record(outputs: outputs)
        }
    }

    /// Map the device's own port description onto ``AudioRoute``.
    ///
    /// ⛔ AN UNRECOGNISED PORT BECOMES ``AudioRoute/unknown``, NEVER ``AudioRoute/earpiece``.
    /// The enum's own doc says so: defaulting would state a fact about hardware nobody
    /// asked. CarPlay (`.carAudio`), AirPlay and HDMI land here deliberately — they are
    /// real routes this build does not model, and "unknown" is the true answer rather
    /// than the closest-looking one.
    ///
    /// ⚠️ THE FIRST OUTPUT WINS. A route can carry several, and iOS orders them with the
    /// active output first; a call has exactly one place its audio is going.
    static func route(for description: AVAudioSessionRouteDescription) -> AudioRoute {
        guard let output = description.outputs.first else { return .unknown }
        switch output.portType {
        case .builtInReceiver:
            return .earpiece
        case .builtInSpeaker:
            return .speaker
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth
        case .headphones, .headsetMic, .lineOut, .usbAudio:
            return .wired
        default:
            return .unknown
        }
    }
}
