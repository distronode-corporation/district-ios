import AVFoundation

/// Whether this app may use the microphone, as the OS last answered.
///
/// ⚠️ THREE STATES, NOT A BOOL, BECAUSE "NEVER ASKED" IS THE ONE THAT MATTERS. A call's audio
/// engine reads the grant passively and refuses to record without it (LiveKit's WebRTC
/// `AudioEngineDevice` answers `kAudioEngineErrorInsufficientDevicePermission`, and
/// `Room.connect` rethrows it as `deviceAccessDenied`), so a question nobody asked fails a call
/// exactly as a refusal does. Only `notDetermined` can still be fixed by asking.
enum MicrophoneStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// The microphone permission, behind a seam.
///
/// ⛔ NOTHING THAT PUBLISHES CALL AUDIO MAY ASSUME THE PROMPT HAPPENED SOMEWHERE ELSE. If only a
/// meeting room and the persona preview asked, then on a fresh install the first dial and the first
/// answer would both fail at the media join: the dial after the carrier had already rung the
/// callee, and the answer after the server had already bridged the caller. So ``DialerModel`` asks
/// before the OS or the carrier hears about a call, ``IncomingCallModel`` asks at a foreground
/// Answer, and `RootView` asks once at the first signed-in landing for the answer that cannot
/// prompt (see ``askAtLanding()``).
///
/// ⚠️ A PROTOCOL SO BOTH CALL MODELS CAN BE DRIVEN WITHOUT A SYSTEM ALERT. It is held by
/// ``CallStack``, the platform half of a call, and injected through ``AppContainer``.
protocol MicrophoneAccess: Sendable {
    /// The grant as the OS holds it now. ⚠️ Passive: reading it never prompts.
    var status: MicrophoneStatus { get }

    /// Ask, or answer at once when the question has already been answered.
    ///
    /// - Returns: whether the microphone may be used.
    func request() async -> Bool
}

/// The real permission.
///
/// ⚠️ `AVCaptureDevice`, NOT `AVAudioApplication`, SO THE APP ASKS ONE WAY. The persona preview
/// and the meeting room already ask through it, and it is the authorization the WebRTC engine
/// checks before it will record.
struct LiveMicrophoneAccess: MicrophoneAccess {
    var status: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

extension MicrophoneAccess {
    /// Ask once at the signed-in landing, and only if nobody has asked yet.
    ///
    /// ⛔ A TELEPHONE APP THAT ASKS AT LANDING RATHER THAN AT USE, AND THE LOCK SCREEN IS WHY. An
    /// answer from the lock screen, a car or a headset reaches ``IncomingCallModel`` with the app in
    /// the background, where no permission alert can be put in front of anybody, so the only moment
    /// a person can grant it for that answer is one when the app is on screen. The dial and the
    /// foreground Answer still ask for themselves.
    ///
    /// ⚠️ IT NEVER NAGS. An answered question stays answered either way; a refusal is reversed in
    /// Settings, not by asking again.
    ///
    /// ⚠️ SKIPPED UNDER A UI-TEST SESSION, so an XCUITest run on a fresh simulator is not stopped by a
    /// system alert over the shell it is driving. Debug-only, like ``UITestSession`` itself.
    func askAtLanding() async {
        #if DEBUG
            guard !UITestSession.isArmed() else { return }
        #endif
        guard status == .notDetermined else { return }
        _ = await request()
    }
}
