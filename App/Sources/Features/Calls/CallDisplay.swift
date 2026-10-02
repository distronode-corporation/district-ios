import DistrictModel
import Foundation

/// The display rules for one call, derived ONCE. Port of Android's `CallDisplay.kt`.
///
/// ⛔ THIS EXISTS BECAUSE THE RULES HAD ALREADY DRIFTED ON THE OTHER CLIENT, AND ONE
/// OF THE DRIFTS HID A FAILURE. The call log and the call detail screen each
/// re-derived these fields inline, with the six wire constants below copied into
/// three files. Two divergences shipped:
///
///   1. ⛔ A FAILED TRANSFER WAS INVISIBLE IN THE CALL LOG. The log rendered only the
///      `success` chip, so the one list an operator scans specifically to find calls
///      that did not reach a human was the one place that would not say so.
///   2. The detail screen appended the duration unconditionally where the log guarded
///      on `durationRaw > 0`, so a missed call read "· 0s", meaning a call that
///      never connected reported a length.
///
/// ⛔ ONE MAPPER, USED BY BOTH SCREENS. ``CallRow`` and ``CallDetailView`` construct
/// this and read nothing else off the DTO for display. Adding a comparison against a
/// wire value anywhere else is how the drift above comes back.
///
/// ⚠️ NO `import SwiftUI`, DELIBERATELY. Everything here is a pure function of the
/// wire row, so it stays readable and reviewable without a Mac. ``Tone`` is named
/// only as a value: it is declared in this same module, so it needs no import and
/// nothing here touches `Color`.
///
/// ⚠️ THE CALLER COMES FROM ``CallSummary/number``, not from `callerName`/`from`.
/// The server has ALREADY resolved `number` to a contact name where one exists,
/// falling back to the raw number and then the literal "Unknown". That is the value
/// the call screens have always shown, and `OverviewRepository.toActivity` on the
/// other client reads the other pair, a difference to preserve rather than tidy.
struct CallDisplay {
    let id: String

    /// nil when there was no usable caller ID, so a render site shows a placeholder.
    ///
    /// ⛔ THE ABSENCE TEST IS ``CallerIdentity``, NOT A LOCAL LITERAL. Guarding
    /// "Unknown" alone let `"Inbound SIP Caller"` through as a resolved name, with
    /// the brand-accent avatar of a known contact; the full set and the server lines
    /// that write it live in one place in `DistrictModel`.
    let displayName: String?

    let outbound: Bool

    /// The server's DISPLAY status, already downgraded for a stale call.
    let status: String

    /// ⚠️ DERIVED FROM THE DISPLAY STATUS, WHICH IS THE WHOLE POINT. The server has
    /// already downgraded an in-progress call whose terminal webhook was lost to
    /// `no-answer`, so only a genuinely live call still carries these values.
    /// Recomputing liveness from a raw status would resurrect the bug where a day-old
    /// stuck row wears a Live badge forever.
    let live: Bool

    let transferred: Bool
    let transferFailed: Bool

    /// ⛔ RENDERED FROM ``CallSummary/createdAt`` IN THE DEVICE'S ZONE, NOT FROM
    /// ``CallSummary/time``. The server pre-formats `time` in the user's stored
    /// timezone, falling back to `America/Toronto`, and that setting is writable only
    /// from the web settings page, which this client does not implement. So on iOS
    /// `time` is whatever a browser last set or the Toronto default, printed with no
    /// zone label either way: an operator in Berlin who has never opened the web app
    /// would read every call six hours off, with nothing to say so.
    ///
    /// ⚠️ AGREEING WITH THE BROWSER IS THE WRONG CONSISTENCY. This app renders
    /// Scheduling, Contacts and Inbox timestamps in the DEVICE zone, so keeping the
    /// server's string would make two screens of ONE account disagree about what time
    /// it is. Agreeing with the rest of the phone beats agreeing with a browser the
    /// operator may not be holding.
    let time: String

    /// The human duration, or nil when there is none worth showing.
    ///
    /// ⚠️ nil rather than "0s" for a call that never connected. The server always
    /// formats a duration string, so the decision not to show one has to be made from
    /// ``CallSummary/durationRaw``.
    let durationLabel: String?

    /// What ``CallSummary/aiSummary`` is really carrying, decided once.
    ///
    /// ⛔ THE WIRE FIELD IS NEVER EMPTY AND IS OFTEN A MARKER. Every outbound
    /// softphone call carries the literal `"direct:softphone"` there, permanently,
    /// and it was being printed under a heading that says "AI summary". See
    /// ``CallNarrative`` for the sets and the server lines that write them.
    let aiSummary: CallNarrative.Summary
}

extension CallDisplay {
    /// Map a wire row to its display rules. The only place these comparisons appear.
    ///
    /// ⛔ `createdAt` RATHER THAN `time`, AND ``WireDate/display(_:in:)`` RATHER
    /// THAN A SECOND FORMATTER. That helper already carries the fractional-seconds
    /// trap the server's `2026-08-19T09:41:00.000Z` walks into (a parser not told to
    /// expect it returns nil, silently), and a private copy here would be a second
    /// place for that to be got wrong. See ``time``.
    init(_ call: CallSummary) {
        let seconds = call.durationRaw ?? 0
        self.init(
            id: call.id,
            displayName: CallerIdentity.resolved(call.number),
            outbound: call.direction == CallWire.directionOutbound,
            status: call.status,
            live: call.status == CallWire.statusInProgress || call.status == CallWire.statusRinging,
            transferred: call.transferStatus == CallWire.transferSuccess,
            transferFailed: call.transferStatus == CallWire.transferFailure,
            time: WireDate.display(call.createdAt),
            durationLabel: seconds > 0 ? call.duration : nil,
            aiSummary: CallNarrative.summary(call.aiSummary)
        )
    }
}

// MARK: - Copy

extension CallDisplay {
    /// ⚠️ The placeholder is copy, not a wire value. See ``displayName``.
    var callerLabel: String {
        displayName ?? "No caller ID"
    }

    var directionLabel: String {
        outbound ? "Outbound" : "Inbound"
    }

    /// The summary to print, or nil when there is none to print.
    ///
    /// ⚠️ nil FEEDS THE CARD'S OWN BLANK GUARD rather than a second guard beside it.
    /// `CallDetailView.card(_:_:)` already declines to render a card for a value that
    /// is absent or blank, which is how Sentiment and Outcome disappear; that branch
    /// was simply unreachable for this field, because the server never sends an empty
    /// one. Handing it an Optional makes the guard that already exists do the work.
    var aiSummaryText: String? {
        guard case let .text(summary) = aiSummary else { return nil }
        return summary
    }

    /// What to say INSTEAD of the card, or nil when the card is showing.
    ///
    /// ⛔ THE TWO SENTENCES ARE DIFFERENT AND MUST STAY DIFFERENT. "Nothing was
    /// written" and "we tried to write it and failed" are not the same fact, and
    /// collapsing them would report a failure as an absence. Neither offers a retry:
    /// nothing on this screen can re-run the summariser.
    var aiSummaryNote: String? {
        switch aiSummary {
        case .text: nil
        case .absent: "No AI summary for this call."
        case .failed: "This call could not be summarised."
        }
    }

    /// ⚠️ "Live" REPLACES the raw status rather than sitting beside it, so the log and
    /// the detail screen say the same word about the same call.
    var statusLabel: String {
        live ? "Live" : status
    }

    /// ⚠️ A ONE-CHARACTER GLYPH, NOT A WORD, AND THE SAME PAIR THE INBOX USES.
    /// `ConversationDisplay.subtitle` renders `↑`/`↓` ahead of its message preview for
    /// the same reason: a spelled-out direction eats the line it prefixes. Here it was
    /// eating the call's TIME and DURATION, which is worse, because "Outbound · " is
    /// two characters longer than "Inbound · " and an ordinary outbound row was
    /// truncating its duration with no badge involved at all.
    ///
    /// ⛔ THE TWO LISTS MUST AGREE AND NOTHING ENFORCES IT. These literals are a
    /// deliberate duplicate of the pair in `ConversationDisplay`; a shared constant
    /// would have to live in a third place that neither feature owns. If one moves,
    /// move both.
    ///
    /// ⚠️ AND IT IS NEVER SPOKEN. VoiceOver would read an arrow as "up arrow" or skip
    /// it, so ``CallRow`` overrides the row's accessibility label with
    /// ``directionLabel``. A glyph that only works visually needs the word supplied
    /// somewhere, and that is the somewhere.
    var directionGlyph: String {
        outbound ? "↑" : "↓"
    }

    /// The transfer badge's text, or nil when this call was never transferred.
    ///
    /// ⚠️ THE COPY LIVES HERE BECAUSE TWO THINGS READ IT: the badge and the row's
    /// spoken label. A literal in the view would have to be written twice, and the
    /// pair would drift the way this file's own ⛔ describes.
    var transferLabel: String? {
        if transferred {
            return "Transferred"
        }
        if transferFailed {
            return "Transfer failed"
        }
        return nil
    }

    /// ⚠️ Danger for a failure, info for a success. Only read when
    /// ``transferLabel`` is non-nil.
    var transferTone: Tone {
        transferFailed ? .danger : .info
    }

    /// `time`, plus the duration when there is one worth showing.
    var timeAndDuration: String {
        var parts = [time]
        if let durationLabel {
            parts.append(durationLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// `Direction · time · duration`. The full second line, for a surface with room
    /// for it: the detail screen.
    var subtitle: String {
        "\(directionLabel) · \(timeAndDuration)"
    }

    /// The call log's second line: `↓ time · duration`.
    ///
    /// ⛔ THE GLYPH REPLACES THE WORD ON EVERY ROW, WITH NO SPECIAL CASE. Dropping the
    /// word only on rows carrying a transfer badge measures the wrong thing:
    /// "Outbound · " is two characters longer than "Inbound · ", so an ORDINARY
    /// outbound row with a single pill truncates its duration too
    /// ("Outbound · Aug 1, 09:23 AM · 1m 4…"), with no badge involved. A conditional
    /// that fires on the wrong condition is worse than no conditional, because it
    /// makes the remaining cases look deliberate. The glyph costs two columns on every
    /// row and needs no special case.
    ///
    /// ⚠️ ``subtitle`` KEEPS THE WORD, for the detail screen, which has a full line to
    /// spend and one call to describe rather than a column of them to scan.
    var rowSubtitle: String {
        "\(directionGlyph) \(timeAndDuration)"
    }
}

// MARK: - Tones

extension CallDisplay {
    /// ⚠️ THE ACCENT FOR A LIVE CALL, THE SEMANTIC MAPPING OTHERWISE. In progress is
    /// not a verdict, so it must not wear success or danger; see the ⚠️ on
    /// ``Tone/forCallStatus(_:)``.
    var statusTone: Tone {
        live ? .district : Tone.forCallStatus(status)
    }

    /// ⚠️ An unidentified caller gets the neutral tone, so an anonymous row does not
    /// wear the brand accent as if it were a known contact.
    var avatarTone: Tone {
        displayName == nil ? .neutral : .district
    }
}

/// The wire values these rules compare against.
///
/// ⚠️ DEFINED ONCE, HERE. They are wire values rather than display copy, so they are
/// not localizable and must never be duplicated: separate copies in the log and the
/// detail screen are exactly what let the transfer-failed badge go missing from the
/// log on the other client.
///
/// ⛔ NO CALLER SENTINEL BELONGS IN THIS LIST. Holding part of the sentinel set in a
/// file the other readers cannot see is precisely what lets `"Inbound SIP Caller"`
/// render as a contact's name here, on the overview, and in the dialler. The whole
/// set lives in ``CallerIdentity`` with the server lines that write it.
private enum CallWire {
    static let directionOutbound = "outbound"
    static let statusInProgress = "in-progress"
    static let statusRinging = "ringing"
    static let transferSuccess = "success"
    static let transferFailure = "failed"
}
