import DistrictModel
import Foundation

public extension JSONValue {
    /// Carry a value that came back on a response into one that can be sent.
    ///
    /// ⛔ IT EXISTS SO A WHOLESALE-REPLACE SAVE CAN BE BUILT FROM WHAT WAS READ, AND
    /// WITHOUT IT `workspace/directory` AND `workspace/routing-rules` WERE UNUSABLE FROM
    /// THIS CLIENT. Both routes replace their stored array outright and validate each row
    /// with a zod `.passthrough()`, so the only safe request is the loaded rows with the
    /// operator's edits applied — and the loaded rows arrive as ``WireJSON`` while the
    /// request builders take ``JSONValue``. `SettingsConfigReadModel` recorded the gap in
    /// prose ("carrying a rule back BYTE-IDENTICALLY across those two types needs a
    /// conversion that does not exist, and a lossy one would strip the keys nothing
    /// models"); this is that conversion.
    ///
    /// ⛔ IT IS LOSSLESS, AND THE ONE LINE THAT MAKES IT SO IS THE `object` ARM. It builds
    /// `.object([String: JSONValue])` DIRECTLY rather than going through
    /// ``JSONValue/object(_:)``, whose whole job is to DROP nil pairs — correct for a
    /// request this client authors field by field, and catastrophic here: a `null` inside
    /// an opaque blob is part of the value, and dropping it would delete a key on a route
    /// that answers 200 either way. ⚠️ `.null` therefore maps to `.null` rather than to an
    /// absence. Read ``WireJSON``'s own ⛔ on the two types before touching this.
    ///
    /// ⚠️ THE NUMERIC CASES DO NOT MERGE. `WireJSON` decodes `Int` BEFORE `Double` so the
    /// contract gate can re-encode `42` as `42` rather than `42.0`, and ``JSONValue`` has
    /// the same pair for the same reason. Collapsing either side would put a decimal point
    /// into a body the server validates with a zod `.int()`.
    ///
    /// ⚠️ IT IS THE HALF-WAY HOUSE, NOT THE FIX. ``WireJSON``'s note says the two types can
    /// and should become one in `DistrictModel` now that `DistrictNetwork` may be edited;
    /// this converts rather than merges because merging is a change to every DTO's stored
    /// type and belongs in its own commit with its own gate run.
    static func carrying(_ value: WireJSON) -> JSONValue {
        switch value {
        case let .string(text):
            .string(text)
        case let .integer(number):
            .integer(number)
        case let .number(number):
            .number(number)
        case let .bool(flag):
            .bool(flag)
        case let .array(values):
            .array(values.map(JSONValue.carrying))
        case let .object(fields):
            // ⛔ NOT `JSONValue.object(_:)`. See the ⛔ above: that factory drops nils.
            .object(fields.mapValues(JSONValue.carrying))
        case .null:
            .null
        }
    }
}
