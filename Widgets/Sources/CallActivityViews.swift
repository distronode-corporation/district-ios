import ActivityKit
import SwiftUI
import WidgetKit

/// What every view of the activity reads, decided once from the context.
///
/// ⛔ NOTHING HERE IS LOGGED: a caller's name and a line of the conversation (Sean's decision,
/// 2026-10-25, GitLab #2).
struct CallActivityContent {
    let phase: DistrictCallActivityPhase
    let caller: String
    let startedAt: Date?
    let endedAt: Date?
    let line: String?
    let speaker: String?
    let stale: Bool

    init(_ context: ActivityViewContext<DistrictCallActivityAttributes>) {
        let state = context.state
        phase = state.phase
        // ⚠️ A NAME THE STATE CARRIES WINS: it was resolved after the start.
        let name = [state.callerName, context.attributes.callerName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        caller = name ?? WidgetCopy.noCallerId
        startedAt = DistrictCallActivityTime.date(state.startedAt)
        endedAt = DistrictCallActivityTime.date(state.endedAt)
        line = state.latestLine.flatMap(DistrictCallActivityLine.clip)
        speaker = switch state.latestSpeaker {
        case .caller: WidgetCopy.speakerCaller
        case .assistant: WidgetCopy.speakerAssistant
        case nil: nil
        }
        stale = context.isStale
    }

    var status: String {
        switch phase {
        case .ringing: WidgetCopy.phaseRinging
        case .aiAnswering: WidgetCopy.phaseAiAnswering
        case .declined: WidgetCopy.phaseDeclined
        case .messageTaken: WidgetCopy.phaseMessageTaken
        case .transferred: WidgetCopy.phaseTransferred
        case .ended: WidgetCopy.phaseEnded
        }
    }
}

/// The Lock Screen banner, and the watch's Smart Stack.
///
/// ⚠️ THE WATCH ASKS FOR `.small`; the Lock Screen is `.medium`.
struct CallActivityLockScreen: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<DistrictCallActivityAttributes>

    var body: some View {
        let call = CallActivityContent(context)
        switch family {
        case .small:
            CallActivitySmall(call: call)
        default:
            CallActivityBanner(call: call, lineLimit: 2)
        }
    }
}

struct CallActivityBanner: View {
    let call: CallActivityContent
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                CallActivityGlyph(phase: call.phase)
                Text(call.caller)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CallActivityClock(call: call)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            CallActivityDetail(call: call, lineLimit: lineLimit)
        }
        .padding(16)
    }
}

/// The Apple Watch Smart Stack: the caller, the status, and the latest line in one line.
struct CallActivitySmall: View {
    let call: CallActivityContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                CallActivityGlyph(phase: call.phase)
                Text(call.caller)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(call.line ?? call.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}

/// The status, the latest line, and a note when the activity is out of date.
struct CallActivityDetail: View {
    let call: CallActivityContent
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(call.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let line = call.line {
                Text(Self.attributed(speaker: call.speaker, line: line))
                    .font(.callout)
                    .lineLimit(lineLimit)
            }
            if call.stale {
                Text(WidgetCopy.stale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Caller · line", the speaker in bold. ⚠️ Plain strings, never a localization key: the
    /// line is the caller's own words.
    static func attributed(speaker: String?, line: String) -> AttributedString {
        guard let speaker else { return AttributedString(line) }
        var head = AttributedString(speaker)
        head.inlinePresentationIntent = .stronglyEmphasized
        return head + AttributedString(" · " + line)
    }
}

/// The time on the call: counting up while it goes, the end time once over.
///
/// ⚠️ THE COMPACT ISLAND IS NARROW, AND ONLY THE RUNNING TIMER IS CAPPED. A `Text(timerInterval:)`
/// sizes itself for the longest value it could show, so without a cap it pushes the island
/// wide; the end time is a fixed string and is never capped, or `12:53 p.m.` truncates to
/// `12:5…` (3.2.0 visual QA). In compact the end time drops its day period (`12:53`,
/// `13 h 19`): the Lock Screen and the expanded island beside it carry the full time.
struct CallActivityClock: View {
    let call: CallActivityContent
    var compact = false

    var body: some View {
        if call.phase.isOver {
            if let endedAt = call.endedAt {
                Text(endedAt.formatted(compact ? Self.compactEnd : Self.end))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else if let startedAt = call.startedAt {
            Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: compact ? 44 : nil)
        }
    }

    private static var end: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: WidgetL10n.locale)
    }

    /// Hour and minute, no day period: `12:53` / `13 h 19`.
    private static var compactEnd: Date.FormatStyle {
        Date.FormatStyle(locale: WidgetL10n.locale).hour(.defaultDigits(amPM: .omitted)).minute()
    }
}

/// One symbol per phase, so the Dynamic Island's smallest forms still say something.
struct CallActivityGlyph: View {
    let phase: DistrictCallActivityPhase

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .ringing: "phone.arrow.down.left"
        case .aiAnswering: "waveform"
        case .declined, .messageTaken: "text.bubble"
        case .transferred: "arrow.triangle.branch"
        case .ended: "phone.down"
        }
    }
}
