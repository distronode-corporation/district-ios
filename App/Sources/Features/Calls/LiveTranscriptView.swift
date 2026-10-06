import DistrictLive
import DistrictModel
import SwiftUI

/// The live transcript on a call's screen, while the call is in progress, and the full
/// transcript in the same place once the call has ended.
///
/// ⚠️ AN INTERIM LINE IS DRAWN AS PROVISIONAL (muted, italic): the server will replace it. The
/// first version of the server sends finished turns only, so none appears yet; the app is
/// ready for them from day one.
struct LiveTranscriptSection: View {
    let model: LiveTranscriptModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            header
            if !model.complete {
                note(LiveTranscriptCopy.incomplete)
                    .accessibilityIdentifier(A11yID.Calls.liveIncomplete)
            }
            if model.lines.isEmpty, model.phase == .live {
                note(LiveTranscriptCopy.waiting)
            }
            ForEach(model.lines, id: \.segmentId) { line in
                lineView(line)
            }
            finalSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Calls.liveTranscript)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(LiveTranscriptCopy.heading)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(LiveTranscriptCopy.status(phase: model.phase, connection: model.connection))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    private func lineView(_ line: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(LiveTranscriptCopy.speaker(line))
                .font(DistrictType.label)
                .foregroundStyle(colors.foreground)
            Text(line.text)
                .font(DistrictType.bodySmall)
                .italic(!line.final)
                .foregroundStyle(line.final ? colors.foreground : colors.mutedForeground)
            if line.interrupted {
                note(LiveTranscriptCopy.interrupted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var finalSection: some View {
        switch model.finalTranscript {
        case .notRequested:
            EmptyView()
        case .fetching:
            HStack(spacing: DistrictSpacing.hairline) {
                ProgressView()
                note(LiveTranscriptCopy.loadingFull)
            }
        case let .loaded(text):
            DetailFieldCard(label: LiveTranscriptCopy.fullTranscript, value: text)
                .accessibilityIdentifier(A11yID.Calls.transcript)
        case .empty:
            note(LiveTranscriptCopy.noTranscript)
        case let .failed(error):
            Text(FailureText.from(error).message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
    }
}
