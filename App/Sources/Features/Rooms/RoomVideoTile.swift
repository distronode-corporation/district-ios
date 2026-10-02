import LiveKit
import SwiftUI
import UIKit

/// The one place in this app that renders a video track.
///
/// ⛔ A HAND-WRITTEN `UIViewRepresentable` OVER THE SDK's `VideoView` RATHER THAN THE
/// SDK's OWN SwiftUI WRAPPER, AND THAT IS A DELIBERATE NARROWING OF RISK. Nothing on
/// the Linux tier can compile a LiveKit symbol, so every SDK name here is checked
/// only by the app build; `VideoView` is a `UIView` whose
/// `track`, `layoutMode` and `mirrorMode` members are the SDK's oldest and most
/// documented surface, while the SwiftUI wrapper's initialiser shape has moved
/// between releases. Betting on three properties of a UIView is a smaller bet than
/// betting on a generic initialiser, and if the wrapper is preferred later this file
/// is the only thing that changes.
///
/// ⛔ AND IT IS WHY NO OTHER FILE IN THE ROOMS FEATURE NAMES A TRACK TYPE FOR RENDERING.
/// `ActiveRoomView` hands over an opaque handle and learns nothing about what is
/// inside it, the same seam the Kotlin client draws with its `VideoTile`.
struct RoomVideoTile: UIViewRepresentable {
    let track: VideoTrack

    /// ⚠️ MIRRORED FOR THE SELF TILE ONLY. A mirrored remote participant is somebody
    /// else's face flipped, which is wrong; an unmirrored self tile is the thing
    /// everybody finds unsettling about their own camera.
    var mirrored = false

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        view.mirrorMode = mirrored ? .mirror : .off
        view.track = track
        return view
    }

    /// ⚠️ THE TRACK IS ASSIGNED UNCONDITIONALLY RATHER THAN COMPARED FIRST. `VideoTrack`
    /// is a protocol and an identity comparison would need it to be class-constrained,
    /// which is one more unverifiable assumption than this view is worth; the SDK's
    /// setter is the thing that decides whether a re-assignment costs anything.
    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.mirrorMode = mirrored ? .mirror : .off
        uiView.track = track
    }
}

/// One participant's cell in the grid.
///
/// ⛔ A PARTICIPANT WITH NO VIDEO STILL GETS A TILE. Camera-off is the normal way to
/// be in a meeting, and dropping those people from the grid would make the room look
/// emptier than it is. That is the dangerous direction: it is what somebody checks
/// before saying something private.
struct RoomParticipantTile: View {
    let participant: RoomParticipantSnapshot

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var label: String {
        let trimmed = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? RoomsCopy.unnamedParticipant : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            surface
            HStack(spacing: DistrictSpacing.hairline) {
                // ⚠️ A MUTED PARTICIPANT IS MARKED, because "why can I not hear them"
                // is the most common question in a room and this is usually why.
                //
                // ⛔ BY SHAPE, NOT ONLY BY COLOUR. A green dot for live and a grey one
                // for muted is the same dot twice to anyone who cannot separate those
                // hues, and it is one indistinct dot under Grayscale — WCAG 1.4.1 is
                // precisely this case. The muted tile carries a struck-through
                // microphone, which reads without any colour at all.
                // ⚠️ HIDDEN FROM VOICEOVER because the tile's own accessibility label
                // already ends "muted"; announcing the glyph as well would say it twice.
                if participant.isMicrophoneEnabled {
                    DistrictStatusDot(tone: .success)
                } else {
                    Image(systemName: "mic.slash.fill")
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                        .accessibilityHidden(true)
                }
                // ⚠️ A SECOND LINE AT AN ACCESSIBILITY SIZE. One line under a tile
                // is right at the default size and truncates a name to two or three
                // characters at AX5, which is worse than no name at all — the grid
                // exists to say who is in the room.
                Text(label)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
            }
        }
        .padding(DistrictSpacing.tight)
        .districtCardSurface(bordered: false)
        .accessibilityElement(children: .combine)
        // ⛔ THE MUTE STATE MUST BE IN THE LABEL. The dot beside the name is the only
        // thing marking a muted participant, and an explicit `.accessibilityLabel`
        // REPLACES everything `.combine` gathered — so without it VoiceOver announces
        // the name and nothing else, losing the one fact the tile adds. "Why can I not hear
        // them" is the most common question in a room, and this is usually the answer.
        .accessibilityLabel(
            participant.isMicrophoneEnabled ? label : RoomsCopy.mutedParticipant(label)
        )
    }

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DistrictRadius.control)
                .fill(colors.muted)
            if let track = participant.video {
                RoomVideoTile(track: track)
                    .clipShape(RoundedRectangle(cornerRadius: DistrictRadius.control))
            } else {
                // ⚠️ AN AUDIO-ONLY TILE, NOT AN OMISSION. See the ⛔ on this type.
                DistrictAvatar(name: label)
            }
        }
        .aspectRatio(RoomGrid.tileAspect, contentMode: .fit)
    }
}

/// The self tile.
///
/// ⛔ DRAWN FROM THE LOCAL TRACK RATHER THAN FROM THE ROSTER, AND ONLY WHEN THE CAMERA
/// IS ON. The engine's roster deliberately excludes the local participant (a self tile
/// taken from the same source double-counts after a reconnect), so this is a separate
/// small view rather than a row in the grid, and it disappears with the camera instead
/// of leaving a dead rectangle on screen.
struct RoomSelfTile: View {
    let track: VideoTrack
    /// The width the grid it sits under was given. See ``RoomGrid/selfTileSize(width:)``.
    let gridWidth: CGFloat

    var body: some View {
        let size = RoomGrid.selfTileSize(width: gridWidth)
        RoomVideoTile(track: track, mirrored: true)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: DistrictRadius.control))
            .accessibilityHidden(true)
    }
}

/// The grid's own measurements, as functions of the width the grid is given.
///
/// ⚠️ NEVER FEWER THAN TWO COLUMNS, MATCHING THE KOTLIN LOBBY'S `GRID_COLUMNS`, and on
/// a phone never more: no phone is wide enough for three tiles that still show a face,
/// so every phone width resolves to exactly two.
///
/// ⛔ DECIDED FROM THE MEASURED WIDTH, NEVER FROM THE DEVICE. An iPad in narrow Split
/// View or Slide Over is a phone-width column and gets the phone's grid; the same iPad
/// full screen has room for four faces side by side.
enum RoomGrid {
    static let minimumColumns = 2
    static let maximumColumns = 4
    /// The narrowest a tile may be drawn at before a face stops reading as one.
    static let minimumTileWidth: CGFloat = 220
    static let tileAspect: CGFloat = 4.0 / 3.0

    /// ⚠️ NO MORE COLUMNS THAN THERE ARE PEOPLE, above the two-column floor: three
    /// guests in four columns would leave an empty quarter and draw everybody smaller
    /// than the width allows.
    ///
    /// ⚠️ A WIDTH OF ZERO IS "NOT MEASURED YET", which is the first frame of every
    /// room, and it resolves to the floor rather than to one column.
    static func columns(width: CGFloat, tiles: Int, spacing: CGFloat) -> Int {
        let fit = Int((width + spacing) / (minimumTileWidth + spacing))
        return max(minimumColumns, min(fit, maximumColumns, tiles))
    }

    /// The self tile: 96 by 128 on a phone-width grid, half as large again on a wider
    /// one, so it stays a corner picture rather than a thumbnail beside tiles three
    /// times its size.
    ///
    /// ⚠️ THE THRESHOLD IS THE WIDTH AT WHICH ``columns(width:tiles:spacing:)`` COULD
    /// FIRST GO PAST TWO, so the self tile grows exactly when the grid does.
    static func selfTileSize(width: CGFloat) -> CGSize {
        let tileWidth: CGFloat = width >= regularGridWidth ? 144 : 96
        return CGSize(width: tileWidth, height: tileWidth * tileAspect)
    }

    /// Three minimum tiles and the two gaps between them.
    static let regularGridWidth: CGFloat = minimumTileWidth * 3 + DistrictSpacing.tight * 2
}
