import Foundation

/// Every sentence the automation monitor says, plus the two vocabularies it has to
/// render without exhausting over.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A SCREEN, the same call
/// ``DialerCopy`` makes: `swiftlint --strict` promotes the `file_length` WARNING at 500
/// lines to an error.
///
/// ⛔ THE COPY IS ANDROID'S WHERE ANDROID HAS A STRING, so the two clients say the same
/// thing. The words are load bearing in three places especially: "Paused" rather than "Off", "No batch size
/// configured yet." rather than a zero, and "No workflows yet" rather than "none".
enum WorkflowsCopy {}

/// The trigger vocabulary this build knows, and what to do about the rest of it.
///
/// ⛔ THE RAW WIRE VALUE IS RETURNED FOR ANYTHING NOT LISTED, AND THAT IS THE POINT OF
/// THIS FUNCTION RATHER THAN A FALLBACK. The column is a bare `String` server-side,
/// validated on write against a list that has already grown once
/// (`call_ended_answered` and `call_ended_unanswered` were added alongside
/// `call_ended`, which still fires for every terminal call). An installed build has to
/// keep drawing a workflow whose trigger it has never heard of. A label reading
/// "Unknown" would turn a server-side vocabulary addition into a screen that lies about
/// existing automation.
///
/// ⚠️ THE THREE CALL-END TRIGGERS ARE NOT SYNONYMS AND THEIR LABELS SAY SO.
/// `call_ended` fires for EVERY terminal call; the answered/unanswered pair fires
/// alongside it, exactly one per call. A workflow on all three runs twice.
enum WorkflowTrigger {
    static func label(_ trigger: String) -> String {
        labels[trigger] ?? trigger
    }

    private static let labels: [String: String] = [
        "call_ended": "After any call ends",
        "call_ended_answered": "After an answered call",
        "call_ended_unanswered": "After a missed call",
        "negative_sentiment": "Negative sentiment",
        "positive_sentiment": "Positive sentiment",
        "neutral_sentiment": "Neutral sentiment",
        "intent_detected": "Intent detected",
        "sms_received": "Message received",
        "contact_created": "New contact",
        "dnc_registered": "Added to do-not-call",
    ]
}

extension Tone {
    /// The badge tone for a run's status.
    ///
    /// ⛔ `partial` IS A WARNING, NOT A SUCCESS, AND IT IS THE ONE THAT MATTERS. It means
    /// some actions ran and some did not (a follow-up email that went while the CRM tag
    /// did not), which draws exactly like a healthy run if it is toned green.
    ///
    /// ⚠️ `skipped` IS NEUTRAL RATHER THAN A WARNING: the engine skips a run whose
    /// conditions were not met, which is the workflow working.
    ///
    /// ⚠️ AN UNRECOGNISED STATUS IS NEUTRAL. The vocabulary is free text on the wire and
    /// colouring an unknown value red would report a fault that may not exist. Same rule
    /// as ``Tone/forCallStatus(_:)``, one screen over.
    static func forRunStatus(_ status: String) -> Tone {
        switch status {
        case "success": .success
        case "partial": .warning
        case "failed": .danger
        default: .neutral
        }
    }

    /// The badge tone for one action's outcome. Same reasoning as ``forRunStatus(_:)``,
    /// one level down.
    ///
    /// ⚠️ `skipped` IS NEUTRAL AND CARRIES THE MOST USEFUL TEXT ON THE ROW. The engine
    /// attaches a `reason` to a skip (no contact, no phone number, missing metadata), so
    /// a skip is the outcome an operator can actually act on.
    static func forActionOutcome(_ outcome: String) -> Tone {
        switch outcome {
        case "ok": .success
        case "failed": .danger
        default: .neutral
        }
    }
}
