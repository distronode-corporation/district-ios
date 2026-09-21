import Foundation

// ⛔ ONE ROUTE, TWO RESPONSE TYPES ON THE SAME KEY, WHICH IS WHY THERE ARE TWO
// ENVELOPES IN THIS FILE. `GET /api/district/workspace/usage` answers
// `{success, usage: UsageMonth|null}` for the current month and
// `{success, usage: UsageMonth[]}` when asked for `history=true`. No single
// Codable field can be both, and the type that tried — an opaque carrier on the
// key, branched on at the call site — would only move the decision somewhere with
// no compiler help. The Kotlin client splits them the same way, for the same
// reason; see `UsageResponse.kt`.

/// `GET /api/district/workspace/usage?workspaceId=` — this month's metered usage.
///
/// ⛔ ``usage`` IS NULL WHEN THE MONTH HAS NO METERING ROWS AT ALL, AND NULL IS NOT
/// ZERO. `getUsage` returns `null` the moment its `groupBy` comes back empty, so a
/// screen that rendered it as a column of zeros would state, with the authority of
/// a billing figure, that a workspace sent no messages and placed no calls — a
/// claim nothing ever measured. "No usage has been recorded yet" is checkable; a
/// fabricated zero beside a billing label is what becomes a support ticket.
///
/// ⚠️ `district-usage-empty.json` IS THE FIXTURE THAT PINS IT and it carries an
/// explicit `null` at `$.usage`, so it reaches the strict gate through one
/// `allowedExplicitNulls` entry rather than by loosening the no-nulls invariant.
public struct UsageResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ nil means "nothing metered this month", never "zero of everything".
    public let usage: UsageMonth?
}

/// The same route with `history=true`: several months, NEWEST FIRST.
///
/// ⚠️ AN EMPTY ARRAY IS "NOTHING HAS EVER BEEN METERED", NOT A FAILURE AND NOT A
/// SHORT PAGE. `getUsageHistory` walks back one month at a time and appends only
/// the months that had rows, so a workspace nobody has metered answers `[]` on a
/// 200 — the list equivalent of the null above.
///
/// ⚠️ SHORTER THAN ASKED FOR IS ORDINARY for the same reason, and the server also
/// clamps `months` to 1...24 and falls back to 6 for a non-numeric value. Nothing
/// here may assume it received the span it requested.
public struct UsageHistoryResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ NEWEST FIRST, AS SENT, AND THIS CLIENT DOES NOT RE-SORT. ``UsageMonth/month``
    /// is a `YYYY-MM` string that happens to sort correctly, which is exactly the
    /// kind of accident a re-sort would come to depend on.
    public let usage: [UsageMonth]
}

/// One month's metered totals. The Kotlin client calls this `UsageData`.
///
/// ⛔ EVERY METRIC IS OPTIONAL, AND ABSENT IS NOT ZERO. `getUsage` seeds the object
/// with `month` alone and then writes one key per metric that had rows, so a metric
/// nobody metered has NO KEY while a metric measured at zero is present as `0`.
/// Both are real facts and they are different ones: "WhatsApp is not metered for
/// this workspace" against "WhatsApp was metered and it was zero". Defaulting these
/// to zero collapses the two and makes an unmetered channel look like an idle one,
/// under a billing-shaped label, which is the place a reader trusts a number most.
///
/// ⛔ AND THEY ARE `Double`, NOT `Int`. `ProviderUsage.amount` is summed as a float
/// server-side, so call minutes genuinely arrive fractional (`1204.25` in the
/// committed fixture). An `Int` here fails to decode that outright — and the
/// obvious "fix", rounding, would round a bill.
///
/// ⚠️ ``month`` IS THE ONLY REQUIRED KEY, and it is required rather than defaulted
/// because it is the row's identity: a month with no key to name it cannot be
/// labelled, charted or compared, so a body missing it is malformed rather than
/// sparse.
public struct UsageMonth: Codable, Sendable {
    /// `YYYY-MM`, built from UTC month boundaries. ⛔ A CALENDAR KEY, NOT AN INSTANT
    /// — parsing it into a date and formatting it back is how a month silently
    /// shifts by one for a reader west of UTC.
    public let month: String
    /// The carrier or vendor the rows were metered against (`twilio`, `tavus`).
    ///
    /// ⚠️ ABSENT ON MOST ROWS. `getUsage` never writes this key; it is declared on
    /// the server's own `UsageData` interface and appears on the fixture's current
    /// month, so it is modelled and optional rather than assumed either way.
    public let provider: String?
    public let smsOutbound: Double?
    public let smsInbound: Double?
    public let mmsOutbound: Double?
    public let whatsappOutbound: Double?
    /// ⚠️ MODELLED THOUGH NO FIXTURE CARRIES IT. `UsageMetric` declares it
    /// server-side and the Kotlin DTO models it; leaving it out would silently drop
    /// a metered channel the day one is recorded, and an absent Optional costs the
    /// strict gate nothing because Swift encodes nil as no key at all.
    public let whatsappInbound: Double?
    public let callMinutesOutbound: Double?
    public let callMinutesInbound: Double?
    public let numberCount: Double?
    /// Tavus video-avatar minutes.
    ///
    /// ⛔ TRACKING ONLY, BY OWNER DECISION. These are deliberately excluded from the
    /// overage calculation in `api/billing/sync-usage`, so presenting them beside
    /// billable metrics without saying so implies a charge that is not made.
    public let videoMinutes: Double?
    /// ISO-8601, or absent. ⚠️ Carried as a `String`: nothing does date arithmetic
    /// on it, and a `Date` would need a decoding strategy this client does not set.
    public let lastUpdated: String?
}
