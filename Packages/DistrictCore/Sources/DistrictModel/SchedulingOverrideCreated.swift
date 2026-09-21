import Foundation

// The `availability.overrides.create` response, which is two shapes from one
// endpoint.
//
// ⛔ IN `DistrictModel` RATHER THAN BESIDE THE REPOSITORY, BECAUSE THE CONTRACT
// GATE CAN ONLY SEE THIS MODULE. `ContractFixtureTests` depends on
// `ContractGateSupport` and `DistrictModel` and nothing else, deliberately — a
// fixture suite that could import the repository layer would drag the whole
// dependency graph into a test about JSON. A wire type that is not here is a wire
// type `StrictDecodeVerifier` cannot pin.
//
// ⚠️ `Codable`, NOT `Decodable`. Nothing in the app encodes one; the gate does,
// because its unknown-key check IS a re-encode.

/// One dated exception to the weekly availability rules.
///
/// ⚠️ SNAKE_CASE ON THE WIRE, WHICH IS THE SCHEDULER'S CONVENTION AND NOT
/// DISTRICT'S. Every other DTO in this package mirrors a Distronode route and is
/// camelCase; these pass THROUGH our RPC from a fork that is not ours, so the keys
/// are spelled out rather than converted. ⛔ Do not reach for
/// `.convertFromSnakeCase` on the shared decoder to "fix" it — ``ApiClient`` uses
/// a plain `JSONDecoder` for every route in the client, and changing it would
/// re-map the whole District surface to chase four fields.
///
/// ⚠️ MINIMAL ON PURPOSE, AND IT IS THE ONLY SCHEDULER ROW TYPE THAT EXISTS YET.
/// S1b ports the rest; this is the subset ``SchedulingOverrideCreated`` needs in
/// order to exist at all, which it has to because `availability.overrides.create`
/// is the one op in the catalog whose 201 has two structurally different shapes.
public struct SchedulingAvailabilityOverride: Codable, Equatable, Sendable {
    public let id: String
    public let date: String
    public let isAvailable: Bool
    public let reason: String
    /// ⚠️ NULLABLE, NOT ABSENT: an all-day block carries an explicit `null`.
    public let startTime: String?
    public let endTime: String?
    /// ⚠️ OPTIONAL, unlike the two above — present only when this row was created
    /// as part of a RANGE. It is what links a single day back to its group, and
    /// therefore what makes ``SchedulingAdminOp/availabilityOverridesDeleteGroup``
    /// addressable from a row the user tapped.
    public let groupId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case isAvailable = "is_available"
        case reason
        case startTime = "start_time"
        case endTime = "end_time"
        case groupId = "group_id"
    }
}

/// The summary a RANGE override answers with instead of a row.
///
/// ⛔ `start` AND `end` ARE **DATES**, NOT TIMES, unlike the `start_time` /
/// `end_time` pair on the row one type up. The two shapes come out of one
/// endpoint and the field names rhyme; reading a date into a time formatter is the
/// obvious way to get this wrong and it renders as a plausible wrong answer rather
/// than as an error.
public struct SchedulingOverrideGroup: Codable, Equatable, Sendable {
    public let groupId: String
    public let reason: String
    public let start: String
    public let end: String
    /// How many days the range covers.
    public let days: Int

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case reason
        case start
        case end
        case days
    }
}

/// What `availability.overrides.create` answers: a row, or a range summary.
///
/// ⛔ TWO STRUCTURALLY DIFFERENT 201 BODIES FROM ONE ENDPOINT, which is why this
/// is a union rather than one loose object with everything optional. A single-date
/// override answers a row; a date RANGE answers
/// `{group_id, reason, start, end, days}` with no `id` in it at all. Modelled as
/// one type with optional fields, a caller would have to guess which half is
/// populated, and the guess would be `if let id` — the same test as below, made
/// once per call site instead of once here.
///
/// ⛔ DISAMBIGUATED ON THE PRESENCE OF `id`, NOT ON `group_id`, AND THE NEAR MISS
/// IS WHY THIS IS WRITTEN DOWN. A row created as part of a range CARRIES a
/// `group_id`, so "has a group id ⇒ it is the group summary" is true of most
/// bodies and wrong for exactly the ones that matter. `id` is present on every row
/// and on no summary.
///
/// ⚠️ TRIED IN ROW ORDER, and the order is load-bearing rather than stylistic: a
/// `try?` on the row first means a body carrying both keys decodes as the row,
/// which is the correct reading — a summary has no `id` to offer.
public enum SchedulingOverrideCreated: Codable, Equatable, Sendable {
    case single(SchedulingAvailabilityOverride)
    case range(SchedulingOverrideGroup)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let row = try? container.decode(SchedulingAvailabilityOverride.self) {
            self = .single(row)
            return
        }
        self = try .range(container.decode(SchedulingOverrideGroup.self))
    }

    /// ⛔ IT MIRRORS ``init(from:)`` EXACTLY, AND AN ASYMMETRY HERE IS THE ONE
    /// CONTRACT FAULT NO DECODE-ONLY TEST CAN SEE. `StrictDecodeVerifier` decodes
    /// and then RE-ENCODES, comparing key sets; an `encode(to:)` that wrapped the
    /// arm in a discriminator, or emitted the other arm's keys, would pass every
    /// runtime test in the package and fail the gate — which is precisely what the
    /// gate is for.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .single(row):
            try container.encode(row)
        case let .range(group):
            try container.encode(group)
        }
    }
}
