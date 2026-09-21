import Foundation

/// `GET /api/district/analytics?workspaceId=&range=` — telephony analytics for
/// one workspace over one window.
///
/// ⛔ EVERY NUMBER HERE IS DERIVED SERVER-SIDE, IN SQL, OVER THE FULL WINDOW,
/// AND THE CLIENT MUST NOT RECOMPUTE ANY OF IT. ``AnalyticsMetrics/avgDuration``
/// divides by COMPLETED calls while ``AnalyticsMetrics/totalCalls`` counts all
/// of them, ``AnalyticsMetrics/conversionRate`` is already a rounded percentage,
/// and the neutral sentiment band is a REMAINDER that is never queried. A client
/// that re-derived any of those from the other fields would disagree with the
/// web console about the same data — two surfaces quoting different numbers to
/// the same operator, with nothing on either screen to say which is wrong.
///
/// ⚠️ EVERY KEY IS ALWAYS PRESENT ON A 200. The route builds one literal object
/// with no conditional spreads, so nothing here is Optional except the one field
/// the server explicitly nulls (see ``CallVolumeDelta/pct``). Failures arrive as
/// a non-2xx `ApiErrorEnvelope`, which is why — unlike the Kotlin DTO — this
/// type carries no `error` field.
public struct AnalyticsResponse: Codable, Sendable {
    public let success: Bool
    public let metrics: AnalyticsMetrics
    public let callVolumeDelta: CallVolumeDelta
    /// The trend series, OLDEST FIRST.
    ///
    /// ⚠️ NEVER EMPTY FOR A WELL-FORMED RESPONSE, so emptiness is not the "no
    /// data" test. The route seeds one point per bucket and fills from the
    /// query, so a workspace with no calls at all gets a series of ZEROS rather
    /// than an absent one. That degenerate series is what the chart has to
    /// survive.
    public let engagementTrends: [EngagementPoint]
    public let funnelData: [FunnelStage]
    public let sentimentDistribution: [SentimentSlice]
}

/// The headline tiles.
///
/// ⚠️ ``avgDuration`` IS SECONDS ACROSS *COMPLETED* SESSIONS, not across every
/// call. A failed or abandoned call with a non-zero duration is deliberately
/// excluded from both the numerator and the denominator, so
/// `avgDuration * totalCalls` is not talk time and must never be presented as
/// such.
///
/// ⚠️ ``conversionRate`` IS ALREADY A PERCENTAGE (0...100), already rounded.
/// Multiplying by 100 is the obvious mistake and produces a plausible-looking
/// four-digit number rather than an obviously broken one.
///
/// ⛔ ``activeAgents`` IS HARDCODED TO ZERO SERVER-SIDE. There is no live-agent
/// presence signal in this product, so it is a placeholder rather than a
/// measurement. Do not build a tile on it: it would read "0 agents online"
/// forever, which is worse than an absent tile because it looks like a fact.
public struct AnalyticsMetrics: Codable, Sendable {
    public let totalCalls: Int
    /// ⚠️ Seconds, completed calls only. See the type note.
    public let avgDuration: Int
    /// ⚠️ Already a percentage. See the type note.
    public let conversionRate: Int
    public let abandonedCalls: Int
    public let missedCalls: Int
    /// ⛔ Always 0. See the type note.
    public let activeAgents: Int
}

/// Call volume against the immediately preceding window of the same length.
///
/// ⛔ ``pct`` IS THE ONE EXPLICIT NULL ON THIS ROUTE AND NULL MEANS "New", NOT
/// ZERO. A workspace with no prior period has no baseline, so there is no
/// percentage to state — the route computes `prior > 0 ? … : null` rather than
/// inventing a divide-by-zero or a fake 0%. Rendering null as "0%" tells a
/// brand-new customer their call volume is flat when in fact this is their first
/// week.
///
/// ⚠️ `district-analytics-new-workspace.json` IS THE FIXTURE THAT PINS IT, AND
/// IT IS NOT WIRED INTO THE STRICT GATE FOR EXACTLY THAT REASON: it carries an
/// explicit `null` at `$.callVolumeDelta.pct`, which the no-nulls invariant
/// rejects. Adding it needs an `allowedExplicitNulls` entry, which is a decision
/// to take alongside the screen that renders "New" rather than ahead of it.
///
/// ⚠️ ``direction`` IS INDEPENDENT OF ``pct`` AND MUST NOT BE INFERRED FROM IT.
/// Zero against zero is `flat` with a null percentage; a first-ever call is `up`
/// with a null percentage. The arrow and the number answer different questions.
public struct CallVolumeDelta: Codable, Sendable {
    public let current: Int
    public let prior: Int
    /// ⛔ nil means "New", never 0. See the type note.
    public let pct: Int?
    /// `up`, `down` or `flat`. A plain String: the server has no enum here, and
    /// this client adds none, for the reason `WorkspaceRole` documents.
    public let direction: String

    /// True when there is no prior baseline, so the delta reads "New" rather
    /// than a percentage.
    public var isNew: Bool {
        pct == nil
    }
}

/// The `direction` vocabulary the server emits.
public enum CallVolumeDirection {
    public static let up = "up"
    public static let down = "down"
    public static let flat = "flat"
}

/// One bucket of the trend series.
///
/// ⛔ ``date`` AND ``isoDate`` ARE NOT INTERCHANGEABLE, AND ONLY ONE OF THEM IS
/// MACHINE-READABLE. ``date`` is a DISPLAY string the server localised to the
/// OPERATOR'S timezone ("Aug 15") — it carries no year and shifts with the
/// reader, so parsing it is not merely fragile but wrong. Render it verbatim.
/// ``isoDate`` is the same bucket's UTC calendar date ("2026-08-15") and is the
/// only field that may be sorted, diffed or re-bucketed.
///
/// ⚠️ THE BUCKET IS NOT ALWAYS A DAY. 7d and 30d windows bucket daily; a 90d
/// window buckets WEEKLY, and for a weekly bucket both fields name its END. So
/// the series length is a property of the window rather than a constant, and
/// consecutive ``isoDate`` values are not necessarily one day apart.
///
/// ⚠️ ``calls`` counts ALL calls in the bucket (the bars sum to
/// `metrics.totalCalls`) while ``avgDuration`` averages COMPLETED ones only, so
/// a bucket can legitimately have traffic and a zero average.
public struct EngagementPoint: Codable, Sendable {
    /// ⛔ Display only, operator-localised. Never parsed.
    public let date: String
    /// ⛔ The machine-readable one. UTC calendar date.
    public let isoDate: String
    public let calls: Int
    public let avgDuration: Int
}

/// One stage of the dial → connect → lead funnel. Ordered widest first by the
/// server, and this client preserves that order rather than sorting.
public struct FunnelStage: Codable, Sendable {
    public let name: String
    public let count: Int
}

/// One sentiment band.
///
/// ⛔ ``color`` IS A SERVER-CHOSEN HEX STRING CARRIED AS AN OPAQUE `String`, NOT
/// PARSED HERE. Nothing server-side constrains it to `#rrggbb`, and a DTO that
/// decoded it into a colour type would fail the WHOLE response — every metric,
/// every trend point — over a presentational detail. Parse it leniently at
/// render time with a theme-token fallback, so a malformed colour costs a shade
/// rather than the screen.
///
/// ⚠️ ALL THREE SLICES ARE PRESENT EVEN WHEN EVERY VALUE IS ZERO, so a
/// proportional bar has to handle a total of zero rather than an absent list.
public struct SentimentSlice: Codable, Sendable {
    public let name: String
    public let value: Int
    /// ⛔ Opaque. See the type note.
    public let color: String
}

// ⚠️ THE WINDOW ITSELF (`AnalyticsRange`) LIVES IN `DistrictNetwork`, NOT HERE,
// AND IT MUST NOT BE RE-DECLARED IN THIS MODULE. It is a REQUEST concern — the
// `range` query parameter — and the reason it is a type rather than a String is
// that the route falls back to 7d with a 200 for anything it does not recognise,
// which is a request-side guard. A second copy here would be ambiguous to any
// file importing both modules, and the two would drift.
