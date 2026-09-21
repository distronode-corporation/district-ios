import Foundation

/// The event-type editor, its row actions, its hosts and its booking questions.
///
/// ⚠️ THE LOCATION TILES ARE FOUR OF THE CATALOG'S SEVEN, WHICH IS THE WEB'S
/// CHOICE AND NOT AN OVERSIGHT. The web's `OFFERED_LOCATION_TYPES`
/// offers `livekit`, `phone`, `in_person` and `link`; `google_meet`, `teams` and
/// `custom_video` are legal on the wire, arrive on stored rows, and are not
/// OFFERED because the platform does not provision the first two and the third is
/// a `link` with a longer name. A stored row carrying one still edits — see
/// ``SchedulingEventTypeForm/locationTitle(for:)``.
extension SchedulingWriteCopy {
    // MARK: - The editor

    static let createTitle = "Create event type"
    static let editTitle = "Edit event type"
    static let nameLabel = "Name"
    static let namePlaceholder = "Phone consultation"
    static let descriptionLabel = "Description"
    static let descriptionHint = "Shown on the booking page."
    static let durationLabel = "Duration"
    static let durationHint = "How long the meeting runs, in minutes."
    static let intervalLabel = "Starts every"
    static let intervalHint = "How often a booking may start. Independent of the duration."
    static let locationLabel = "Location"
    static let activeToggle = "Active"
    static let listedToggle = "Listed on your booking page"
    static let showTakenToggle = "Show taken times as taken"
    static let bookingPageLabel = "Booking page"
    static let bookingPageHint =
        "The address customers use. It cannot be changed: links you have already shared point at it."
    static let bufferBeforeLabel = "Buffer before"
    static let bufferBeforeHint = "Minutes kept free before a booking."
    static let bufferAfterLabel = "Buffer after"
    static let bufferAfterHint = "Minutes kept free after a booking."
    static let minNoticeLabel = "Minimum notice"
    static let minNoticeHint = "Minutes. How soon from now a customer may book."
    static let maxFutureLabel = "Bookable ahead"
    static let noLimitHint = "0 means no limit."
    static let maxActiveLabel = "Active bookings per attendee"

    static let nameMissing = "Give the event type a name."
    /// ⚠️ THE CREATE MODAL'S SENTENCE IS LONGER THAN THE EDITOR'S, in the web too:
    /// the modal has one number on it and can afford to name it.
    static let createDurationInvalid = "The duration has to be a whole number of minutes, at least 1."
    static let atLeastOneMinute = "Has to be a whole number of minutes, at least 1."
    static let atLeastZero = "Has to be a whole number, 0 or more."

    static let created = "Event type created"
    static let saved = "Event type saved"

    // MARK: - Row actions

    static let turnOn = "Turn on"
    static let turnOff = "Turn off"
    static let turnedOn = "Event type turned on"
    static let turnedOff = "Event type turned off"
    static let archive = "Archive"
    static let restore = "Restore"
    static let archived = "Event type archived"
    static let restored = "Event type restored"
    static let deleteEventTypeTitle = "Delete event type?"
    /// ⛔ IT NAMES WHAT SURVIVES, WHICH IS THE HALF AN OPERATOR CANNOT GUESS.
    static let deleteEventTypeBody = "Its booking page stops working. Existing bookings keep their times."
    static let deleteEventTypeConfirm = "Delete event type"
    static let eventTypeDeleted = "Event type deleted"

    // MARK: - Test email

    static let sendTestEmail = "Send test email"
    /// ⛔ "SENT TO", NOT "DELIVERED TO". ``SchedulingTestEmailResult`` is the
    /// scheduler having handed the message to its mail transport; the web says the
    /// same thing for the same reason.
    static func testEmailSent(to address: String) -> String {
        "Test email sent to \(address)"
    }

    static let testEmailNotSent = "The booking system did not send the test email."

    /// The four templates `eventTypes.testEmail` accepts, wire value first.
    ///
    /// ⛔ THE WIRE VALUES ARE THE CATALOG'S AND ARE NOT DERIVED FROM THE LABELS.
    static let emailTemplates: [(type: String, label: String)] = [
        ("confirmation", "Confirmation"),
        ("cancellation", "Cancellation"),
        ("reschedule", "Reschedule"),
        ("reminder", "Reminder"),
    ]

    // MARK: - Hosts

    static let hostsTitle = "Hosts"
    static let hostsSaved = "Hosts saved"
    static let hostsEmpty = "No hosts yet. Add at least one or nobody can be booked."
    /// ⛔ THE SAVE REFUSES, NOT THE REMOVE — the web's own arrangement. The schema
    /// requires a non-empty array, so an event type cannot be left hostless; being
    /// told at Save is what lets somebody swap the only host for a different one.
    static let hostsNeedOne = "An event type needs at least one host."
    static let hostPriorityInvalid = "A host's priority has to be a whole number, 0 or more."
    static let routingModeLabel = "Routing"
    static let rotationLabel = "Rotation"
    static let rotationHint = "Which host the next booking goes to."
    static let priorityLabel = "Priority"

    static let hostRoles: [(value: String, label: String)] = [
        ("required", "Required"),
        ("rotation", "Rotation"),
        ("optional", "Optional"),
    ]

    static let routingModes: [(value: String, label: String)] = [
        ("fixed", "Fixed"),
        ("round_robin", "Round robin"),
        ("collective", "Collective"),
    ]

    static let rotationStrategies: [(value: String, label: String)] = [
        ("even", "Even"),
        ("soonest", "Soonest"),
        ("priority", "Priority"),
    ]

    // MARK: - Booking questions

    static let questionsTitle = "Questions"
    static let questionAddTitle = "Add question"
    static let questionEditTitle = "Edit question"
    static let questionSaveButton = "Save question"
    static let questionLabelLabel = "Label"
    static let questionLabelPlaceholder = "What would you like to talk about?"
    static let questionTypeLabel = "Type"
    static let questionRequiredToggle = "Required"
    static let questionPositionLabel = "Position"
    static let questionPositionHint = "Lower numbers are asked first."
    static let questionOptionsLabel = "Options"
    static let questionOptionsHint = "What the customer can choose from."
    static let questionAddOption = "Add option"
    static let questionOptionPlaceholder = "Add an option"
    static let questionLabelMissing = "Give the question a label."
    static let questionNeedsOption = "A Select question needs at least one option."
    static let questionPositionInvalid = "Position has to be a whole number, 0 or more."
    static let questionAdded = "Question added"
    static let questionSaved = "Question saved"
    static let questionDeleteTitle = "Delete question?"
    static let questionDeleteBody = "Customers stop being asked it. Answers already given stay on their bookings."
    static let questionDeleteConfirm = "Delete question"
    static let questionDeleted = "Question deleted"
    static let questionsEmpty = "No questions yet. Customers give their name, email and nothing else."

    static let questionTypes: [(value: String, label: String)] = [
        ("text", "Text"),
        ("select", "Select"),
        ("checkbox", "Checkbox"),
    ]
}
