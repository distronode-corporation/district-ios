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
    // MARK: - Test email

    /// The four templates `eventTypes.testEmail` accepts, wire value first.
    ///
    /// ⛔ THE WIRE VALUES ARE THE CATALOG'S AND ARE NOT DERIVED FROM THE LABELS.
    static var emailTemplates: [(type: String, label: String)] {
        [
            ("confirmation", emailTemplateConfirmation),
            ("cancellation", emailTemplateCancellation),
            ("reschedule", emailTemplateReschedule),
            ("reminder", emailTemplateReminder),
        ]
    }

    // MARK: - Hosts

    static var hostRoles: [(value: String, label: String)] {
        [
            ("required", hostRoleRequired),
            ("rotation", hostRoleRotation),
            ("optional", hostRoleOptional),
        ]
    }

    static var routingModes: [(value: String, label: String)] {
        [
            ("fixed", routingModeFixed),
            ("round_robin", routingModeRoundRobin),
            ("collective", routingModeCollective),
        ]
    }

    static var rotationStrategies: [(value: String, label: String)] {
        [
            ("even", rotationStrategyEven),
            ("soonest", rotationStrategySoonest),
            ("priority", rotationStrategyPriority),
        ]
    }

    // MARK: - Booking questions

    static var questionTypes: [(value: String, label: String)] {
        [
            ("text", questionTypeText),
            ("select", questionTypeSelect),
            ("checkbox", questionTypeCheckbox),
        ]
    }
}
