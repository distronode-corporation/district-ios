import Foundation

// The weekly availability rule, and where the dated override already lives.
//
// ⛔ ``SchedulingAvailabilityOverride`` IS **NOT** DECLARED HERE AND MUST NOT BE.
// S1a landed it in `SchedulingOverrideCreated.swift`, because
// `availability.overrides.create` answers a union of that row and a range summary
// and the union could not exist without it. A second definition beside the rest of
// the availability family would compile — two types in one module may not share a
// name, but nothing stops `SchedulingAvailabilityOverrideRow` sitting next to it —
// and the two would then drift a field at a time, with the contract gate pinning
// whichever one the fixture list happened to name. The list op, the patch op and
// the create op all decode the one type in that file.

/// One weekly availability window.
///
/// ⛔ `event_type_id` IS NULLABLE AND THE NULL IS THE LOAD-BEARING VALUE: it means
/// the rule applies to EVERY event type the member hosts, not that the rule is
/// unattached or broken. A screen that filtered nulls out would hide the default
/// working week — which is the only rule most tenancies ever create — and a
/// caller that sent a real id "to tidy it up" would narrow a global rule to one
/// event type silently. It arrives as an explicit `null` rather than as an absent
/// key (the catalog spells it `.nullable()` with no `.optional()`), which is why
/// it has a path in `AllowedExplicitNulls+SchedulingA.swift`.
///
/// ⛔ `start_time` AND `end_time` ARE ZERO-PADDED `HH:MM` WALL-CLOCK STRINGS IN
/// THE MEMBER'S OWN TIMEZONE, and they are neither instants nor dates. The fork
/// refuses `9:00`, so a formatter that drops the leading zero produces a 400 on
/// the way back in; and the zone is the scheduler user's `timezone` (`me.get`),
/// not the device's, so rendering these against `TimeZone.current` shifts a
/// travelling member's published hours without anything on screen saying so.
/// ⚠️ ``SchedulingSlot`` uses the same two names for INSTANTS and
/// ``SchedulingOverrideGroup`` uses them for DATES.
///
/// ⚠️ `day_of_week` IS 0...6 WITH 0 = SUNDAY, matching the fork's own column and
/// `me.get`'s `week_start`. It is not `Calendar`'s `weekday`, which is 1...7.
public struct SchedulingAvailabilityRule: Codable, Equatable, Sendable {
    public let id: String
    /// ⚠️ NULL MEANS "EVERY EVENT TYPE". See the type doc.
    public let eventTypeId: String?
    /// 0...6, Sunday first. See the type doc.
    public let dayOfWeek: Int
    /// Zero-padded `HH:MM`. See the type doc.
    public let startTime: String
    /// Zero-padded `HH:MM`. See the type doc.
    public let endTime: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventTypeId = "event_type_id"
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
    }
}
