import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Building the scheduling DTOs a formatter test needs, FROM THE WIRE.
///
/// ⛔ EVERY FIXTURE IS DECODED FROM JSON RATHER THAN CONSTRUCTED, AND THAT IS THE POINT
/// RATHER THAN A CONSEQUENCE OF THE DTOs HAVING NO MEMBERWISE INIT. A formatter test that
/// built its input in Swift would assert that the formatter agrees with the test's idea of
/// the shape; starting at the bytes means a `CodingKeys` rename — `booker_name` to
/// `bookerName`, say — fails the formatter test too, where the symptom ("Someone" in every
/// row) is the one an operator would actually report.
///
/// ⚠️ THE SNAKE_CASE KEYS BELOW ARE THE FORK'S AND ARE COPIED FROM THE DTO's OWN
/// `CodingKeys`. They are not guesses; where a key is optional it is written out in at
/// least one fixture and omitted in another, because "absent" and "null" are different
/// answers to several of these functions.
enum SchedulingFixture {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// One weekly availability rule.
    ///
    /// - Parameter eventTypeId: ⛔ `nil` IS THE WORKSPACE-WIDE RULE and a string is one
    ///   event type's override. Both formatters that read these exclude the second, so
    ///   the distinction is exercised rather than defaulted.
    static func rule(
        id: String = "r1",
        eventTypeId: String? = nil,
        dayOfWeek: Int,
        start: String,
        end: String
    ) throws -> SchedulingAvailabilityRule {
        let eventType = eventTypeId.map { "\"\($0)\"" } ?? "null"
        return try decode(SchedulingAvailabilityRule.self, """
        {"id":"\(id)","event_type_id":\(eventType),"day_of_week":\(dayOfWeek),
         "start_time":"\(start)","end_time":"\(end)"}
        """)
    }

    /// One dated override. ⚠️ `groupId` absent is a single day; present folds into a span.
    static func override(
        id: String = "o1",
        date: String,
        isAvailable: Bool = false,
        reason: String = "day_off",
        startTime: String? = nil,
        endTime: String? = nil,
        groupId: String? = nil
    ) throws -> SchedulingAvailabilityOverride {
        var fields = [
            "\"id\":\"\(id)\"",
            "\"date\":\"\(date)\"",
            "\"is_available\":\(isAvailable)",
            "\"reason\":\"\(reason)\"",
        ]
        fields.append("\"start_time\":\(startTime.map { "\"\($0)\"" } ?? "null")")
        fields.append("\"end_time\":\(endTime.map { "\"\($0)\"" } ?? "null")")
        if let groupId {
            fields.append("\"group_id\":\"\(groupId)\"")
        }
        return try decode(SchedulingAvailabilityOverride.self, "{\(fields.joined(separator: ","))}")
    }

    /// One event type. ⚠️ `is_active` / `is_public` are OMITTED when nil rather than sent
    /// as null, because "absent counts as true" is a rule those two formatters hold and an
    /// explicit null would not exercise it.
    static func eventType(
        id: String = "et1",
        slug: String,
        name: String,
        durationMinutes: Int = 30,
        isActive: Bool? = nil,
        isPublic: Bool? = nil
    ) throws -> SchedulingEventType {
        var fields = [
            "\"id\":\"\(id)\"",
            "\"slug\":\"\(slug)\"",
            "\"name\":\"\(name)\"",
            "\"duration_minutes\":\(durationMinutes)",
        ]
        if let isActive {
            fields.append("\"is_active\":\(isActive)")
        }
        if let isPublic {
            fields.append("\"is_public\":\(isPublic)")
        }
        return try decode(SchedulingEventType.self, "{\(fields.joined(separator: ","))}")
    }

    static func booking(
        id: String = "b1",
        slug: String? = nil,
        start: String = "2026-09-12T14:30:00Z",
        end: String = "2026-09-12T15:00:00Z",
        status: String = "confirmed",
        attendees: String? = nil
    ) throws -> SchedulingBooking {
        var fields = [
            "\"id\":\"\(id)\"",
            "\"start_at\":\"\(start)\"",
            "\"end_at\":\"\(end)\"",
            "\"status\":\"\(status)\"",
        ]
        if let slug {
            fields.append("\"event_type_slug\":\"\(slug)\"")
        }
        if let attendees {
            fields.append("\"attendees\":\(attendees)")
        }
        return try decode(SchedulingBooking.self, "{\(fields.joined(separator: ","))}")
    }

    static func schedulerUser(
        id: String = "u1",
        email: String,
        name: String,
        archived: Bool = false
    ) throws -> SchedulingUser {
        try decode(SchedulingUser.self, """
        {"id":"\(id)","email":"\(email)","name":"\(name)","is_admin":false,
         "is_owner":false,"role":"member","archived":\(archived)}
        """)
    }

    static func recording(
        id: String = "rec1",
        status: String = "complete",
        durationS: Int? = nil,
        hasFile: Bool? = nil,
        createdAt: String? = nil,
        bookerName: String? = nil
    ) throws -> SchedulingRecording {
        var fields = ["\"id\":\"\(id)\"", "\"status\":\"\(status)\""]
        if let durationS {
            fields.append("\"duration_s\":\(durationS)")
        }
        if let hasFile {
            fields.append("\"has_file\":\(hasFile)")
        }
        if let createdAt {
            fields.append("\"created_at\":\"\(createdAt)\"")
        }
        if let bookerName {
            fields.append("\"booker_name\":\"\(bookerName)\"")
        }
        return try decode(SchedulingRecording.self, "{\(fields.joined(separator: ","))}")
    }

    static func consent(
        identity: String,
        name: String? = nil,
        decision: String = "continue"
    ) throws -> SchedulingRecordingConsent {
        let nameField = name.map { "\"\($0)\"" } ?? "null"
        return try decode(SchedulingRecordingConsent.self, """
        {"identity":"\(identity)","name":\(nameField),"decision":"\(decision)","decided_at":null}
        """)
    }

    static func calendarConnection(
        id: String = "c1",
        provider: String = "google",
        email: String = "a@b.com",
        isDestination: Bool = false,
        checkConflicts: Bool = false
    ) throws -> SchedulingCalendarConnection {
        try decode(SchedulingCalendarConnection.self, """
        {"id":"\(id)","provider":"\(provider)","account_email":"\(email)",
         "is_destination":\(isDestination),"check_conflicts":\(checkConflicts)}
        """)
    }

    static func calendarSelection(
        id: String = "cal1",
        name: String,
        checkConflicts: Bool? = nil,
        isDestination: Bool? = nil
    ) throws -> SchedulingCalendarSelection {
        var fields = ["\"id\":\"\(id)\"", "\"name\":\"\(name)\""]
        if let checkConflicts {
            fields.append("\"check_conflicts\":\(checkConflicts)")
        }
        if let isDestination {
            fields.append("\"is_destination\":\(isDestination)")
        }
        return try decode(SchedulingCalendarSelection.self, "{\(fields.joined(separator: ","))}")
    }

    static func team(
        id: String = "t1",
        name: String = "Sales",
        memberCount: Int? = nil,
        members: String? = nil
    ) throws -> SchedulingTeam {
        var fields = ["\"id\":\"\(id)\"", "\"name\":\"\(name)\"", "\"slug\":\"sales\""]
        if let memberCount {
            fields.append("\"member_count\":\(memberCount)")
        }
        if let members {
            fields.append("\"members\":\(members)")
        }
        return try decode(SchedulingTeam.self, "{\(fields.joined(separator: ","))}")
    }

    /// A profile with every notification switch settable.
    static func me(
        timezone: String = "America/Toronto",
        timeFormat: String = "24h",
        weekStart: Int = 1,
        dateFormat: String = "dmy",
        notifications: Bool = true
    ) throws -> SchedulingMe {
        try decode(SchedulingMe.self, """
        {"id":"u1","email":"a@b.com","name":"Ada","timezone":"\(timezone)",
         "time_format":"\(timeFormat)","week_start":\(weekStart),"date_format":"\(dateFormat)",
         "is_admin":true,"is_owner":false,"role":"admin",
         "notify_confirmation":\(notifications),"notify_cancellation":\(notifications),
         "notify_reschedule":\(notifications),"notify_reminder":\(notifications),
         "notify_host_booking":\(notifications),"notify_host_cancel":\(notifications),
         "notify_host_reschedule":\(notifications)}
        """)
    }

    static func storage(
        enabled: Bool = true,
        ready: Bool? = nil
    ) throws -> SchedulingStorageSettings {
        var fields = ["\"recordings_enabled\":\(enabled)"]
        if let ready {
            fields.append("\"recordings_storage_ready\":\(ready)")
        }
        return try decode(SchedulingStorageSettings.self, "{\(fields.joined(separator: ","))}")
    }
}
