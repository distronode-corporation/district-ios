import DistrictModel

extension HQVoiceSession {
    /// The session for an HQ screen: the one the call stack holds for this workspace, in any
    /// phase, else a new one it then holds.
    ///
    /// ⛔ HELD BY THE CALL STACK, NOT THE SCREEN (Seer, round 4): a screen rebuilt while a token
    /// is minting or the notice is up finds the same session, so nothing minted is orphaned. A
    /// sign-out or a workspace switch abandons it (``CallStack/endPendingRoom()``).
    ///
    /// ⛔ A SESSION REPLACED BY ANOTHER WORKSPACE'S IS ENDED HERE (Seer, round 7), not left to the
    /// switch: the new screen can be built before the switch's own teardown runs, and that one
    /// then finds only the new session, so a minted token or a notice would be orphaned.
    static func forScreen(container: AppContainer, workspaceId: String, role: WorkspaceRole?) -> HQVoiceSession {
        let stack = container.callStack
        if let held = stack.hqVoice as? HQVoiceSession {
            if held.workspaceId == workspaceId {
                return held
            }
            Task { await held.end() }
        }
        let session = HQVoiceSession(
            workspaceId: workspaceId,
            canConfirm: WorkspaceRole.allowsMutation(role),
            hq: container.hq,
            callStack: stack,
            microphone: microphone(stack),
            makeEngine: engine
        )
        stack.hqVoice = session
        return session
    }

    private static func microphone(_ stack: CallStack) -> any MicrophoneAccess {
        #if DEBUG
            // ⚠️ A SCREENSHOT RUN ON A SIMULATOR ONLY: see ``StagedHQVoiceEngine``.
            if StagedHQVoiceEngine.isArmed() {
                return StagedHQVoiceEngine.microphone
            }
        #endif
        return stack.microphone
    }

    private static func engine(_ key: String) -> any HQVoiceEngine {
        #if DEBUG
            if StagedHQVoiceEngine.isArmed() {
                return StagedHQVoiceEngine()
            }
        #endif
        return LiveKitHQVoiceEngine(e2eeKey: key)
    }
}

extension HQModel {
    /// The console's turns, oldest first, for a voice token (the core bounds them).
    var voiceHistory: [HQVoiceTurn] {
        messages.filter(\.replayable).map { message in
            switch message.speaker {
            case .person: HQVoiceTurn(role: .user, text: message.text)
            case .console: HQVoiceTurn(role: .model, text: message.text)
            }
        }
    }
}
