import DistrictData
import DistrictModel
import Foundation

/// The payload fields a webhook delivery may carry, in the fork's own order.
///
/// ⛔ A FOURTH HAND-KEPT COPY OF ONE LIST, AND THAT IS DELIBERATE RATHER THAN
/// SLOPPY. The other three are `defaultFields`/`allFields` in the scheduler fork,
/// the website's `SCHEDULER_WEBHOOK_FIELDS` and the catalog's own schema. Nothing
/// here can derive it: `SchedulingWebhook.fields` is `[String]?` on the way back
/// and carries whatever a row was created with, so reading the list off a response
/// would show a form built from one webhook's history rather than from what may be
/// sent. ⚠️ ORDER IS PART OF IT — the request is filtered THROUGH this array so the
/// stored list matches the one every other surface prints.
enum SchedulingWebhookFieldsC {
    static let all: [String] = [
        "id",
        "status",
        "start_at",
        "end_at",
        "created_at",
        "location_value",
        "cancellation_reason",
        "previous_start_at",
        "previous_end_at",
        "event_type_slug",
        "event_type_name",
        "host_id",
        "host_name",
        "host_email",
        "attendee_name",
        "attendee_email",
        "attendee_timezone",
        "answers",
        "payment_status",
        "amount_paid_cents",
        "amount_paid_currency",
        "hours_before",
    ]

    /// ⛔ THE BOOKER'S OWN DETAILS, OFF BY DEFAULT ON A NEW WEBHOOK. A webhook is a
    /// copy of a booking leaving this platform for a system we know nothing about.
    /// A customer may absolutely send their attendees' names and addresses to their
    /// own CRM, and they should have to tick the box that does it. `answers` is here
    /// for the same reason wearing a different name: it is whatever the booker typed
    /// into the intake questions, the least predictable personal data on the record.
    static let attendee = Set(SchedulingDeveloperFormat.attendeeWebhookFields)

    /// ⛔ NOT THE FORK'S `defaultFields`, WHICH IS A DIFFERENT LIST FOR A DIFFERENT
    /// PURPOSE. That one reproduces the payload of a row created before field
    /// selection existed and omits `event_type_name`, `host_name` and `host_email`
    /// as well — so a webhook created with nil would arrive missing values this form
    /// never offered to remove. Sending the list explicitly is what keeps the ticked
    /// boxes and the delivered payload the same thing.
    static var defaults: Set<String> {
        Set(all).subtracting(attendee)
    }
}

/// What is wrong with a webhook URL, said to the customer, or nil when it can be
/// saved.
///
/// ⛔ HTTPS ONLY, WHICH IS NARROWER THAN THE FORK ON PURPOSE. `CreateWebhook`
/// accepts `http` as well. A delivery carries names, email addresses and whatever
/// the booker typed into the intake questions, and offering to send that in the
/// clear is not a choice this platform puts in front of a customer. The RPC route
/// refuses it too; this check exists so the answer is a sentence rather than a
/// 400 the user cannot act on.
///
/// ⚠️ THE PRIVATE-HOST LIST IS A COURTESY AND NOT THE GUARD. `validateWebhookURL`
/// on the fork resolves the host and rejects any loopback, link-local or private
/// address, at save time AND again at delivery time — neither of which a client
/// can reproduce, since it cannot resolve DNS. What this CAN do is catch the
/// spellings a person actually types.
///
/// ⛔ HAND-PORTED FROM `PRIVATE_HOST_PATTERNS` RATHER THAN RUN AS REGEX. The
/// browser's nine patterns are literal prefixes, suffixes and one numeric range;
/// written as string tests they are readable, allocate nothing, and cannot throw —
/// a runtime-constructed `Regex` can, and a validator that throws on a typo would
/// refuse a URL for a reason nobody could act on.
enum SchedulingWebhookURLCheckC {
    static func issue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SchedulingWriteCopyC.webhookUrlMissing }
        // ⚠️ `URLComponents`, NOT `URL(string:)`. Swift's `URL` parses a bare word
        // into a relative reference with no scheme and no host, which is a SUCCESS
        // — so a `URL(string:) != nil` check would accept "example.com" where the
        // browser's `new URL(...)` throws.
        guard let parsed = URLComponents(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host, !host.isEmpty
        else {
            return SchedulingWriteCopyC.webhookUrlNotAUrl
        }
        guard scheme == "https" else { return SchedulingWriteCopyC.webhookUrlNotHttps }
        guard !isPrivateHost(host) else { return SchedulingWriteCopyC.webhookUrlPrivate }
        return nil
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }
        if lower == "0.0.0.0" || lower == "::1" || lower == "[::1]" {
            return true
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") {
            return true
        }
        if lower.hasPrefix("192.168.") || lower.hasPrefix("169.254.") {
            return true
        }
        return isCarrierPrivate172(lower)
    }

    /// `172.16.` through `172.31.`, which is the one pattern that is a RANGE rather
    /// than a literal. ⚠️ Written out because `172.2.` is public and `172.20.` is
    /// not, so a prefix test on `172.2` would refuse a reachable address.
    private static func isCarrierPrivate172(_ host: String) -> Bool {
        guard host.hasPrefix("172.") else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let second = Int(parts[1]) else { return false }
        return (16 ... 31).contains(second)
    }
}

/// The events/fields form, shared by the create and the edit sheet.
///
/// ⚠️ SETS RATHER THAN ARRAYS, BECAUSE A TICK BOX IS A MEMBERSHIP QUESTION. Order
/// is restored on the way out by filtering the canonical lists, which is what the
/// browser does and what keeps the stored array matching every other surface.
struct SchedulingWebhookDraftC: Equatable {
    var url: String
    var events: Set<SchedulingWebhookEvent>
    var fields: Set<String>

    /// A brand-new webhook: no URL, no events, and every field except the
    /// attendee's own.
    static var blank: SchedulingWebhookDraftC {
        SchedulingWebhookDraftC(url: "", events: [], fields: SchedulingWebhookFieldsC.defaults)
    }

    /// An existing row, as the edit sheet opens it.
    ///
    /// ⛔ AN UNKNOWN EVENT NAME IS DROPPED FROM THE TICKS AND THAT IS THE HONEST
    /// ANSWER, NOT A LOSS. `SchedulingWebhook.events` is `[String]` precisely
    /// because a row created before a rename can carry a value this build's enum
    /// does not have; the form cannot offer a box for one, and the patch would be
    /// refused with `unknown event: <name>` if it sent it back. ⚠️ So a save from
    /// this sheet CAN narrow such a row's subscription — which is why the sheet
    /// says the events it is about to send rather than claiming to preserve them.
    ///
    /// ⚠️ AN ABSENT `fields` IS NOT AN EMPTY SELECTION. The fork substitutes its
    /// own default set at delivery time for a row that never had one, so rendering
    /// nil as "nothing ticked" would show a form claiming the webhook sends no data
    /// at all.
    static func from(_ webhook: SchedulingWebhook) -> SchedulingWebhookDraftC {
        let known = webhook.events.compactMap(SchedulingWebhookEvent.init(rawValue:))
        let fields = webhook.fields.map(Set.init) ?? SchedulingWebhookFieldsC.defaults
        return SchedulingWebhookDraftC(url: webhook.url, events: Set(known), fields: fields)
    }

    /// ⚠️ IN THE FORK'S OWN ORDER, never in tick order.
    var orderedEvents: [SchedulingWebhookEvent] {
        SchedulingWebhookEvent.allCases.filter { events.contains($0) }
    }

    var orderedFields: [String] {
        SchedulingWebhookFieldsC.all.filter { fields.contains($0) }
    }

    /// ⛔ AN UNKNOWN EVENT NAME CARRIED BY THE ROW THIS DRAFT CAME FROM. Shown so
    /// the sheet can say what a save would drop; never sent.
    static func unknownEvents(_ webhook: SchedulingWebhook) -> [String] {
        webhook.events.filter { SchedulingWebhookEvent(rawValue: $0) == nil }
    }
}
