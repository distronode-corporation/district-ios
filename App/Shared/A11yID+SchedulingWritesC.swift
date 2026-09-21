/// Accessibility identifiers for the scheduling admin's DEVELOPER and CALENDAR
/// writes.
///
/// ⛔ ITS OWN FILE RATHER THAN A BLOCK INSIDE `A11yID.swift`, AND THAT IS A
/// CONCURRENCY-OF-AUTHORS DECISION RATHER THAN A STYLE ONE. Three write surfaces
/// extend the same `A11yID` enum; one shared file would be three writers on one set
/// of adjacent lines, which is a conflict per commit and no compiler help at all. An
/// `extension` per surface is namespaced by the compiler: two authors cannot silently
/// define the same nested enum, because the second one fails to build.
///
/// ⚠️ NO IMPORTS, MATCHING `A11yID.swift`. This file is compiled into BOTH the app
/// target and `DistrictAIUITests` from `App/Shared`; anything it imports has to be
/// importable by a `bundle.ui-testing` target too.
///
/// ⚠️ THE STRINGS ARE iOS-FIRST. Android has no native scheduling admin, so there
/// is nothing to mirror verbatim the way `district-nav-overview` mirrors it; the
/// shape (`district-<surface>-<thing>`) is copied instead.
extension A11yID {
    /// API keys, connected apps and webhooks — the Developer tab's writes.
    enum SchedulingDeveloperWrites {
        static let keyNameField = "district-scheduling-key-name"
        static let keyCreate = "district-scheduling-key-create"
        /// ⛔ THE REVEALED PLAINTEXT'S OWN ELEMENT. A UI test may assert it is
        /// GONE after the sheet closes; it must never assert its VALUE, because a
        /// UI-test failure message quotes the element it was looking at.
        static let keyRevealed = "district-scheduling-key-revealed"
        static let keyCopy = "district-scheduling-key-copy"
        static let keyRevoke = "district-scheduling-key-revoke"

        static let appRevoke = "district-scheduling-app-revoke"

        static let webhookUrlField = "district-scheduling-webhook-url"
        static let webhookSubmit = "district-scheduling-webhook-submit"
        static let webhookSecretRevealed = "district-scheduling-webhook-secret"
        static let webhookDelete = "district-scheduling-webhook-delete"
        static let webhookDeliveries = "district-scheduling-webhook-deliveries"

        static let eventRowBase = "district-scheduling-webhook-event"
        static let fieldRowBase = "district-scheduling-webhook-field"
        static let deliveryRowBase = "district-scheduling-webhook-delivery"

        static func event(_ name: String) -> String {
            A11yID.row(eventRowBase, name)
        }

        static func field(_ name: String) -> String {
            A11yID.row(fieldRowBase, name)
        }

        static func delivery(_ id: String) -> String {
            A11yID.row(deliveryRowBase, id)
        }
    }

    /// The caller's own calendar connections.
    enum SchedulingCalendarWrites {
        static let caldavPreset = "district-scheduling-caldav-preset"
        static let caldavServerUrlField = "district-scheduling-caldav-server-url"
        static let caldavUsernameField = "district-scheduling-caldav-username"
        /// ⛔ THE FIELD, NEVER THE VALUE. The app password is an app-specific
        /// credential the host generated at their provider; nothing may read it
        /// back out, and a UI test addresses the box rather than its contents.
        static let caldavPasswordField = "district-scheduling-caldav-password"
        static let caldavSubmit = "district-scheduling-caldav-submit"

        static let connectProviderBase = "district-scheduling-calendar-connect"
        static let disconnect = "district-scheduling-calendar-disconnect"
        static let calendarsSave = "district-scheduling-calendars-save"
        static let conflictRowBase = "district-scheduling-calendar-conflict"
        static let destinationRowBase = "district-scheduling-calendar-destination"

        static func connect(_ provider: String) -> String {
            A11yID.row(connectProviderBase, provider)
        }

        static func conflict(_ id: String) -> String {
            A11yID.row(conflictRowBase, id)
        }

        static func destination(_ id: String) -> String {
            A11yID.row(destinationRowBase, id)
        }
    }
}
