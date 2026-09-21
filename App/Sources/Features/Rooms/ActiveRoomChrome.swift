import SwiftUI

// Everything the room draws AROUND the participant grid: the connection banner, the
// Companion chip, the permission notices and the join failure.
//
// ⚠️ A SEPARATE FILE FROM ``ActiveRoomView``, the same split the Kotlin screen makes
// and along the same seam: nothing here touches a participant, a track or a control,
// so the grid and the chrome genuinely have no shared state. Here the ceiling is
// `swiftlint --strict`'s 500-line `file_length` rather than detekt's function count,
// but the cut is the same one. If either half ever needs the other's data, that is
// the signal to reconsider rather than to widen a suppression.

/// ⛔ RENDERED FOR EVERY PHASE EXCEPT `connected`, INCLUDING `reconnecting` — AND
/// `reconnecting` IS TONED AS A WARNING, NEVER AS DANGER. Colouring a recoverable
/// radio handover red is how somebody learns to hang up on a meeting that was about
/// to fix itself.
struct RoomConnectionBanner: View {
    let phase: RoomPhase

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let banner = RoomBanner.of(phase) {
            // ⚠️ FIRST-BASELINE, NOT CENTRE. A dropped-with-reason or a server failure
            // message wraps to several lines at a large text size, and a dot centred
            // against that paragraph floats in the middle of it pointing at nothing.
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                DistrictStatusDot(tone: banner.tone)
                Text(banner.text)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DistrictSpacing.row)
            .background(banner.tone.fill(colors), in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        }
    }
}

/// One banner's two properties, bundled.
///
/// ⚠️ A NAMED TYPE RATHER THAN A TUPLE, because one of the two decides whether a
/// recoverable reconnect is drawn as an error, and a tuple would let the pair be
/// swapped silently at the destructuring site.
///
/// ⛔ FILE SCOPE, NOT NESTED IN A VIEW, for the reason `DistrictButtonVariant`
/// records: a helper nested inside a type that conforms to a protocol with associated
/// types can be picked up as the witness, and the error surfaces somewhere else.
struct RoomBanner {
    let text: String
    let tone: Tone

    /// ⚠️ nil FOR `connected`, WHICH IS WHAT MAKES THE BANNER ABSENT rather than a
    /// green bar over every meeting. ⚠️ `idle` is nil too: before anybody has pressed
    /// Join there is a whole card explaining what is about to happen, and a "not
    /// connected yet" banner above it would be saying the same thing twice.
    static func of(_ phase: RoomPhase) -> RoomBanner? {
        switch phase {
        case .idle, .connected:
            nil
        case .joining:
            RoomBanner(text: RoomsCopy.stateConnecting, tone: .neutral)
        // ⛔ Warning, NOT danger. See the ⛔ on the banner.
        case .reconnecting:
            RoomBanner(text: RoomsCopy.stateReconnecting, tone: .warning)
        case .left:
            RoomBanner(text: RoomsCopy.stateLeft, tone: .neutral)
        // ⛔ WARNING RATHER THAN DANGER, AND THE SENTENCE DOES NOT SAY "you left". The
        // meeting is probably still running and the operator can rejoin; a red bar
        // saying they left would be wrong twice over. See the ⛔ on ``RoomPhase``.
        case let .droppedRemotely(reason):
            RoomBanner(text: RoomBanner.dropped(reason), tone: .warning)
        // ⚠️ NEUTRAL, BECAUSE NOTHING WENT WRONG. Something with a stronger claim on
        // the device's audio took it, which is a fact rather than a fault.
        case let .yielded(reason):
            RoomBanner(text: RoomBanner.yielded(reason), tone: .neutral)
        case let .failed(message):
            RoomBanner(text: message ?? RoomsCopy.stateFailed, tone: .danger)
        }
    }

    /// ⚠️ THE SERVER'S REASON WHEN THERE IS ONE, WHICH IS THE MINORITY CASE. A clean
    /// eviction carries nothing at all.
    private static func dropped(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return RoomsCopy.stateDropped }
        return RoomsCopy.stateDroppedBecause(reason)
    }

    /// ⛔ THE THREE REASONS GET THREE SENTENCES. Which one took the audio is the only
    /// thing that lets the operator connect the meeting vanishing to what they were
    /// doing at the time; "the room ended" would be true and useless.
    private static func yielded(_ reason: RoomAudioYield) -> String {
        switch reason {
        case .telephoneCall:
            RoomsCopy.stateYieldedToCall
        case .sessionEnded:
            RoomsCopy.stateYieldedToSession
        case .workspaceChanged:
            RoomsCopy.stateYieldedToWorkspace
        }
    }
}

/// ⛔ SAYS WHAT THE COMPANION IS DOING, NOT MERELY THAT IT IS HERE. "Companion" alone
/// means nothing to somebody who did not build this; "taking notes" is the fact that
/// matters to a person deciding what to say in the room.
struct RoomCompanionChip: View {
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
            DistrictStatusDot(tone: .district)
            Text(RoomsCopy.companionNotes)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.row)
        .background(Tone.district.fill(colors), in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}

/// ⚠️ NOTHING IS SAID UNTIL THE PERMISSIONS HAVE ACTUALLY BEEN REQUESTED. Before that
/// both flags are false and mean nothing, and a "microphone blocked" warning in that
/// window would be telling somebody something untrue about their own device.
///
/// ⚠️ AND A VIEWER IS TOLD WHY ITS CONTROLS ARE OFF, which is a DIFFERENT reason from
/// a denied permission: one is the workspace's role and the other is the phone's
/// settings, and the remedy differs. It is stated instead of the other two rather
/// than alongside them, because for a viewer the permissions decide nothing.
struct RoomPermissionNotices: View {
    let canPublish: Bool
    let permissions: RoomPermissions

    var body: some View {
        if !canPublish {
            RoomNotice(text: RoomsCopy.viewerNotice)
        } else if permissions.requested {
            if !permissions.microphoneGranted {
                RoomNotice(text: RoomsCopy.noMicrophone)
            }
            if !permissions.cameraGranted {
                RoomNotice(text: RoomsCopy.noCamera)
            }
        }
    }
}

struct RoomNotice: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DistrictSpacing.row)
            .background(colors.muted, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}

/// ⚠️ THE JOIN FAILING IS SHOWN INSTEAD OF THE ROOM, and it is a different fact from
/// the connection phase: the engine never connected, so there is no connection state
/// to report and the reason the user needs is the one the API gave.
struct RoomJoinFailure: View {
    let failure: FailureText

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: RoomsCopy.joinFailed)
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.row)
        .background(Tone.danger.fill(colors), in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}
