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
enum WorkflowsCopy {
    static let title = "Workflows"

    static let section = "Workflows"

    static let retry = "Try again"

    static let dismiss = "Dismiss"

    static let listFailed = "Could not load workflows"

    /// ⚠️ "None yet", NEVER "none". An empty list here is a workspace that has not built
    /// any automation, not one whose automation vanished.
    static let emptyTitle = "No workflows yet"

    static let emptyBody = "Workflows run an action after a call, a message or a new contact. "
        + "They cannot be created in this app."

    // MARK: - The always-on SDR campaign

    static let campaignLabel = "Outbound campaign"

    static let campaignActive = "Active"

    /// ⚠️ "Paused", NOT "Off" OR "Not set up". A workspace that switched the campaign off
    /// and one that never opened the campaigns tab are the SAME value on the wire (the
    /// route normalises both), so the word has to be true of both.
    static let campaignPaused = "Paused"

    /// ⛔ NULL IS NOT ZERO. The settings route floors the stored batch size to at least
    /// 1, so a "0" on screen would be a number nobody configured.
    static let campaignBatchUnset = "No batch size configured yet."

    static let campaignNoGoal = "No goal configured yet."

    static let campaignFailed = "Could not load the campaign"

    /// ⛔ NAMES WHAT THIS SCREEN CANNOT DO, AND NAMES NO DESTINATION FOR IT. Pausing merges
    /// ONE key through `workspace/campaign-status`; the goal and the batch size are written
    /// by `campaign-settings`, which rebuilds all three fields from its body, so a phone
    /// editing either of those would have to send all of them. Without this line the
    /// single button reads as a half-built settings form. ⚠️ It must not name the
    /// website: Guideline 3.1.1 makes that steering.
    static let campaignReadOnly = "The campaign goal and batch size cannot be changed in this app."

    /// ⚠️ A VIEWER SENT TO THE WEB DASHBOARD WOULD BE REFUSED THERE TOO, so they are told
    /// who can change it instead.
    static let campaignReadOnlyViewer = "You are in this workspace as a viewer. "
        + "Ask an agency or client member to change the campaign."

    static let campaignPause = "Pause campaign"

    static let campaignResume = "Resume campaign"

    /// ⚠️ REPLACES THE LABEL WHILE A WRITE IS IN FLIGHT rather than sitting beside it:
    /// the button is the only control on the card, so a spinner elsewhere would leave it
    /// looking dead.
    static let campaignWorking = "Saving…"

    static let campaignCancel = "Cancel"

    /// ⛔ THE CONFIRMATIONS NAME THE CONSEQUENCE, NOT "ARE YOU SURE". A pause stops an
    /// engine that is working through a contact list right now; a resume starts spending
    /// call and message credit again. Two facts, two sentences.
    static let campaignPausePrompt = "Pause the outbound campaign? The always-on SDR engine stops working "
        + "through your contacts. Nothing is deleted, and the campaign goal and batch size are kept, "
        + "so resuming picks up where it left off."

    static let campaignResumePrompt = "Resume the outbound campaign? The SDR engine starts calling and "
        + "messaging your contacts again, which spends call and message credit."

    // MARK: - Run history

    static let runsHeading = "Recent runs"

    static let runsEmpty = "This workflow has not run yet."

    static let runsMore = "Load more runs"

    /// ⚠️ SHOWN WHERE A FINISH TIME WOULD BE. A run with no finish did not complete; a
    /// blank there reads as a missing value rather than as the answer.
    static let runUnfinished = "Did not finish"

    static let neverRun = "Never run"

    static func batchLine(_ size: Int) -> String {
        "\(size) contacts per batch"
    }
}

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
