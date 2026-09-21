/// Accessibility identifiers for the scheduling admin's WRITE sheets.
///
/// ⛔ ITS OWN FILE RATHER THAN A CASE IN `A11yID.swift`, WHICH IS A CONCURRENCY
/// DECISION AND NOT A TASTE ONE. Two surfaces appending to one nested enum in parallel
/// is a conflict on every line either of them touched. An extension compiles into the same two targets
/// (`App/Shared` is listed by the app AND the UI-test bundle) and costs nothing.
///
/// ⚠️ iOS-FIRST, EVERY ONE OF THEM. Android has no native scheduling admin, so
/// there is no Kotlin name to copy verbatim the way `A11yID` requires where one
/// exists. They follow the same `district-<area>-<thing>` shape so the day Android
/// ports this surface it has names to adopt rather than invent.
///
/// ⚠️ ONE LEVEL OF NESTING, deliberately: `.swiftlint.yml` warns at
/// `nesting.type_level: 2` and `--strict` makes that an error, so a
/// `SchedulingWrites.EventType` sub-enum would not compile the lint gate.
extension A11yID {
    enum SchedulingWrites {
        // The event type editor.
        static let editorRoot = "district-scheduling-editor-root"
        static let editorName = "district-scheduling-editor-name"
        static let editorDescription = "district-scheduling-editor-description"
        static let editorDuration = "district-scheduling-editor-duration"
        static let editorInterval = "district-scheduling-editor-interval"
        static let editorLocation = "district-scheduling-editor-location"
        static let editorLocationValue = "district-scheduling-editor-location-value"
        static let editorSave = "district-scheduling-editor-save"
        static let editorCancel = "district-scheduling-editor-cancel"
        static let editorError = "district-scheduling-editor-error"

        // The row actions: turn on/off, archive, test email, delete.
        static let actionsRoot = "district-scheduling-actions-root"
        static let actionsToggle = "district-scheduling-actions-toggle"
        static let actionsArchive = "district-scheduling-actions-archive"
        static let actionsDelete = "district-scheduling-actions-delete"
        static let actionsNotice = "district-scheduling-actions-notice"
        /// ⚠️ One per template, suffixed with the wire value (`confirmation`, …).
        static let actionsTestEmailBase = "district-scheduling-actions-test-email"
        static func testEmail(_ type: String) -> String {
            A11yID.row(actionsTestEmailBase, type)
        }

        // Hosts.
        static let hostsRoot = "district-scheduling-hosts-root"
        static let hostsMode = "district-scheduling-hosts-mode"
        static let hostsStrategy = "district-scheduling-hosts-strategy"
        static let hostsSave = "district-scheduling-hosts-save"
        static let hostsRowBase = "district-scheduling-host-row"
        static func host(_ userId: String) -> String {
            A11yID.row(hostsRowBase, userId)
        }

        // Booking questions.
        static let questionsRoot = "district-scheduling-questions-root"
        static let questionsAdd = "district-scheduling-questions-add"
        static let questionsLabel = "district-scheduling-questions-label"
        static let questionsType = "district-scheduling-questions-type"
        static let questionsPosition = "district-scheduling-questions-position"
        static let questionsSubmit = "district-scheduling-questions-submit"
        static let questionsRowBase = "district-scheduling-question-row"
        static func question(_ id: String) -> String {
            A11yID.row(questionsRowBase, id)
        }

        // Weekly working hours.
        static let hoursRoot = "district-scheduling-hours-root"
        static let hoursSave = "district-scheduling-hours-save"
        static let hoursDayBase = "district-scheduling-hours-day"
        static func day(_ index: Int) -> String {
            A11yID.row(hoursDayBase, String(index))
        }

        // Dated overrides.
        static let overridesRoot = "district-scheduling-overrides-root"
        static let overridesAdd = "district-scheduling-overrides-add"
        static let overridesDate = "district-scheduling-overrides-date"
        static let overridesEndDate = "district-scheduling-overrides-end-date"
        static let overridesSubmit = "district-scheduling-overrides-submit"
        static let overridesRowBase = "district-scheduling-override-row"
        static func overrideRow(_ id: String) -> String {
            A11yID.row(overridesRowBase, id)
        }
    }
}
