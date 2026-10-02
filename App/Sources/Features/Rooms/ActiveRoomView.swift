import DistrictModel
import DistrictNetwork
import SwiftUI

/// A live multi-party room.
///
/// ⛔ IT OPENS ON A JOIN CONTROL AND CONNECTS TO NOTHING BY ITSELF. See the ⛔ on
/// ``ActiveRoomModel``: `Route.activeRoom` is restored from the navigation path after
/// process death, so a `.task` that joined would re-enter a room, re-dispatch its
/// Companion and open a microphone with nobody having asked. This is the one place
/// this client deliberately diverges from the Kotlin screen, which joins from its
/// permission-launcher effect.
///
/// ⛔ `reconnecting` IS A BANNER OVER THE MEETING, NEVER A FAILURE SCREEN. A phone
/// walking out of wifi onto its radio disconnects and resumes within seconds and the
/// SDK does that recovery itself; swapping the grid for an error would tear down a
/// meeting that was about to come back, during exactly the ordinary event it is meant
/// to survive. The tiles stay on screen.
///
/// ⛔ THE COMPANION IS A CHIP AND NOT A TILE, AND BOTH HALVES ARE DELIBERATE. It
/// publishes no media, so a tile would be a blank rectangle in the middle of the grid;
/// it is also transcribing the conversation, so hiding it entirely would mean people
/// are recorded without the screen ever saying so.
///
/// ⛔ A DENIED PERMISSION DEGRADES THE ROOM, IT DOES NOT REFUSE IT. No camera is
/// audio-only attendance; no microphone is listen-only attendance, which is precisely
/// the seat a viewer is given by the server anyway. Both are stated on screen so
/// nobody wonders why a control is inert.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once.
struct ActiveRoomView: View {
    @State private var model: ActiveRoomModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The width the screen's content column was last laid out at; zero until the first
    /// layout. See ``RoomGrid``.
    @State private var gridWidth: CGFloat = 0

    /// ⛔ A SCREEN REBUILT AROUND A LIVE ROOM RE-ATTACHES TO IT. Choosing another sidebar
    /// section and coming back, or a rotation that swaps the tab bar for the sidebar,
    /// destroys this view while ``CallStack`` keeps the meeting publishing; a fresh model
    /// would open on the Join control, over a microphone and camera still live, with Leave
    /// nowhere on screen and every join refused as busy. The claim holds the one model
    /// for this room, so that is the one drawn. A killed process holds none, so a restored
    /// route still opens on Join, which is the ⛔ on this type.
    init(container: AppContainer, roomName: RoomName, role: WorkspaceRole?) {
        let live = ActiveRoomModel.attached(to: container.callStack, roomName: roomName)
        _model = State(
            initialValue: live ?? ActiveRoomModel(container: container, roomName: roomName, role: role)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            RoomConnectionBanner(phase: model.phase)
            if let failure = model.joinFailure {
                RoomJoinFailure(failure: failure)
            }
            if model.companionPresent {
                RoomCompanionChip()
            }
            RoomPermissionNotices(canPublish: model.canPublish, permissions: model.permissions)
            // ⛔ A NOTICE BESIDE THE PERMISSION ONES, NOT A FAILURE BANNER. A refused
            // camera swap leaves a working meeting, so it is toned like "your camera
            // is off" rather than like a lost connection. What it must not be is
            // nothing: a control that does not respond, with the reason nowhere.
            if model.flipFailed {
                RoomNotice(text: RoomsCopy.flipFailed)
            }
            // ⚠️ THE SAME TONE FOR A REFUSED MICROPHONE OR CAMERA CHANGE, for the same
            // reason: the meeting is fine, one control did not do what it was asked.
            if model.microphone.failed {
                RoomNotice(text: Self.microphoneFailed)
            }
            if model.camera.failed {
                RoomNotice(text: Self.cameraFailed)
            }
            content
            controls
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // ⚠️ MEASURED OUTSIDE THE FULL-WIDTH FRAME, minus the gutters, rather than on
        // the stack: the stack is only as wide as its widest child, which before the
        // grid exists is a sentence.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width - DistrictSpacing.gutter * 2
        } action: { width in
            gridWidth = width
        }
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // ⛔ THE LEAVE IS AWAITED BEFORE THE POP, so the room is actually left rather
        // than left to the server's participant timeout. A ghost in the grid is what
        // everybody else sees, and the Companion records the meeting as still running.
        .navigationBarBackButtonHidden(isLive)
    }

    /// ⚠️ ANSWERED BY ``RoomPhase`` RATHER THAN BY A SWITCH HERE, so the controls, the
    /// hidden back button and the model cannot disagree about what "live" means.
    private var isLive: Bool {
        model.phase.isLive
    }

    // MARK: - The body of the screen

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            readyToJoin
        case .joining:
            LoadingView(message: RoomsCopy.stateConnecting)
        case .connected, .reconnecting:
            grid
        case .left:
            // ⚠️ THE GRID IS NOT REDRAWN AFTER A LEAVE OR A LOSS. The banner above
            // already says what happened, and tiles for a room nobody is in would be
            // a picture of a meeting that is over.
            Spacer()
        case .droppedRemotely, .yielded, .failed:
            // ⛔ THE SAME BLANK, PLUS A WAY BACK IN. These three endings were none of
            // the operator's doing and the meeting is very likely still running, so
            // leaving them at a sentence and nothing else renders a failure as an
            // absence. ``RoomPhase/canJoin`` is where the list is decided.
            rejoin
        }
    }

    /// ⛔ NOT OFFERED AFTER `left`. The operator asked to leave and the screen pops
    /// behind them; the lobby's own Rejoin entry is how somebody goes back on purpose.
    private var rejoin: some View {
        VStack {
            Spacer()
            Button(RoomsCopy.rejoinRoom) {
                Task { await model.join() }
            }
            .buttonStyle(.districtSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// ⛔ THE COMPANION IS NAMED BEFORE ANYBODY JOINS, NOT AFTER. It is dispatched
    /// into every `meet_` room and transcribes what is said; being told afterwards is
    /// being told too late, which is why this sentence is on the pre-join card rather
    /// than only on the chip inside the room.
    private var readyToJoin: some View {
        VStack(spacing: DistrictSpacing.row) {
            EmptyStateView(
                systemImage: "video",
                title: RoomsCopy.readyTitle,
                message: RoomsCopy.readyBody(model.displayName)
            )
            Button(RoomsCopy.joinNow) {
                Task { await model.join() }
            }
            .buttonStyle(.districtPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    /// ⛔ A PARTICIPANT WITH NO VIDEO STILL GETS A TILE, and an empty room gets a
    /// sentence rather than a blank rectangle. See ``RoomParticipantTile``.
    ///
    /// ⚠️ KEYED ON THE SERVER-DERIVED IDENTITY, which is the EVICTION key: the same
    /// human rejoining replaces themselves rather than producing a second tile.
    @ViewBuilder
    private var grid: some View {
        if model.tiles.isEmpty {
            VStack {
                EmptyStateView(
                    systemImage: "person.2",
                    title: RoomsCopy.aloneTitle,
                    message: RoomsCopy.aloneBody
                )
                selfTile
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: DistrictSpacing.tight) {
                    ForEach(model.tiles) { participant in
                        RoomParticipantTile(participant: participant)
                    }
                }
                selfTile
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, DistrictSpacing.tight)
            }
        }
    }

    @ViewBuilder
    private var selfTile: some View {
        if let track = model.localVideo {
            RoomSelfTile(track: track, gridWidth: gridWidth)
        }
    }

    /// ⚠️ ONE COLUMN AT AN ACCESSIBILITY TEXT SIZE. Half the screen width holds a
    /// name at the default size and about four characters of one at AX5, so the grid
    /// that shows who is in the room stops answering that question exactly when the
    /// person reading it needs the biggest type.
    private var gridColumns: [GridItem] {
        let columns = dynamicTypeSize.isAccessibilitySize
            ? 1
            : RoomGrid.columns(width: gridWidth, tiles: model.tiles.count, spacing: DistrictSpacing.tight)
        return Array(repeating: GridItem(.flexible(), spacing: DistrictSpacing.tight), count: columns)
    }

    // MARK: - The controls

    /// ⛔ DISABLED RATHER THAN HIDDEN WHEN A PERMISSION OR THE ROLE FORBIDS THEM. A
    /// missing control makes somebody hunt for it; a disabled one beside a notice
    /// saying why is the pair that explains the state, and the notices are above.
    ///
    /// ⛔ THE SHARE CONTROL IS ABSENT RATHER THAN DISABLED when the server minted no
    /// invite. A disabled share would suggest a viewer could invite somebody if only
    /// something else were true; the refusal is categorical. See
    /// ``ActiveRoomModel/guestLink``.
    @ViewBuilder
    private var controls: some View {
        if isLive {
            VStack(spacing: DistrictSpacing.tight) {
                HStack(spacing: DistrictSpacing.tight) {
                    Button(model.microphone.isOn ? RoomsCopy.micOn : RoomsCopy.micOff) {
                        Task { await model.toggleMicrophone() }
                    }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary, size: .small))
                    // ⚠️ AND WHILE A CHANGE IS IN FLIGHT. See ``RoomMediaToggle``.
                    .disabled(
                        !model.canPublish || !model.permissions.microphoneGranted || model.microphone.inFlight
                    )

                    Button(model.camera.isOn ? RoomsCopy.cameraOn : RoomsCopy.cameraOff) {
                        Task { await model.toggleCamera() }
                    }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary, size: .small))
                    .disabled(!model.canPublish || !model.permissions.cameraGranted || model.camera.inFlight)

                    Button(RoomsCopy.flip) {
                        Task { await model.flipCamera() }
                    }
                    .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
                    // ⚠️ Only while the camera is publishing: flipping an off camera
                    // does nothing visible, so an enabled control would report success
                    // for an action with no effect.
                    .disabled(!model.camera.isOn)

                    // ⛔ ABSENT WHERE THERE IS NO EARPIECE, as on the call screen. See
                    // ``SpeakerToggleRule``.
                    if AudioOutputs.shared.offersSpeakerToggle(speakerRequested: model.speakerOn) {
                        Button(model.speakerOn ? RoomsCopy.speakerOn : RoomsCopy.speakerOff) {
                            model.toggleSpeaker()
                        }
                        .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
                    }
                }
                HStack(spacing: DistrictSpacing.tight) {
                    Button(RoomsCopy.leave) {
                        Task {
                            await model.leave()
                            dismiss()
                        }
                    }
                    .buttonStyle(.districtDestructive)

                    if let link = model.guestLink {
                        ShareLink(item: link) {
                            Text(RoomsCopy.shareInvite)
                        }
                        .buttonStyle(.districtSecondary)
                    }
                }
            }
        }
    }

    // ⚠️ HERE RATHER THAN IN ``RoomsCopy`` ONLY BECAUSE THAT FILE BELONGS TO ANOTHER
    // CHANGE SET TODAY; move them beside ``RoomsCopy/flipFailed`` when it is free.
    // Like that sentence they name no cause, because the SDK's reason is not known here.
    static let microphoneFailed = "Could not change your microphone. It is as the button shows."
    static let cameraFailed = "Could not change your camera. It is as the button shows."
}

extension ActiveRoomModel {
    /// The model holding this room's claim, if the meeting is live.
    ///
    /// ⚠️ MATCHED ON THE ROOM'S NAME, so a screen for one room never draws another's
    /// meeting; the claim is one room per process, and a different name gets a fresh
    /// model whose Join is refused as busy.
    static func attached(to calls: CallStack, roomName: RoomName) -> ActiveRoomModel? {
        guard let live = calls.room as? ActiveRoomModel, live.roomName == roomName else { return nil }
        return live
    }
}
