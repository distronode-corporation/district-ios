import Foundation

/// `phoneIntel`: what the server can say about one phone number. Carried on
/// every ``CallSummary`` (for the OTHER party: the caller on an inbound call,
/// the dialled number on an outbound one) and beside the contact in
/// ``ContactDetailResponse``.
///
/// ⛔ EVERY NIL MEANS "NOBODY KNOWS", NEVER "CHECKED AND EMPTY", and the server
/// sends the nulls rather than omitting the keys:
///   - ``region`` is nil outside Canada and the United States (the server's
///     area-code table covers only those), and when a stored carrier lookup
///     contradicts the number's country.
///   - ``lineType`` and ``carrier`` are nil unless a PAID carrier lookup is
///     stored on the contact. Number metadata cannot tell a North American
///     mobile from a landline, so the server never guesses them, and neither
///     may the app.
///
/// ⚠️ The whole block is nil on an outbound call with no recorded callee and
/// for a stored "number" that does not parse (see ``CallerIdentity``).
public struct PhoneIntel: Codable, Sendable, Equatable {
    /// ISO 3166-1 alpha-2, e.g. "CA". A stored carrier answer wins over the
    /// number's metadata.
    public let country: String?
    /// English display name of ``country``, e.g. "Canada".
    public let countryName: String?
    /// e.g. "(416) 555-0134".
    public let nationalFormat: String?
    /// e.g. "+1 416 555 0134". Prefer this outside +1, where a national format
    /// hides the country.
    public let internationalFormat: String?
    public let region: PhoneRegion?
    /// "mobile", "landline", "voip", …, from a stored carrier lookup only.
    public let lineType: String?
    /// The carrier holding the number, from a stored carrier lookup only.
    public let carrier: String?
}

/// A Canadian province or US state, from the number's area code.
public struct PhoneRegion: Codable, Sendable, Equatable {
    /// ISO 3166-2 subdivision suffix, e.g. "ON".
    public let code: String
    /// e.g. "Ontario".
    public let name: String
    /// Present only where the area-code table names one.
    public let city: String?
}
