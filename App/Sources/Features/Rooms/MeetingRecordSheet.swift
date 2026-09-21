import DistrictModel
import SwiftUI

/// One meeting's full record.
///
/// ⛔ ITS OWN FILE, AND THAT IS WORTH MORE THAN THE LINE COUNT IT SAVES: this is the
/// only place in the app that displays a meeting TRANSCRIPT, so keeping it here makes
/// that surface one file to review rather than a section of a longer one. The Kotlin
/// client split it out for the same reason.
///
/// ⛔ THE TRANSCRIPT IS BEHIND AN EXPLICIT SECTION LABEL AND IS NOT THE FIRST THING
/// SHOWN. It is every word everybody said, unredacted and unsummarised; the minutes
/// are what somebody opening this actually wants, and putting the raw conversation
/// first would mean the sensitive thing is what appears on screen before anyone has
/// decided to read it. `MeetingDetail.transcript` carries the same ⚠️ on the wire type.
///
/// ⛔ AND THERE IS NO PLAY CONTROL. The `Meeting` model has no recording column and
/// neither meetings route has a recording sibling; the artefacts are these two.
///
/// ⚠️ SCROLLS INTERNALLY. A transcript is arbitrarily long, and a sheet that grew with
/// it would push its own dismiss control off the screen.
struct MeetingRecordSheet: View {
    /// ⚠️ OPTIONAL BECAUSE THE SHEET'S PRESENTATION IS DRIVEN BY THE SAME VALUE. nil
    /// is only reachable during the dismissal animation, and it draws the loading
    /// state rather than an empty sheet.
    let state: MeetingRecordState?
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                    content(for: state)
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(RoomsCopy.recordTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(RoomsCopy.recordClose, action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for state: MeetingRecordState?) -> some View {
        switch state {
        case .loading, .none:
            SkeletonBlock(height: DistrictSpacing.header)
        case let .ready(meeting):
            record(meeting)
        case let .failed(failure):
            // ⚠️ A 404 HERE MEANS "not yours OR not there", indistinguishably, so the
            // sentence is the server's rather than one that promises which.
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                DistrictEyebrow(text: RoomsCopy.recordFailed)
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            }
        }
    }

    @ViewBuilder
    private func record(_ meeting: MeetingDetail) -> some View {
        DistrictEyebrow(text: RoomsCopy.recordMinutes)
        Text(text(meeting.summary) ?? RoomsCopy.noMinutesYet)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .textSelection(.enabled)
        if let transcript = text(meeting.transcript) {
            DistrictEyebrow(text: RoomsCopy.recordTranscript)
                .padding(.top, DistrictSpacing.tight)
            Text(transcript)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .textSelection(.enabled)
        }
    }

    /// ⚠️ BLANK COUNTS AS ABSENT, the shared normalisation rule this client follows
    /// everywhere. An in-progress meeting genuinely has neither, and an empty block
    /// reads as a fault where a sentence reads as an answer.
    private func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
