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
        // ⚠️ READ IN `body`, so the model's observation tracks every value drawn.
        let content = LiveTranscriptContent(model)
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            header(content.status)
            if content.incomplete {
                note(LiveTranscriptCopy.incomplete)
                    .accessibilityIdentifier(A11yID.Calls.liveIncomplete)
            }
            if content.waiting {
                note(LiveTranscriptCopy.waiting)
            }
            ForEach(content.lines, id: \.id) { line in
                lineView(line)
            }
            finalSection(content.final)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Calls.liveTranscript)
    }

    private func header(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(LiveTranscriptCopy.heading)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(status)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    private func lineView(_ line: LiveTranscriptContent.Line) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(line.speaker)
                .font(DistrictType.label)
                .foregroundStyle(colors.foreground)
            Text(line.text)
                .font(DistrictType.bodySmall)
                .italic(line.provisional)
                .foregroundStyle(line.provisional ? colors.mutedForeground : colors.foreground)
            if line.interrupted {
                note(LiveTranscriptCopy.interrupted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func finalSection(_ final: LiveTranscriptContent.Final) -> some View {
        switch final {
        case .none:
            EmptyView()
        case .loading:
            HStack(spacing: DistrictSpacing.hairline) {
                ProgressView()
                note(LiveTranscriptCopy.loadingFull)
            }
        case let .loaded(text):
            DetailFieldCard(label: LiveTranscriptCopy.fullTranscript, value: text)
                .accessibilityIdentifier(A11yID.Calls.transcript)
        case .empty:
            note(LiveTranscriptCopy.noTranscript)
        case let .failed(message):
            Text(message)
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

/// What ``LiveTranscriptSection`` draws, worked out from the model's state in one place: the
/// section only lays it out. A test reads every state here, on both platforms, including the
/// Mac, whose SwiftUI builds no accessibility tree for a unit test to read the drawn words
/// back from.
struct LiveTranscriptContent: Equatable {
    /// One line as drawn.
    struct Line: Equatable {
        let id: String
        let speaker: String
        let text: String
        /// An interim line, drawn muted and italic: the server will replace it.
        let provisional: Bool
        /// "Interrupted" under it: what it says is what was actually played.
        let interrupted: Bool
    }

    /// Below the lines: the full transcript, once the live one has ended.
    enum Final: Equatable {
        /// Not asked for: the transcript has not ended.
        case none
        /// A spinner and "Loading the full transcript…".
        case loading
        case loaded(String)
        /// "No transcript for this call."
        case empty
        /// The failure's words.
        case failed(String)
    }

    /// The line under the heading.
    let status: String
    /// The "earlier lines" note (D3).
    let incomplete: Bool
    /// "Nothing has been said yet": live, and no line on screen.
    let waiting: Bool
    let lines: [Line]
    let final: Final

    @MainActor
    init(_ model: LiveTranscriptModel) {
        status = LiveTranscriptCopy.status(phase: model.phase, connection: model.connection)
        incomplete = !model.complete
        waiting = model.lines.isEmpty && model.phase == .live
        lines = model.lines.map { segment in
            Line(
                id: segment.segmentId,
                speaker: LiveTranscriptCopy.speaker(segment),
                text: segment.text,
                provisional: !segment.final,
                interrupted: segment.interrupted
            )
        }
        final = switch model.finalTranscript {
        case .notRequested: .none
        case .fetching: .loading
        case let .loaded(text): .loaded(text)
        case .empty: .empty
        case let .failed(error): .failed(FailureText.from(error).message)
        }
    }
}
