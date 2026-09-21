import DistrictModel
import Foundation

/// The overview register's five rows, computed the way the web computes them.
///
/// ⛔ A PORT OF `overview-summary.ts`, FUNCTION FOR FUNCTION, AND THE EDGE CASES ARE THE
/// PRODUCT. Every sentence here is one an operator can see on both clients at once, so
/// "Mon to Fri, 9:00 to 17:00" has to come out of the same grouping rule, the same
/// consecutive-day test and the same unpadded hour on a phone as in a browser. The
/// behaviours that look like accidents below (a two-day run is a comma list, `active` is
/// never pluralised, an unresolved slug is shown raw) were read off the source rather
/// than inferred, and each is marked.
///
/// ⚠️ IT TAKES THE DTOs DIRECTLY RATHER THAN `*Like` PROTOCOLS. The TypeScript declares
/// structural interfaces because its callers pass three differently-shaped objects; here
/// there is exactly one shape per input and it is already typed in `DistrictModel`, so a
/// protocol would be indirection with one conformer.
public enum SchedulingOverviewSummary {
    /// `09:00` → `9:00`. Display only.
    ///
    /// ⛔ NEVER FEED THE RESULT BACK INTO A WRITE. The fork's validator demands a
    /// zero-padded `HH:MM` and refuses `9:00`, so a round trip through this function
    /// turns a saveable value into a **400**. It is the reason the write stage's drafts
    /// keep the padded string and render this only at the leaf.
    ///
    /// ⚠️ A VALUE WITH NO COLON COMES BACK UNCHANGED, matching the TypeScript's
    /// `minute === undefined` guard: it is not a time this function understands and
    /// mangling it would hide that.
    public static func displayTime(_ value: String) -> String {
        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return value }
        let hour = Int(pieces[0]).map(String.init) ?? String(pieces[0])
        return "\(hour):\(pieces[1])"
    }

    /// `Mon to Fri, 9:00 to 17:00; Sat, 10:00 to 14:00`, or nil when nothing is set.
    ///
    /// ⛔ ONLY WORKSPACE-WIDE RULES COUNT. A rule carrying an `eventTypeId` governs one
    /// event type and is NOT part of "your working hours"; including them would report
    /// hours the booking page as a whole does not offer. See the ⛔ on
    /// ``SchedulingAdminRepository/availabilityRules(workspaceId:eventTypeId:)``, which
    /// makes the same distinction on the way in.
    ///
    /// ⚠️ GROUPED BY THE RENDERED PHRASE, NOT BY THE WINDOWS. Two days with the same
    /// hours collapse to one clause because their phrase STRINGS match, which is what
    /// makes "Mon to Fri" possible at all; the group's position is that of the first day
    /// that produced it, so the port needs an ordered dictionary rather than Swift's
    /// unordered one.
    ///
    /// ⚠️ nil RATHER THAN AN EMPTY STRING when no rule qualifies. The caller renders a
    /// "Set your hours" link for nil, and an empty string would draw an empty row.
    public static func summarizeWorkingHours(_ rules: [SchedulingAvailabilityRule]) -> String? {
        var byDay: [Int: [(start: String, end: String)]] = [:]
        for rule in rules where rule.eventTypeId == nil {
            // ⛔ THIS GUARD CANNOT FIRE AND IS KEPT BECAUSE THE SOURCE'S CANNOT EITHER.
            // `displayIndex` has already folded every integer into 0...6, so a corrupt
            // `day_of_week` of `9` arrives here as Tuesday and is SUMMARISED rather than
            // skipped. ⚠️ ``SchedulingHoursFormat/weekFromRules(_:)`` checks the WIRE value
            // instead, before the modulo, and therefore drops the same row — so the two
            // screens genuinely disagree about a corrupt rule. That asymmetry is
            // `overview-summary.ts` and `working-hours.ts` verbatim; removing this line
            // would read as a decision to fold, when the truth is that it is inherited,
            // and tightening it would put the register out of step with the browser.
            // Pinned by `testADayOutsideTheWeekIsFoldedHereAndSkippedInTheGrid`.
            let index = displayIndex(rule.dayOfWeek)
            guard index >= 0, index <= 6 else { continue }
            byDay[index, default: []].append((rule.startTime, rule.endTime))
        }
        guard !byDay.isEmpty else { return nil }

        // ⚠️ AN ARRAY OF PAIRS RATHER THAN A DICTIONARY, because the ORDER of the groups
        // is the order their first day appeared and Swift's `Dictionary` has none.
        var phrases: [(phrase: String, days: [Int])] = []
        for (index, windows) in byDay.sorted(by: { $0.key < $1.key }) {
            let ordered = windows.sorted { $0.start < $1.start }
            let phrase = windowsPhrase(ordered)
            if let existing = phrases.firstIndex(where: { $0.phrase == phrase }) {
                phrases[existing].days.append(index)
            } else {
                phrases.append((phrase, [index]))
            }
        }
        return phrases.map { "\(daysPhrase($0.days)), \($0.phrase)" }.joined(separator: "; ")
    }

    /// The event types a customer could actually book.
    ///
    /// ⚠️ ABSENT COUNTS AS TRUE, WHICH IS THE `!== false` IN THE SOURCE AND NOT A
    /// `== true`. A row whose `is_active` the server did not send is bookable; treating
    /// nil as false would empty the register for any tenancy on an older payload.
    public static func bookableEventTypes(_ items: [SchedulingEventType]) -> [SchedulingEventType] {
        items.filter { $0.isActive != false && $0.isPublic != false }
    }

    /// `3 event types, 2 active`, or nil when there are none.
    ///
    /// ⚠️ THE COUNT IS PLURALISED AND THE WORD `active` IS NOT. That asymmetry is the
    /// web's, verbatim: `1 event type, 1 active` is what it renders. It reads as an
    /// oversight and is what the operator sees in the browser, so it is preserved.
    ///
    /// ⛔ `active` COUNTS `isActive` ALONE AND IS NOT ``bookableEventTypes(_:)``. The two
    /// differ on a row that is active but not public, and the register deliberately
    /// reports the switch the operator threw rather than the derived bookability.
    public static func summarizeEventTypes(_ items: [SchedulingEventType]) -> String? {
        guard !items.isEmpty else { return nil }
        let active = items.filter { $0.isActive != false }.count
        let noun = items.count == 1 ? "event type" : "event types"
        return "\(items.count) \(noun), \(active) active"
    }

    /// `https://<host>/book/<slug>`.
    ///
    /// ⛔ THE SLUG IS PERCENT-ENCODED AND THE HOST IS NOT. The host came from the
    /// tenancy row and is already a hostname; the slug is customer-authored and can carry
    /// anything the fork accepted. ⚠️ `urlPathAllowed` is the wrong set here — it permits
    /// `/`, which would let a slug reach a different path — so the allowed characters are
    /// stated explicitly, matching `encodeURIComponent`.
    public static func bookingUrlFor(publicHost: String, slug: String) -> String {
        "https://\(publicHost)/book/\(encodeURIComponent(slug))"
    }

    /// `Today 14:30`, `Tomorrow 10:00` or `Sep 12, 10:00`. nil when the stamp will not
    /// parse.
    ///
    /// ⛔ RELATIVE ONLY ON THIS SURFACE. The bookings TABLE renders the same instant
    /// absolutely and with a year (``SchedulingBookingFormat/bookingDateTime(startAt:timezone:)``);
    /// the register is a glance and the table is a record. Using one for the other was
    /// checked against the web rather than assumed.
    ///
    /// ⚠️ A PAST BOOKING FALLS THROUGH TO THE ABSOLUTE FORM. There is no "Yesterday":
    /// a negative delta matches neither branch, which is the source's behaviour and is
    /// right for a register whose query asks for upcoming rows anyway.
    public static func bookingWhen(
        startAt: String,
        timezone: String,
        now: Date = Date()
    ) -> String? {
        guard let start = SchedulingClock.parse(startAt) else { return nil }
        let at = SchedulingClock.parts(of: start, timezone: timezone)
        let today = SchedulingClock.parts(of: now, timezone: timezone)
        let clock = SchedulingClock.clock(at)
        guard let delta = SchedulingClock.dayDelta(from: today, to: at) else { return nil }
        if delta == 0 {
            return "Today \(clock)"
        }
        if delta == 1 {
            return "Tomorrow \(clock)"
        }
        guard let month = SchedulingClock.monthName(at.month) else { return nil }
        return "\(month) \(at.day), \(clock)"
    }

    /// The first attendee's name, then their email, then `Someone`.
    ///
    /// ⚠️ A BLANK-AFTER-TRIM NAME FALLS THROUGH TO THE EMAIL, which is the JavaScript
    /// `||` and not a `??`. A row whose attendee name is `"  "` shows the address rather
    /// than an empty cell, and that difference is the whole reason the source uses the
    /// looser operator here and the stricter one elsewhere.
    public static func bookingWho(_ booking: SchedulingBooking) -> String {
        let first = booking.attendees?.first
        if let name = first?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = first?.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return "Someone"
    }

    /// The event type's display name, its slug, or `Booking`.
    ///
    /// ⚠️ AN UNRESOLVED SLUG IS SHOWN RAW RATHER THAN REPLACED. The booking genuinely
    /// names an event type the list did not carry (it may have been deleted since), and
    /// the slug is the only true thing left to say about it; `Booking` is reserved for a
    /// row that names none at all.
    public static func bookingEventTypeName(
        _ booking: SchedulingBooking,
        eventTypes: [SchedulingEventType]
    ) -> String {
        guard let slug = booking.eventTypeSlug, !slug.isEmpty else { return "Booking" }
        return eventTypes.first { $0.slug == slug }?.name ?? slug
    }

    // MARK: - Grouping

    /// ⚠️ `Mon`...`Sun`. The DISPLAY order, which is Monday-first and is not the wire's
    /// Sunday-first `day_of_week`. ``displayIndex(_:)`` is the only conversion.
    static let displayDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Wire (0 = Sunday) to display (0 = Monday).
    static func displayIndex(_ dayOfWeek: Int) -> Int {
        ((dayOfWeek % 7) + 6 + 7) % 7
    }

    /// `9:00 to 17:00` or `9:00 to 12:00 and 13:00 to 17:00`.
    ///
    /// ⚠️ THE SEPARATOR IS `, ` FOR ALL BUT THE LAST PAIR AND ` and ` BEFORE IT, with no
    /// Oxford comma — three windows read "a, b and c".
    static func windowsPhrase(_ windows: [(start: String, end: String)]) -> String {
        let parts = windows.map { "\(displayTime($0.start)) to \(displayTime($0.end))" }
        // One window or none: `joined()` is that window, or "".
        guard parts.count > 1 else { return parts.joined() }
        return "\(parts.dropLast().joined(separator: ", ")) and \(parts[parts.count - 1])"
    }

    /// `Mon to Fri`, or `Mon, Wed, Fri`.
    ///
    /// ⛔ THE RANGE FORM NEEDS **THREE OR MORE** CONSECUTIVE DAYS, SO EXACTLY TWO STAYS A
    /// COMMA LIST. `Mon, Tue` rather than `Mon to Tue` looks like a bug and is the
    /// source's `sorted.length >= 3 && consecutive`; shortening it to two would make this
    /// client word a common case differently from the browser beside it.
    static func daysPhrase(_ indexes: [Int]) -> String {
        let sorted = indexes.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        let consecutive = sorted.enumerated().allSatisfy { offset, value in
            offset == 0 || value == sorted[offset - 1] + 1
        }
        if sorted.count >= 3, consecutive {
            return "\(displayDays[first]) to \(displayDays[last])"
        }
        return sorted.map { displayDays[$0] }.joined(separator: ", ")
    }

    /// `encodeURIComponent`, byte for byte: every UTF-8 byte outside the surviving set
    /// becomes `%XX` with upper-case hex.
    ///
    /// ⛔ ASCII LETTERS AND DIGITS ONLY, NOT `CharacterSet.alphanumerics`. That set is
    /// every Unicode letter and digit, so `addingPercentEncoding` with it left `café`
    /// as it was where the browser sends `caf%C3%A9`, and the two platforms built
    /// different links to the same page. Working on the UTF-8 bytes also has no
    /// failure case, where `addingPercentEncoding` returns an Optional.
    static func encodeURIComponent(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if componentUnreserved.contains(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += "%" + hexDigits[Int(byte >> 4)] + hexDigits[Int(byte & 0x0F)]
            }
        }
        return encoded
    }

    /// ⚠️ `encodeURIComponent`'s SURVIVING SET, written out. Foundation has no
    /// character set that matches it, and the near-misses (`urlPathAllowed`,
    /// `urlQueryAllowed`) both permit `/` and `&`.
    static let componentUnreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8
    )

    private static let hexDigits = "0123456789ABCDEF".map(String.init)
}
