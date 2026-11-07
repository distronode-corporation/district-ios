import DistrictModel

extension HQVoiceSession {
    /// The session for an HQ screen: the one still live on the call stack for this workspace,
    /// else a new idle one.
    static func forScreen(container: AppContainer, workspaceId: String, role: WorkspaceRole?) -> HQVoiceSession {
        let stack = container.callStack
        if let live = stack.room as? HQVoiceSession, live.workspaceId == workspaceId {
            return live
        }
        return HQVoiceSession(
            workspaceId: workspaceId,
            canConfirm: WorkspaceRole.allowsMutation(role),
            hq: container.hq,
            callStack: stack,
            microphone: microphone(stack),
            makeEngine: engine
        )
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
