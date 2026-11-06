#if DEBUG

    import DistrictCall
    import Foundation

    /// A device that performs every system call and joins every room at once, for screenshots of
    /// a supervision on a simulator against a local fixture server.
    ///
    /// ⛔ THE WHOLE FILE IS INSIDE `#if DEBUG`, FOR ``UITestSession``'S REASON: the archive is a
    /// Release build, so neither the type nor the variable that arms it exists in a shipped
    /// binary (`archive-imac.sh` counts `DISTRICT_UITEST` in the archive and requires 0).
    ///
    /// ⛔ ARMED ONLY BY BOTH HALVES: the `-UITestSession` launch argument AND
    /// `DISTRICT_UITEST_STAGED_MEDIA=1`. What it stands in for is only the DEVICE (CallKit and
    /// the LiveKit room); the reducer, the three routes, the telemetry socket and the screens are
    /// the real ones, against whatever server the session names.
    @MainActor
    final class StagedSuperviseMedia: SuperviseMedia {
        static let variable = "DISTRICT_UITEST_STAGED_MEDIA"

        static func isArmed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            UITestSession.isArmed() && environment[variable] == "1"
        }

        let hasLiveCall = false
        let hasLiveRoom = false
        let microphone: any MicrophoneAccess = GrantedMicrophone()

        private var handler: ((CallKitRequest) -> Void)?
        private var events: AsyncStream<CallEngineEvent>.Continuation?

        func claim(_: AnyObject, handler: @escaping (CallKitRequest) -> Void) {
            self.handler = handler
        }

        func release(_: AnyObject) {
            handler = nil
        }

        func startCall(uuid: UUID, handle _: String, onRefused _: @escaping @MainActor @Sendable () -> Void) {
            after(milliseconds: 800) { $0.handler?(.dialRequested(uuid: uuid)) }
        }

        func reportConnecting(uuid _: UUID, callerName _: String) {}
        func reportConnected(uuid _: UUID) {}
        func requestEnd(uuid _: UUID) {}
        func reportEnded(uuid _: UUID) {}

        /// ⚠️ ECHOED, AS CALLKIT ECHOES IT: the model applies a mute only when the OS performs it.
        func requestMuted(uuid: UUID, muted: Bool) {
            after(milliseconds: 0) { $0.handler?(.muteRequested(uuid: uuid, muted: muted)) }
        }

        func beginLeg(_: SuperviseLeg) async -> AsyncStream<CallEngineEvent> {
            events?.finish()
            let (stream, continuation) = AsyncStream<CallEngineEvent>.makeStream()
            events = continuation
            return stream
        }

        func perform(_ command: CallCommand) async {
            switch command {
            case .connect:
                // ⚠️ THE CALLER AND THE RECEPTIONIST ARE IN THE ROOM, ANNOUNCED AS JOINS: that is
                // what a supervise leg's engine does for the people present at the join
                // (``LiveKitCallEngine``'s `announcesPresentParticipants`; the SDK alone does not).
                let events = events
                after(milliseconds: 3000) { _ in
                    events?.yield(.participantJoined(CallParticipant(identity: "caller", name: nil, isAgent: false)))
                    events?.yield(.participantJoined(CallParticipant(identity: "agent", name: "Ava", isAgent: true)))
                    events?.yield(.connected)
                }
            case let .setMuted(muted):
                events?.yield(.microphoneChanged(enabled: !muted))
            case .disconnect, .setSpeakerphone:
                break
            }
        }

        func endLeg() {
            events?.finish()
            events = nil
        }

        private func after(milliseconds: Int, _ work: @escaping @MainActor (StagedSuperviseMedia) -> Void) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard let self else { return }
                work(self)
            }
        }
    }

    /// A microphone the staged device may always use: no system alert over a screenshot run.
    private struct GrantedMicrophone: MicrophoneAccess {
        var status: MicrophoneStatus {
            .granted
        }

        func request() async -> Bool {
            true
        }
    }

#endif
