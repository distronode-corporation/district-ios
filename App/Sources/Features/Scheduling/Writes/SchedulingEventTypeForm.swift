import DistrictData
import DistrictModel
import Foundation

/// One event-type form's typed contents, and the rules that decide whether it may
/// be sent.
///
/// ⛔ A VALUE TYPE BESIDE THE MODEL RATHER THAN FIELDS ON IT, SO THE RULES ARE
/// TESTABLE WITHOUT A TRANSPORT. Everything a reviewer actually argues about here
/// — the slug a name produces, which numbers are refused, which fields a CREATE is
/// allowed to carry — is a pure function of what was typed, and putting it on an
/// `@Observable` class would make every one of those questions require a fake HTTP
/// stack to ask.
///
/// ⛔ EVERY NUMBER IS HELD AS A `String`, WHICH IS THE WEB'S ARRANGEMENT AND IS
/// NOT LAZINESS. A numeric field bound to an `Int` cannot hold "", so clearing the
/// duration to retype it would snap to 0 under the cursor — and 0 is a legal value
/// for four of these fields, so the snap is indistinguishable from an edit. The
/// string is the truth the operator typed; ``whole(_:atLeast:)`` is where it
/// becomes a number or a refusal.
///
/// ⚠️ AND NOTHING HERE VALIDATES WHAT THE SERVER VALIDATES. The catalog's zod
/// schema is the only validator (see the ⛔ on ``SchedulingAdminRepository``); what
/// this mirrors is exactly the set the web mirrors, for the same reason it does —
/// so a host is told before spending a request rather than after.
struct SchedulingEventTypeForm: Equatable {
    var name = ""
    var description = ""
    var duration = "30"
    /// ⚠️ ON A STORED ROW THIS DEFAULTS TO THE DURATION, not to a constant: the
    /// fork sets `slot_interval_minutes` from the duration when it is not given, so
    /// an empty column and "every 30 minutes" are the same booking page.
    var interval = "30"
    var location = SchedulingEventTypeForm.defaultLocation
    var locationValue = ""
    var isActive = true
    var isPublic = true
    var showTakenSlots = false
    var bufferBefore = "0"
    var bufferAfter = "0"
    var minNotice = "0"
    var maxFutureDays = "0"
    var maxActiveBookings = "0"

    /// ⚠️ `livekit` IS THE WEB'S DEFAULT AND IS THE ONE LOCATION THE PLATFORM
    /// PROVISIONS ITSELF, so a create that never touched the tiles still produces a
    /// bookable page.
    static let defaultLocation = "livekit"

    /// The four the web offers, in its order.
    static let offeredLocations: [(value: String, label: String)] = [
        ("livekit", "Built-in video"),
        ("phone", "Phone"),
        ("in_person", "In person"),
        ("link", "Link"),
    ]

    /// What the `location_value` field is called, or nil when the type has none.
    ///
    /// ⛔ nil IS "DRAW NO FIELD", AND IT IS READ FROM ``SchedulingLocationType``
    /// RATHER THAN FROM A SECOND LIST. The scheduler generates the join link for
    /// `livekit`, `google_meet` and `teams`, so a value sent for one of them is at
    /// best ignored; the enum already classifies all seven and an independent list
    /// here would be a second thing to keep in step.
    static func locationTitle(for wire: String) -> String? {
        guard let known = SchedulingLocationType.known(wire) else { return nil }
        return switch known.valueKind {
        case .generated: nil
        case .url: "Meeting link"
        case .phone: "Phone number"
        case .address: "Address"
        }
    }

    /// ⚠️ THE STORED TYPE IS ADDED TO THE TILES WHEN IT IS NOT ONE OF THE FOUR, so
    /// editing a `google_meet` row does not silently re-home it on `livekit`. It is
    /// labelled with its raw value, which is the honest answer for a type this
    /// build was not built to name.
    static func locationChoices(including stored: String?) -> [(value: String, label: String)] {
        guard let stored, !offeredLocations.contains(where: { $0.value == stored }) else {
            return offeredLocations
        }
        return offeredLocations + [(stored, stored)]
    }

    // MARK: - Hydration

    /// ⚠️ THE THREE-STATE FLAGS COLLAPSE THE WEB'S WAY: `is_active !== false`, so an
    /// ABSENT flag reads as on. The wire omits them rather than sending false (see
    /// ``SchedulingEventType``'s three kinds of absence), and defaulting an absent
    /// key to off would turn every event type the handler did not stamp into an
    /// inactive one the moment somebody opened the editor and saved.
    static func from(_ row: SchedulingEventType) -> SchedulingEventTypeForm {
        var form = SchedulingEventTypeForm()
        form.name = row.name
        form.description = row.description ?? ""
        form.duration = String(row.durationMinutes)
        form.interval = String(row.slotIntervalMinutes ?? row.durationMinutes)
        form.location = row.locationType ?? defaultLocation
        form.locationValue = row.locationValue ?? ""
        form.isActive = row.isActive != false
        form.isPublic = row.isPublic != false
        form.showTakenSlots = row.showTakenSlots == true
        form.bufferBefore = String(row.bufferBeforeMinutes ?? 0)
        form.bufferAfter = String(row.bufferAfterMinutes ?? 0)
        form.minNotice = String(row.minNoticeMinutes ?? 0)
        form.maxFutureDays = String(row.maxFutureDays ?? 0)
        form.maxActiveBookings = String(row.maxActiveBookings ?? 0)
        return form
    }

    // MARK: - Validation

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A whole number at or above `floor`, or nil.
    static func whole(_ raw: String, atLeast floor: Int) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= floor else { return nil }
        return value
    }

    /// The create modal's rules: a name and a duration, and nothing else.
    var createError: String? {
        if trimmedName.isEmpty {
            return SchedulingWriteCopy.nameMissing
        }
        if Self.whole(duration, atLeast: 1) == nil {
            return SchedulingWriteCopy.createDurationInvalid
        }
        return nil
    }

    /// The editor's rules: the name, two minute counts and five plain counts.
    ///
    /// ⚠️ FIRST FAULT WINS AND IS REPORTED ONCE. The web attaches an error to each
    /// field; this sheet has one strip, so reporting them all would stack sentences
    /// that mostly repeat each other.
    var editError: String? {
        if trimmedName.isEmpty {
            return SchedulingWriteCopy.nameMissing
        }
        if Self.whole(duration, atLeast: 1) == nil || Self.whole(interval, atLeast: 1) == nil {
            return SchedulingWriteCopy.atLeastOneMinute
        }
        let counts = [bufferBefore, bufferAfter, minNotice, maxFutureDays, maxActiveBookings]
        if counts.contains(where: { Self.whole($0, atLeast: 0) == nil }) {
            return SchedulingWriteCopy.atLeastZero
        }
        return nil
    }

    // MARK: - What goes on the wire

    /// The four keys `eventTypes.create` is given.
    ///
    /// ⛔ FOUR OF THE FOURTEEN THE SCHEMA ACCEPTS, WHICH IS THE WEB'S CHOICE AND
    /// WORTH KEEPING. Everything else has a defensible default at the fork
    /// (`slot_interval_minutes` becomes the duration, the rest become 0), and a
    /// create form offering ten more controls is ten more ways to be told 400
    /// before the event type exists at all. They are all editable a tap later.
    ///
    /// ⚠️ RETURNS nil WHEN ``createError`` WOULD, so an unvalidated caller cannot
    /// compose a body from a form that was refused.
    func createDraft(slug: String) -> SchedulingEventTypeDraft? {
        guard createError == nil, let minutes = Self.whole(duration, atLeast: 1) else { return nil }
        var draft = SchedulingEventTypeDraft(slug: slug, name: trimmedName, durationMinutes: minutes)
        draft.locationType = location
        return draft
    }

    /// The editor's patch.
    ///
    /// ⛔ EVERY FIELD IS SENT EVERY TIME, INCLUDING AN EMPTY `location_value`, AND
    /// THE WEB DOES THE SAME. A sparse patch built by diffing against the loaded row
    /// would be smaller and would also make "I cleared the address" indistinguishable
    /// from "I did not touch the address" — nil means LEAVE ALONE on this schema, so
    /// the diff cannot express the clear that the form plainly did.
    /// ⚠️ It is still not a way to null a column: `location_value: ""` stores an empty
    /// string, because the catalog's fields are `.optional()` and not `.nullable()`.
    func changes() -> SchedulingEventTypeChanges? {
        guard editError == nil else { return nil }
        var changes = SchedulingEventTypeChanges()
        changes.name = trimmedName
        changes.description = description
        changes.durationMinutes = Self.whole(duration, atLeast: 1)
        changes.slotIntervalMinutes = Self.whole(interval, atLeast: 1)
        changes.locationType = location
        changes.locationValue = locationValue
        changes.isActive = isActive
        changes.isPublic = isPublic
        changes.showTakenSlots = showTakenSlots
        changes.bufferBeforeMinutes = Self.whole(bufferBefore, atLeast: 0)
        changes.bufferAfterMinutes = Self.whole(bufferAfter, atLeast: 0)
        changes.minNoticeMinutes = Self.whole(minNotice, atLeast: 0)
        changes.maxFutureDays = Self.whole(maxFutureDays, atLeast: 0)
        changes.maxActiveBookings = Self.whole(maxActiveBookings, atLeast: 0)
        return changes
    }
}
