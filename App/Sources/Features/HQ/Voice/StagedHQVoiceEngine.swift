#if DEBUG

    import DistrictModel
    import Foundation

    /// An HQ voice room that joins at once and plays one short scripted exchange, for
    /// screenshots on a simulator against a local fixture server.
    ///
    /// ⛔ THE WHOLE FILE IS INSIDE `#if DEBUG`, for ``StagedSuperviseMedia``'s reason: a
    /// shipped binary has neither the type nor the variable that arms it.
    ///
    /// ⛔ ARMED ONLY BY BOTH HALVES: the `-UITestSession` launch argument AND
    /// `DISTRICT_UITEST_STAGED_MEDIA=1`. Only the ROOM is staged; the session, the token, the
    /// notice, the screen reports and the proposal routes are the real ones, against whatever
    /// server the session names.
    @MainActor
    final class StagedHQVoiceEngine: HQVoiceEngine {
        static func isArmed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            StagedSuperviseMedia.isArmed(environment: environment)
        }

        static let microphone: any MicrophoneAccess = StagedMicrophone()

        let events: AsyncStream<HQVoiceEngineEvent>
        private let continuation: AsyncStream<HQVoiceEngineEvent>.Continuation
        private var script: Task<Void, Never>?

        init() {
            (events, continuation) = AsyncStream<HQVoiceEngineEvent>.makeStream()
        }

        func connect(url _: String, token _: String) async throws {
            continuation.yield(.connected)
            let french = AppL10n.copyLocale == .frCA
            let steps: [(Int, HQVoiceEngineEvent)] = [
                (300, .agentState(.listening)),
                (900, .transcript(HQVoiceSegment(
                    id: "seg-1",
                    text: french ? "Ajoute une note à la fiche de Maya Chen." : "Add a note to Maya Chen's contact.",
                    isFinal: true,
                    fromMember: true
                ))),
                (1500, .agentState(.thinking)),
                (2300, .agentState(.speaking)),
                (2400, .transcript(HQVoiceSegment(
                    id: "seg-2",
                    text: french ? "D'accord. Je propose cette note; dites « confirmer » ou touchez Confirmer."
                        : "Sure. Here is the note; say confirm, or tap Confirm.",
                    isFinal: true,
                    fromMember: false
                ))),
                (2600, .packet(.proposal(HQVoiceProposal(
                    proposalId: "prop-staged-1",
                    tool: "add_contact_note",
                    args: .object(["contactId": .string("c_maya"), "note": .string("Prefers morning visits.")]),
                    summary: french ? "Ajouter la note « Préfère les visites le matin » à Maya Chen."
                        : "Add the note \"Prefers morning visits\" to Maya Chen."
                )))),
                (3400, .agentState(.listening)),
            ]
            let continuation = continuation
            script = Task {
                var elapsed = 0
                for (at, event) in steps {
                    try? await Task.sleep(for: .milliseconds(at - elapsed))
                    elapsed = at
                    guard !Task.isCancelled else { return }
                    continuation.yield(event)
                }
            }
        }

        func setMicrophone(enabled: Bool) async -> Bool {
            enabled
        }

        func disconnect() async {
            script?.cancel()
            continuation.finish()
        }
    }

    /// A microphone the staged room may always use: no system alert over a screenshot run.
    private struct StagedMicrophone: MicrophoneAccess {
        var status: MicrophoneStatus {
            .granted
        }

        func request() async -> Bool {
            true
        }
    }

#endif
