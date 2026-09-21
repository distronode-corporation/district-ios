import DistrictModel
import Foundation

/// How the two opaque config blobs are read for EDITING.
///
/// ⚠️ DEFENSIVE AT EVERY STEP, WHICH IS WHAT ``WireJSON``'S OWN ⚠️ ASKS FOR ("carried,
/// never rewritten; read known keys defensively at the point of display"). An absent
/// column, a null, an array of something other than objects and a missing key are four
/// different inputs and none of them may crash a settings screen.
enum SettingsWireDisplay {
    /// The transfer directory's rows, or nil when the stored value is not an array of
    /// objects.
    ///
    /// ⛔ THE ROWS THEMSELVES, NOT A PROJECTION OF THEM. The stored row is a `Json`
    /// object written through a `.passthrough()` schema, `PATCH workspace/directory`
    /// REPLACES the whole array, and a row rebuilt from three fields would strip
    /// everything else and be answered 200. ``DirectoryDraft`` carries the row this
    /// returns and overwrites only the keys its form owns.
    ///
    /// ⚠️ AN ABSENT COLUMN IS AN EMPTY LIST, NOT AN UNREADABLE ONE. The save route
    /// writes `callDirectory || []`, so "never configured" and "explicitly empty" are
    /// the same stored value and there is nothing to distinguish.
    static func directoryRows(_ value: WireJSON?) -> [WireJSON]? {
        objectRows(value)
    }

    /// The dynamic-persona rules, or nil when the stored value is not an array of
    /// objects.
    ///
    /// ⛔ THE ROWS THEMSELVES, FOR THE SAME REASON AND WITH A LARGER BLAST RADIUS. The
    /// column holds two different row shapes in one array today — the committed fixture
    /// carries `{id, match, action, target}` alongside builder-shaped rows — and
    /// `POST workspace/routing-rules` replaces the array wholesale. ``RoutingRuleDraft``
    /// is what makes a row this build cannot read survive the round trip.
    static func ruleRows(_ value: WireJSON?) -> [WireJSON]? {
        objectRows(value)
    }

    /// ⚠️ ONE ROW THAT IS NOT AN OBJECT MAKES THE WHOLE VALUE UNREADABLE, rather than
    /// being skipped. Skipping it would silently drop it on the next wholesale save,
    /// which is the same deletion this whole design exists to prevent — so the screen
    /// declines to edit the value at all and says so.
    private static func objectRows(_ value: WireJSON?) -> [WireJSON]? {
        guard let value, value != .null else { return [] }
        guard let rows = value.arrayValue else { return nil }
        guard rows.allSatisfy({ $0.objectValue != nil }) else { return nil }
        return rows
    }
}
