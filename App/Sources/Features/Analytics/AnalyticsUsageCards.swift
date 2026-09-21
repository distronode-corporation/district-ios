import DistrictModel
import SwiftUI

/// This month's metered usage.
///
/// ⛔ A nil MONTH RENDERS A SENTENCE, NEVER ZEROS. `usage: null` means the month has
/// no metering rows at all, which is not the claim "you sent nothing". A zero beside
/// a billing label reads as a measurement, and it is the kind of wrong number that
/// becomes a support ticket.
///
/// ⚠️ ONLY THE METRICS THAT ARE PRESENT ARE LISTED. An absent metric has no key in
/// the response, which is a different fact from a metric measured at zero — see
/// ``UsageMonth`` — so an absent row is omitted here while a zero row is shown.
/// (The history card takes the opposite tack, because there the rows are fixed and
/// the absence has to be labelled. Both keep absent and zero distinguishable.)
struct AnalyticsUsageCard: View {
    let usage: UsageMonth?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AnalyticsCard(title: "Usage this month") {
            if let usage {
                Text("Month \(usage.month)")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                ForEach(Self.rows(usage), id: \.label) { row in
                    AnalyticsAmountRow(label: row.label, amount: row.amount)
                }
            } else {
                AnalyticsNote(text: "No usage has been recorded for this month yet.")
            }
        }
    }

    /// The metrics this month actually carries, in a fixed display order.
    ///
    /// ⚠️ A PLAIN FUNCTION OVER PLAIN VALUES, deliberately: it is the one piece of
    /// this card that has a right and a wrong answer, and keeping it out of the view
    /// body is what would let it be tested the day this tier gets a test lane.
    ///
    /// ⚠️ "Video minutes (tracked)" SAYS TRACKED BECAUSE TAVUS MINUTES ARE METERED
    /// AND DELIBERATELY EXCLUDED FROM OVERAGE. Listing them unqualified beside
    /// billable metrics would imply a charge that is not made.
    static func rows(_ usage: UsageMonth) -> [AnalyticsUsageRow] {
        let candidates: [(String, Double?)] = [
            ("SMS sent", usage.smsOutbound),
            ("SMS received", usage.smsInbound),
            ("MMS sent", usage.mmsOutbound),
            ("WhatsApp sent", usage.whatsappOutbound),
            ("WhatsApp received", usage.whatsappInbound),
            ("Outbound call minutes", usage.callMinutesOutbound),
            ("Inbound call minutes", usage.callMinutesInbound),
            ("Phone numbers", usage.numberCount),
            ("Video minutes (tracked)", usage.videoMinutes),
        ]
        return candidates.compactMap { label, amount in
            amount.map { AnalyticsUsageRow(label: label, amount: $0) }
        }
    }
}

/// One present metric on the current-month card.
///
/// ⚠️ A NAMED TYPE RATHER THAN A TUPLE so `ForEach` can key on the label without the
/// row's identity being a positional accident.
struct AnalyticsUsageRow {
    let label: String
    let amount: Double
}

/// Metered usage over recent months, the web console's three-month trend.
///
/// ⛔ AN EMPTY LIST IS "NOTHING HAS EVER BEEN METERED", NOT A FAULT AND NOT A ROW OF
/// ZEROS. The server appends only months that had rows, so a workspace nobody has
/// metered answers `[]` on a 200.
///
/// ⛔ EVERY FIGURE HERE IS OPTIONAL AND AN ABSENT ONE IS LABELLED, NEVER SHOWN AS A
/// ZERO. These sit under billing-shaped labels, which is exactly where a fabricated
/// zero gets believed. ``AnalyticsFormat/sumMetered(_:)`` carries the distinction
/// through the addition and ``AnalyticsFormat/normalized(_:)`` keeps it out of the
/// geometry.
///
/// ⛔ DRAWN WITH PLAIN RECTANGLES RATHER THAN A CHART, unlike the analytics cards
/// above. The bars are one dimension scaled against each other and the common case
/// is a zero-length one — a month whose only metered row was a phone-number count —
/// so a chart here would add an axis, a legend and a plot frame to a shape that is
/// literally a filled fraction of a track.
struct AnalyticsHistoryCard: View {
    let months: [UsageMonth]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ COMPUTED ONCE FOR THE WHOLE CARD, not per row: the bars are scaled against
    /// EACH OTHER, so the maximum is a property of the list and a per-row derivation
    /// would draw every month full width.
    private var minutes: [Double?] {
        months.map { AnalyticsFormat.sumMetered($0.callMinutesOutbound, $0.callMinutesInbound) }
    }

    var body: some View {
        AnalyticsCard(title: "Recent months") {
            if months.isEmpty {
                AnalyticsNote(text: "No usage has been recorded in any recent month yet.")
            } else {
                populated
            }
        }
    }

    /// ⚠️ IN THE ORDER RECEIVED, NEWEST FIRST, AND NOT RE-SORTED. The server
    /// documents the ordering; re-deriving it from the `YYYY-MM` string would work by
    /// accident today and would be the thing depended on tomorrow.
    private var populated: some View {
        let widths = AnalyticsFormat.normalized(minutes)
        return VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            // ⛔ INDEXED RATHER THAN KEYED ON THE ROW. Three parallel arrays have to
            // stay aligned (the month, its summed minutes, its width against the
            // others), and `enumerated()` cannot supply the id because Swift has no
            // key path into a tuple element.
            ForEach(months.indices, id: \.self) { index in
                row(months[index], minutes: minutes[index], width: widths[index])
            }
            Text(
                "Bars compare metered call minutes across these months. "
                    + "A channel with nothing metered is labelled rather than shown as zero."
            )
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
        }
    }

    /// One month: its label, its metered call minutes, a bar, and its message count.
    ///
    /// ⚠️ `width` IS PASSED IN RATHER THAN DERIVED. The scale is the whole list's
    /// maximum, which this row cannot see.
    private func row(_ month: UsageMonth, minutes: Double?, width: Double) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(AnalyticsFormat.monthLabel(month.month))
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            AnalyticsAmountRow(label: "Metered call minutes", amount: minutes)
            bar(width: width)
            // ⚠️ EVERY MESSAGING CHANNEL, summed the way the minutes are: a month with
            // SMS metered and WhatsApp absent totals the SMS, and a month with none of
            // them metered totals to nil rather than to zero.
            AnalyticsAmountRow(label: "Messages", amount: messages(month))
        }
    }

    /// ⚠️ A `GeometryReader` INSIDE A FIXED-HEIGHT FRAME, which is the one shape that
    /// makes a proportional width safe in a `VStack`. A bare `GeometryReader` takes
    /// all the vertical space offered and would push every following row off screen.
    private func bar(width: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DistrictRadius.badge)
                    .fill(colors.muted)
                RoundedRectangle(cornerRadius: DistrictRadius.badge)
                    .fill(colors.district)
                    .frame(width: proxy.size.width * CGFloat(width))
            }
        }
        .frame(height: 10)
    }

    private func messages(_ month: UsageMonth) -> Double? {
        AnalyticsFormat.sumMetered(
            month.smsOutbound,
            month.smsInbound,
            month.mmsOutbound,
            month.whatsappOutbound,
            month.whatsappInbound
        )
    }
}
