import Foundation

// Release and configure are modelled, along with the whole regulatory-registration
// surface and the carrier-account surfaces, in `NumberProvisioningResponses.swift` and
// `CarrierAccountResponses.swift`. This file holds the two READS.
//
// ⛔ THE PURCHASE IS THE ONE THING DELIBERATELY NOT MODELLED.
// `workspace/numbers/purchase` charges a setup fee AND opens a recurring monthly charge
// for a service consumed inside the app, which is App Store Review Guideline 3.1.1: an
// in-app purchase or nothing. No request DTO and no response DTO for it belongs in this
// file or any other, and with no ``EndpointID`` case and no path constant the route is
// unconstructible from outside `DistrictNetwork` rather than merely unmodelled.
// ⛔ 3.1.1 covers STEERING too, so nothing here carries a URL to the web marketplace.
// `EndpointSurfaceTests` pins both halves.
//
// ⚠️ THE SHAPE TO DISTRUST IS THE ONE THIS PARAGRAPH JUST CORRECTED: a note that was
// true when written and that nothing updated when the decision behind it changed.

/// One phone number the carrier has for sale.
///
/// ⛔ EVERY PRICE FIELD IS OPTIONAL BECAUSE THE KEY IS GENUINELY ABSENT, NOT
/// NULL. The Twilio implementation wraps its pricing lookup in a bare catch and
/// leaves `monthlyPrice` undefined when the account has no Pricing API access —
/// and `JSON.stringify` DROPS an undefined value rather than writing null, so
/// the field vanishes from the wire entirely. Typing it as required would throw
/// on the first search from such an account, in production, with a decode
/// failure that reads like contract drift rather than like a missing price.
/// `district-numbers-search.json` carries one row with pricing and one without,
/// precisely so this stays covered.
///
/// ⚠️ ``monthlyPrice`` IS A NUMBER AND CARRIES NO CURRENCY OF ITS OWN —
/// ``currency`` is a separate, equally optional field. A price with no currency
/// beside it must not be rendered with a symbol the server never sent.
public struct AvailableNumber: Codable, Sendable {
    /// E.164. The row's identity.
    public let phoneNumber: String
    /// ⚠️ Absent on a toll-free result, which has no locality to report.
    public let locality: String?
    public let region: String?
    /// `sms`, `voice`, `mms`. ⚠️ Present and possibly EMPTY rather than absent.
    public let capabilities: [String]
    /// "local" or "tollFree" in practice; free text on the wire.
    public let type: String
    /// ⛔ Absent, not null, when the pricing lookup failed. See the type doc.
    public let monthlyPrice: Double?
    /// ⛔ Absent, not null. See the type doc.
    public let setupPrice: Double?
    /// ⛔ Absent, not null. See the type doc.
    public let currency: String?
}

/// `GET /api/district/workspace/numbers/search` — the carrier's inventory.
///
/// ⚠️ ``provider`` IS THE SERVER'S CHOICE, ECHOED BACK. A caller may name one,
/// but the resolved credentials decide which carrier actually answered, so this
/// reports what happened rather than repeating the request. It is required
/// rather than Optional because it is the answer's own discriminator: the route
/// writes `credentials.provider` on every 200, and a body without it is drift
/// rather than a search that named no carrier.
///
/// ⛔ A WORKSPACE WITH NO CARRIER CONNECTED ANSWERS **400**, NOT AN EMPTY LIST —
/// `{success: false, error: "Messaging provider not configured for workspace"}`.
/// That is a legitimate account state rather than a fault, and it must render as
/// an empty state that explains itself. ⛔ It must NEVER be converted into an
/// empty success: telling an operator the carrier has no numbers in their area
/// code is a claim about inventory that was never looked at.
///
/// ⚠️ THE SERVER HARDCODES THE RESULT LIMIT (10) AND THE CAPABILITY FILTER
/// (sms+voice). Neither is a client parameter, so a UI offering a page size or a
/// capability filter would be offering a control the route ignores.
public struct NumberSearchResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Which carrier answered, not which one was asked for.
    public let provider: String
    public let numbers: [AvailableNumber]
}

/// One line the workspace already has, whoever supplies it.
///
/// ⛔ ``managed`` IS THE ONLY FIELD THAT IS NOT THE CARRIER'S OWN, AND IT DECIDES
/// WHAT MAY BE OFFERED. `true` means the line is held on DISTRONODE's carrier
/// account rather than the tenant's, so the tenant cannot release or reconfigure
/// it — the row is theirs to USE, not to administer. The two halves of this list
/// also come from different databases: `managed: false` rows are what the
/// tenant's own carrier account reports, `managed: true` rows are hub records
/// the carrier fetch deliberately never sees. Before the hub read existed, a
/// workspace with live managed DIDs got an empty list, which is
/// indistinguishable from owning none.
///
/// ⚠️ ``provider`` IS WIDENED TO A PLAIN `String` on purpose: the hub's
/// `PhoneNumberIndex.provider` is a free-text column, and a managed row with a
/// blank one falls back to whatever `messagingConfig.managed` names, or to the
/// literal "unknown".
public struct ListedNumber: Codable, Sendable {
    /// E.164. The row's identity.
    public let phoneNumber: String
    /// ⚠️ Absent on a row the carrier never named.
    public let friendlyName: String?
    /// ⚠️ Present and possibly EMPTY — the all-fallbacks managed row carries `[]`
    /// rather than omitting the key, which is a measured "we do not know what
    /// this line can do" rather than "it can do nothing".
    public let capabilities: [String]
    /// Defaulted server-side to "local" on a managed row.
    public let type: String
    /// `in-use`, `active`. Defaulted server-side to "active" on a managed row.
    public let status: String
    /// ⚠️ Absent on every managed row: the webhooks belong to our account, not
    /// the tenant's, so there is nothing of theirs to report.
    public let smsUrl: String?
    /// ⚠️ Absent on every managed row. See ``smsUrl``.
    public let voiceUrl: String?
    /// ⚠️ Free text. See the type doc.
    public let provider: String
    /// ⚠️ Absent, not null, on a managed row with no recorded price. Same shape
    /// as ``AvailableNumber/monthlyPrice`` and for a related reason.
    public let monthlyPrice: Double?
    /// ⛔ Decides what may be offered. See the type doc.
    public let managed: Bool
}

/// `GET /api/district/workspace/provider/numbers` — every number the workspace
/// already has, from every source.
///
/// ⛔ ``partial`` IS THE DANGEROUS SHAPE OF THIS ROUTE AND IT MUST NEVER BE
/// DROPPED. It arrives on a **200** carrying a real but SHORT list: one carrier
/// answered, another did not, and the response decodes perfectly while
/// describing less inventory than the workspace owns. The route reserves its 502
/// for "a carrier failed AND nothing resolved at all", because a failed lookup
/// rendered as an empty list reads as "you own no numbers". ⛔ A screen must
/// therefore render the rows AND name the carrier that is missing — a banner
/// that REPLACED the list would throw away an answer already in hand, and a list
/// with no banner would draw an incomplete inventory as a complete one.
///
/// ⚠️ BOTH FLAGS ARE ABSENT — not false, not empty — ON A CLEAN LIST, which is
/// why both are Optional and why the partial fixture exists beside the clean
/// one: with only one of them, the pair would be indistinguishable to a decoder.
/// Use ``failedProviderNames`` rather than reading either field alone.
///
/// ⚠️ A SECOND CONFIGURED CARRIER IS REQUIRED FOR THE PARTIAL STATE TO BE
/// REACHABLE AT ALL. The route only fetches from providers the workspace has
/// credentials for, so a single-carrier workspace has no partial state — it has
/// a 502 or a complete answer.
public struct OwnedNumbersResponse: Codable, Sendable {
    public let success: Bool
    public let numbers: [ListedNumber]
    /// ⛔ ABSENT on a clean list. See the type doc; branch on
    /// ``failedProviderNames``.
    public let partial: Bool?
    /// ⚠️ Non-empty exactly when ``partial`` is true, and named so a banner can
    /// say WHICH carrier is missing rather than "some data may be missing".
    public let failedProviders: [String]?

    /// The carriers that did not answer, or empty when the list is complete.
    ///
    /// ⛔ THE TWO FLAGS READ AS ONE FACT, so a caller cannot render the short
    /// list without the names or the names without knowing the list is short. ⚠️
    /// Computed, so it adds no key on re-encode.
    public var failedProviderNames: [String] {
        partial == true ? (failedProviders ?? []) : []
    }
}
