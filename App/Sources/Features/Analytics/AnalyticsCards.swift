import Charts
import DistrictModel
import SwiftUI

/// The five KPI tiles.
///
/// ⛔ NO "ACTIVE AGENTS" TILE, AND THAT IS THE ONE OMISSION WORTH STATING. The server
/// hardcodes ``AnalyticsMetrics/activeAgents`` to zero — there is no live-agent
/// presence signal in this product — so a tile would read "0" forever and look like
/// a measurement. Absent is honest.
///
/// ⚠️ A HAND-BUILT 2 + 2 + 1, NOT A `LazyVGrid`. Five items, never more and never
/// fewer, and a lazy grid inside the enclosing scroll view would need an explicit
/// height, which hardcodes the very measurement the grid was supposed to compute.
struct AnalyticsMetricTiles: View {
    let metrics: AnalyticsMetrics

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            HStack(spacing: DistrictSpacing.row) {
                AnalyticsMetricTile(
                    label: "Total Calls",
                    value: "\(metrics.totalCalls)",
                    caption: "In this window"
                )
                AnalyticsMetricTile(
                    label: "Avg Call Duration",
                    // ⛔ NOT "Across completed sessions": THAT IS THE NARROW NAME ON THE
                    // BROAD NUMBER. The server divides by
                    // `lower(status) IN ('completed','answered','machine','human')`,
                    // so a call answered by an ANSWERING MACHINE is in this average and
                    // "completed sessions" would not tell you that. What the four
                    // statuses share is that something picked up.
                    //
                    // ⚠️ AND THE WINDOW IS PART OF THE ANSWER. This query is scoped to
                    // the selected range (`WHERE "createdAt" >= rangeStart`), unlike
                    // the Overview tile of the same name, which is all-time and takes
                    // ONLY an exact `completed`.
                    // The two tiles measure different things and are meant to.
                    value: AnalyticsFormat.duration(seconds: metrics.avgDuration),
                    caption: "Answered calls, this window"
                )
            }
            HStack(spacing: DistrictSpacing.row) {
                AnalyticsMetricTile(
                    label: "Conversion Rate",
                    // ⚠️ ALREADY A PERCENTAGE, ALREADY ROUNDED. Multiplying by 100 is
                    // the obvious mistake and produces a plausible four-digit number
                    // rather than an obviously broken one.
                    value: "\(metrics.conversionRate)%",
                    caption: "Of all dials"
                )
                AnalyticsMetricTile(
                    label: "Missed Calls",
                    value: "\(metrics.missedCalls)",
                    caption: "Never connected"
                )
            }
            AnalyticsMetricTile(
                label: "Abandoned",
                value: "\(metrics.abandonedCalls)",
                caption: "Caller hung up"
            )
        }
    }
}

/// Call volume against the immediately preceding window of the same length.
///
/// ⛔ A nil `pct` RENDERS "New", NOT "0%". There is no prior period to compare
/// against, so no percentage exists — and a zero would tell a brand-new customer
/// their call volume was flat during their first week on the platform.
///
/// ⚠️ THE ARROW CARRIES THE SIGN AND THE NUMBER CARRIES THE MAGNITUDE. The server
/// sends a negative percentage for a fall, and "▼ -20%" reads as a double negative.
///
/// ⚠️ ``CallVolumeDelta/direction`` IS INDEPENDENT OF `pct` AND IS NOT INFERRED FROM
/// IT. Zero against zero is `flat` with a nil percentage; a first-ever call is `up`
/// with a nil percentage. The arrow and the number answer different questions.
struct AnalyticsDeltaCard: View {
    let delta: CallVolumeDelta

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AnalyticsCard(title: "Call volume") {
            Text("\(delta.current) now, \(delta.prior) in the previous period")
                .font(DistrictType.metric)
                .foregroundStyle(colors.foreground)
            Text(comparison)
                .font(DistrictType.bodySmall)
                .foregroundStyle(tone)
        }
    }

    private var comparison: String {
        guard let pct = delta.pct else { return "New, no previous period to compare" }
        switch delta.direction {
        case CallVolumeDirection.up: return "▲ \(abs(pct))% vs the previous period"
        case CallVolumeDirection.down: return "▼ \(abs(pct))% vs the previous period"
        default: return "No change vs the previous period"
        }
    }

    /// ⚠️ NEUTRAL WHENEVER THERE IS NO PERCENTAGE, whatever the direction says. A
    /// green "New" would read as growth that was never measured.
    private var tone: Color {
        guard delta.pct != nil else { return colors.mutedForeground }
        switch delta.direction {
        case CallVolumeDirection.up: return colors.success
        case CallVolumeDirection.down: return colors.destructive
        default: return colors.mutedForeground
        }
    }
}

/// The trend series as vertical bars.
///
/// ⛔ THE AXIS LABEL IS RENDERED VERBATIM AND NEVER PARSED. ``EngagementPoint/date``
/// is a display string the SERVER localised to the operator's timezone; it carries
/// no year and shifts with the reader. ``EngagementPoint/isoDate`` is the
/// machine-readable one, and it is used here for nothing but row identity — the
/// ordering is the server's and this client preserves it.
///
/// ⛔ THE X AXIS IS HIDDEN AND REPLACED BY ONE CAPTION, which is what Android does.
/// A 90-day window buckets WEEKLY and a 30-day one daily, so the label count is a
/// property of the window rather than a constant; drawing all thirty on a phone
/// produces an unreadable smear, and thinning them means choosing which dates to
/// drop. First and last say the same thing and cannot go wrong.
///
/// ⚠️ AN ALL-ZERO SERIES IS LABELLED RATHER THAN LEFT BLANK. The series is never
/// empty — the server emits one point per bucket regardless — so a workspace with no
/// calls draws a flat floor, and an unlabelled flat chart reads as a broken renderer
/// rather than as "no calls".
struct AnalyticsTrendCard: View {
    let points: [EngagementPoint]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AnalyticsCard(title: "Call volume trend") {
            if let first = points.first, let last = points.last {
                chart
                Text("\(first.date) to \(last.date)")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            if isQuietWindow {
                AnalyticsNote(text: "No calls in this window.")
            }
        }
    }

    /// ⚠️ THE TEST IS "EVERY BUCKET IS ZERO", NOT "THE SERIES IS EMPTY". The route
    /// seeds one point per bucket and fills from the query, so a workspace with no
    /// calls gets a series of ZEROS rather than an absent one — emptiness is not the
    /// "no data" test here, and a nil check would never fire.
    private var isQuietWindow: Bool {
        points.allSatisfy { $0.calls == 0 }
    }

    /// ⛔ A CHART WITH NO PER-MARK LABELS IS ANNOUNCED AS ONE UNLABELLED IMAGE, and
    /// the numbers in it reach nobody using VoiceOver. Labelling each `BarMark` is
    /// what makes the series navigable bar by bar and what feeds the audio graph.
    ///
    /// ⚠️ `point.date` RATHER THAN `point.isoDate`. The model's own ⛔ says `date` is
    /// the operator-localised display string and `isoDate` is the machine-readable
    /// one; a spoken label is display, so it takes the display field. The x-axis is
    /// hidden visually, which makes the label the ONLY place that bucket is named.
    private var chart: some View {
        Chart {
            ForEach(points, id: \.isoDate) { point in
                BarMark(
                    x: .value("Bucket", point.date),
                    y: .value("Calls", point.calls)
                )
                .foregroundStyle(colors.district)
                .accessibilityLabel(point.date)
                .accessibilityValue(AnalyticsFormat.callCount(point.calls))
            }
        }
        .chartXAxis(.hidden)
        .frame(height: AnalyticsChartHeight.trend)
    }
}

/// The dial to connect to lead funnel, as horizontal bars.
///
/// ⛔ THE SERVER'S ORDER IS PINNED WITH AN EXPLICIT DOMAIN RATHER THAN LEFT TO THE
/// CHART. The stages are ordered widest first and that ordering is the shape of a
/// funnel; a categorical axis that derived its own domain could present them in any
/// order and the picture would still look plausible, which is the worst kind of
/// wrong. See ``FunnelStage``.
///
/// ⚠️ BOTH AXES ARE LEFT VISIBLE, unlike the trend. Three stages produce three
/// labels, and the counts on the value axis are the numbers an operator came for.
struct AnalyticsFunnelCard: View {
    let stages: [FunnelStage]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AnalyticsCard(title: "Conversion funnel") {
            Chart {
                ForEach(stages, id: \.name) { stage in
                    BarMark(
                        x: .value("Calls", stage.count),
                        y: .value("Stage", stage.name)
                    )
                    .foregroundStyle(colors.district)
                    .accessibilityLabel(stage.name)
                    .accessibilityValue(AnalyticsFormat.callCount(stage.count))
                }
            }
            .chartYScale(domain: stages.map(\.name))
            .frame(height: AnalyticsChartHeight.funnel(stages.count))
        }
    }
}

/// Sentiment as a donut plus a legend.
///
/// ⛔ THE COLOURS COME FROM THE SERVER AS OPAQUE HEX STRINGS AND ARE PARSED LENIENTLY
/// HERE, falling back to the brand accent. Parsing them in the DTO would let a
/// malformed shade fail the entire analytics response — every metric, every trend
/// point — over a presentational detail. See ``SentimentSlice/color``.
///
/// ⛔ AN ALL-ZERO BREAKDOWN DRAWS NO CHART AT ALL. All three bands are present even
/// for a workspace with no calls, so this is reached on every brand-new account, and
/// a donut of three zero-angle sectors is either empty or (if a chart library helpfully
/// splits it evenly) a confident three-way sentiment analysis of nothing.
struct AnalyticsSentimentCard: View {
    let slices: [SentimentSlice]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Anchored to `.callout`, the style `bodySmall` uses for the labels either side.
    @ScaledMetric(relativeTo: .callout) private var swatch: CGFloat = 8

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var hasAnalysis: Bool {
        slices.contains { $0.value > 0 }
    }

    var body: some View {
        AnalyticsCard(title: "Sentiment") {
            if hasAnalysis {
                chart
            }
            ForEach(slices, id: \.name) { slice in
                legendRow(slice)
            }
            if !hasAnalysis {
                AnalyticsNote(text: "No calls to analyse yet.")
            }
        }
    }

    /// ⛔ HIDDEN FROM VOICEOVER RATHER THAN LABELLED, WHICH IS THE OPPOSITE CALL FROM
    /// THE OTHER TWO CHARTS AND IS RIGHT HERE. Every slice already has a legend row
    /// directly underneath carrying the same name and the same number, and that row
    /// is a combined element. Labelling the sectors as well would make a person swipe
    /// through the whole breakdown twice to learn it once. The trend and the funnel
    /// have no legend, which is why they are labelled instead.
    private var chart: some View {
        Chart {
            ForEach(slices, id: \.name) { slice in
                SectorMark(
                    angle: .value("Calls", slice.value),
                    innerRadius: .ratio(0.6),
                    angularInset: 1
                )
                .foregroundStyle(color(for: slice))
            }
        }
        .frame(height: AnalyticsChartHeight.sentiment)
        .accessibilityHidden(true)
    }

    private func legendRow(_ slice: SentimentSlice) -> some View {
        // ⚠️ THE VALUE GOES UNDER THE NAME AT AN ACCESSIBILITY SIZE. Side by side, a
        // long sentiment name and its count compete for one line and the name wins by
        // truncating, which loses the label the number belongs to.
        let row = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.tight))
        return row {
            // ⚠️ THE SWATCH GROWS WITH THE LABEL BESIDE IT, the same fix
            // `DistrictStatusDot` took. It is the legend's only link between a name
            // and a slice of the donut, and a fixed 8pt dot against type that has
            // scaled to five times its size reads as a rendering fault.
            Circle()
                .fill(color(for: slice))
                .frame(width: swatch, height: swatch)
            Text(slice.name)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(slice.value)")
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
        .accessibilityElement(children: .combine)
    }

    /// ⚠️ THE THEME TOKEN IS THE FALLBACK, NOT A FAILURE. A colour this client cannot
    /// read costs a shade rather than the card.
    private func color(for slice: SentimentSlice) -> Color {
        AnalyticsFormat.hexColor(slice.color) ?? colors.district
    }
}

/// The plot heights, in one place so the loading skeleton and the real chart agree
/// and the layout does not jump on arrival.
enum AnalyticsChartHeight {
    static let trend: CGFloat = 140
    static let sentiment: CGFloat = 160

    /// ⚠️ DERIVED FROM THE ROW COUNT rather than fixed. The funnel is three stages
    /// today and the server owns that number; a constant height would squash a
    /// fourth stage into the same box without anything failing.
    static func funnel(_ stages: Int) -> CGFloat {
        CGFloat(max(stages, 1)) * 36 + 24
    }
}
