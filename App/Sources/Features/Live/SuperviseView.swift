import DistrictCall
import DistrictModel
import SwiftUI

/// One live call's supervision: Listen, the note to the receptionist, Take over, Hand back,
/// and the transcript.
///
/// ⛔ ARRIVING HERE STARTS NOTHING. Like ``Route/dialer(workspaceId:role:)``, a destination
/// restored from the path after process death only reads the call again; listening starts
/// with a press, and a person already listening finds the supervision that holds the call
/// (``CallStack/supervisor``) rather than a second one.
struct SuperviseView: View {
    let container: AppContainer
    let workspaceId: String
    let role: WorkspaceRole?
    let callId: String

    @State private var model: SuperviseModel?
    @State private var failure: FailureText?

    var body: some View {
        Group {
            if let model {
                SuperviseScreen(model: model)
            } else if let failure {
                FailureView(failure: failure, onRetry: { Task { await load() } })
            } else {
                LoadingView()
            }
        }
        // ⚠️ THE CALL SCREEN'S OWN TITLE ("Call"), NOT "Live call": the badge under the caller's
        // name already says it is live, and saying it twice read as a stutter.
        .navigationTitle(CallsCopy.call)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if let live = container.callStack.supervisor as? SuperviseModel, live.callId == callId {
            model = live
            return
        }
        guard model == nil else { return }
        failure = nil
        switch await container.calls.detail(workspaceId: workspaceId, callId: callId) {
        case let .success(call):
            model = SuperviseModel.make(container: container, call: call, workspaceId: workspaceId, role: role)
        case let .failure(error):
            failure = error.httpStatus == 404
                ? FailureText(message: CallsCopy.callNotAvailable, action: .none)
                : FailureText.from(error)
        }
    }
}

extension SuperviseModel {
    /// The app's own: the container's repository, its call stack, and two sockets.
    static func make(
        container: AppContainer,
        call: CallSummary,
        workspaceId: String,
        role: WorkspaceRole?
    ) -> SuperviseModel {
        let model = SuperviseModel(
            call: call,
            workspaceId: workspaceId,
            role: role,
            server: container.calls,
            media: media(container: container),
            transcript: LiveTranscriptModel(
                workspaceId: workspaceId,
                callId: call.id,
                dependencies: .live(container: container, workspaceId: workspaceId, callId: call.id)
            ),
            events: LiveEventFeed(workspaceId: workspaceId, dependencies: .live(container: container))
        )
        model.recents = container.listenInRecents
        return model
    }

    private static func media(container: AppContainer) -> any SuperviseMedia {
        #if DEBUG
            // ⚠️ A SCREENSHOT RUN ON A SIMULATOR ONLY: see ``StagedSuperviseMedia``.
            if StagedSuperviseMedia.isArmed() {
                return StagedSuperviseMedia()
            }
        #endif
        return CallStackSuperviseMedia(stack: container.callStack)
    }
}

/// The loaded supervision.
private struct SuperviseScreen: View {
    let model: SuperviseModel

    @State private var confirmingTakeover = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var state: SuperviseState {
        model.state
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                header
                SuperviseCallCard(model: model, confirmingTakeover: $confirmingTakeover)
                // ⛔ HIDDEN, NOT DISABLED, ON A COLLEAGUE'S OWN SOFTPHONE CALL (Sean, Q2): no
                // receptionist is there to read a note.
                if state.receptionistOnCall {
                    SuperviseWhisperCard(model: model)
                } else {
                    Label(SuperviseCopy.receptionistNotOnCall, systemImage: "person.crop.circle.badge.xmark")
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                        .accessibilityIdentifier(A11yID.Live.noReceptionist)
                }
                if state.phase != .over {
                    LiveTranscriptSection(model: model.transcript)
                }
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .alert(SuperviseCopy.takeOverConfirmHeading, isPresented: $confirmingTakeover) {
            Button(SuperviseCopy.takeOverCancel, role: .cancel) {}
            Button(SuperviseCopy.takeOverConfirm) { Task { await model.takeOver() } }
        } message: {
            Text(SuperviseCopy.takeOverConfirmBody)
        }
        // ⛔ BOTH SOCKETS FOLLOW THE SCREEN AND THE SCENE, as the call screen's transcript does.
        .onAppear {
            if scenePhase == .active {
                activate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: activate()
            case .background: deactivate()
            default: break
            }
        }
        .onDisappear { deactivate() }
        // ⛔ SAID ALOUD, NOT ONLY DRAWN (xhigh review of PR #101, item 11): a live microphone, the
        // call ending and the receipt each change what the person may do, and VoiceOver users
        // would otherwise learn of them only by exploring the screen again.
        .onChange(of: state.phase) { _, phase in
            switch phase {
            case .takenOver: announce(SuperviseCopy.takenOverHeading)
            case .over: announce(SuperviseCopy.callEnded)
            default: break
            }
        }
        .onChange(of: state.receipt) { _, receipt in
            guard let receipt else { return }
            let words = SuperviseCopy.receipt(receipt)
            announce([words.headline, words.detail].compactMap(\.self).joined(separator: " "))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Live.supervise)
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func activate() {
        model.events.activate()
        model.transcript.activate()
    }

    private func deactivate() {
        model.events.deactivate()
        model.transcript.deactivate()
    }

    private var header: some View {
        let display = CallDisplay(model.call)
        return VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(display.callerLabel)
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
            HStack(spacing: DistrictSpacing.tight) {
                // ⚠️ THE ROW READ WHEN THE SCREEN OPENED STILL SAYS "in progress" once the call
                // has ended, so the badge follows the supervision, not the row.
                DistrictBadge(
                    text: state.phase == .over ? LiveTranscriptCopy.ended : SuperviseCopy.liveCall,
                    tone: state.phase == .over ? .neutral : .success
                )
                Text(display.timeAndDuration)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
