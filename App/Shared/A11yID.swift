/// Accessibility identifiers, shared by the app and the UI-test bundle.
///
/// ⛔ IDENTITY, NEVER POSITION. A UI test that taps "the third row" passes until
/// somebody sorts the list, and then fails somewhere unrelated to the change. Every
/// identifier here names WHAT a thing is; rows suffix the server's own id through
/// ``row(_:_:)`` so a test addresses `ct-review-01` rather than an index.
///
/// ⛔ THE STRINGS MIRROR ANDROID'S WHERE ANDROID HAS ONE, AND THEY ARE COPIED
/// VERBATIM RATHER THAN RE-DERIVED. `district-nav-overview`, `district-sign-in-root`,
/// `district-dialer-refusal` and the rest already exist in the Android client; two
/// clients disagreeing about the name of the same element would make every
/// cross-platform test plan a translation exercise.
/// ⚠️ WHERE ANDROID HAS NONE, THE NAME IS NEW AND SAYS SO in a comment — Account's
/// rows and the individual keypad keys are iOS-first, because Android's dialer
/// addresses its field rather than its keys.
///
/// ⚠️ NO IMPORTS, AND `internal` RATHER THAN `public`. This file is compiled into
/// BOTH the app target and `DistrictAIUITests` from `App/Shared`, because a
/// `bundle.ui-testing` target cannot `@testable import` the app under test. Sharing
/// the SOURCE is what keeps one definition; sharing a module would need a package.
enum A11yID {
    /// `"\(base)-\(id)"` — a row addressed by the server's own id.
    ///
    /// ⚠️ THE SERVER ID IS NOT SANITISED. It is an opaque identifier the API already
    /// chose; rewriting it here would mean the test and the app disagreed about the
    /// same row the moment one of them changed its rules.
    static func row(_ base: String, _ id: String) -> String {
        "\(base)-\(id)"
    }

    /// ⛔ THE TAB BAR IS ADDRESSED BY LABEL, NOT BY IDENTIFIER, AND THAT IS FORCED BY
    /// SwiftUI RATHER THAN CHOSEN. `.tabItem` takes no identifier of its own: an
    /// `.accessibilityIdentifier` on the tab's content tags the CONTENT view, and the
    /// tab-bar button keeps only its label. Measured on an iPhone XS Max from
    /// `app.debugDescription` — `district-nav-overview` appeared as a full-screen
    /// `Other`, while the TabBar held `Button, label: 'Overview'`.
    ///
    /// ⚠️ SO THE LABELS LIVE HERE, compiled into both the app and the UI bundle, and
    /// ``Tab/label`` reads them. Two copies of "Overview" would be a test that passes
    /// until somebody renames a tab.
    enum NavLabel {
        static let overview = "Overview"
        static let inbox = "Inbox"
        static let calls = "Calls"
        static let contacts = "Contacts"
        static let account = "Account"
    }

    /// ⚠️ THESE TAG EACH TAB'S CONTENT ROOT, NOT ITS BUTTON. Useful for asserting
    /// WHICH tab is showing; useless for tapping one. See ``NavLabel``.
    enum Nav {
        static let overview = "district-nav-overview"
        static let inbox = "district-nav-inbox"
        static let calls = "district-nav-calls"
        static let contacts = "district-nav-contacts"
        static let account = "district-nav-account"
    }

    enum SignIn {
        static let root = "district-sign-in-root"
        static let status = "district-sign-in-status"
        /// iOS-first: Android's sign-in button is addressed through its root.
        static let button = "district-sign-in-button"
        /// ⛔ iOS-ONLY, AND IT WILL STAY THAT WAY. Sign in with Apple exists here
        /// because App Store Review Guideline 4.8 requires it beside the Google and
        /// Microsoft doors; Play has no equivalent rule and the Android client
        /// offers no such button, so this is the one identifier in this enum that
        /// deliberately has no Kotlin twin.
        static let apple = "district-sign-in-apple"
        /// The authenticator-code step after Sign in with Apple. ⚠️ Apple-only like the
        /// button above, so these have no Kotlin twin either.
        static let mfaSheet = "district-sign-in-mfa"
        static let mfaCode = "district-sign-in-mfa-code"
        static let mfaVerify = "district-sign-in-mfa-verify"
        static let mfaKind = "district-sign-in-mfa-kind"
        static let mfaMessage = "district-sign-in-mfa-message"
        static let mfaCancel = "district-sign-in-mfa-cancel"
    }

    /// ⚠️ NOT Android's `district-workspace-settings-*`, which is the SETTINGS screen.
    /// These name the workspace header and switcher, which iOS surfaces separately.
    enum Workspace {
        static let header = "district-workspace-header"
        static let picker = "district-workspace-picker"
        static let rowBase = "district-workspace-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }
    }

    /// The console home. Mirrors Android's `OVERVIEW_ROOT_DESCRIPTION`.
    ///
    /// ⚠️ DISTINCT FROM ``Nav/overview``, which tags the TAB's content root rather
    /// than the screen. That is enough to answer "which tab is showing" and not enough
    /// to answer "did the overview render", which is the question a smoke run asks.
    enum Overview {
        static let root = "district-overview-root"
        /// The owner mid-setup's "Open setup" button. Present only for that owner.
        static let finishSetup = "district-overview-finish-setup"
    }

    enum Contacts {
        static let root = "district-contacts-root"
        static let add = "district-contacts-add"
        static let rowBase = "district-contact-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }

        static let detailRoot = "district-contact-detail-root"
        /// The DGI dossier section inside a contact's detail screen. Mirrors Android's
        /// `CONTACT_DETAIL_DOSSIER_DESCRIPTION`.
        ///
        /// ⛔ NOT THE SAME ASSERTION AS ``detailRoot``. The detail screen renders for
        /// every contact; the dossier is the enrichment payload and is absent on a
        /// contact that has never been enriched. A test that asserts only the root
        /// passes on a contact with no dossier at all.
        static let dossier = "district-contact-detail-dossier"
    }

    enum Calls {
        static let root = "district-call-log-root"
        static let rowBase = "district-call-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }

        static let detailRoot = "district-call-detail-root"
        static let transcript = "district-call-detail-transcript"
        static let showTranscript = "district-call-detail-show-transcript"
    }

    enum Inbox {
        static let root = "district-inbox-root"
        static let rowBase = "district-inbox-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }

        /// ⛔ A FORBIDDEN SURFACE. See `UITestApp.ForbiddenSurfaces`.
        static let send = "district-inbox-send"
    }

    enum Dialer {
        static let root = "district-dialer-root"
        static let entry = "district-dialer-entry"
        static let refusal = "district-dialer-refusal"
        /// ⛔ A FORBIDDEN SURFACE: tapping it places a real, billed call.
        static let call = "district-dialer-call"
        /// iOS-first. Android addresses `district-dialer-field` and types into it;
        /// driving the keys is what lets a test prove the keypad itself.
        static func key(_ digit: String) -> String {
            "district-dialer-key-\(digit)"
        }
    }

    enum Billing {
        static let root = "district-billing-root"
        static let status = "district-billing-status"
        static let plan = "district-billing-plan"
        static let readOnly = "district-billing-read-only"
    }

    enum Marketplace {
        static let root = "district-marketplace-root"
        static let owned = "district-marketplace-owned"
        static let rowBase = "district-marketplace-number-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }

        /// ⛔ A FORBIDDEN SURFACE: releasing a number is irreversible and billed.
        static let release = "district-marketplace-release"
    }

    /// iOS-first throughout: Android has no equivalent account screen.
    enum Account {
        static let root = "district-account-root"
        static let notifications = "district-account-notifications"
        static let devices = "district-account-devices"
        /// ⛔ A FORBIDDEN SURFACE: ends the session the run depends on.
        static let signOut = "district-account-sign-out"
        /// ⛔ A FORBIDDEN SURFACE: starts an irreversible deletion.
        static let delete = "district-account-delete"
    }

    /// The workspace-settings hub. Mirrors Android's
    /// `WORKSPACE_SETTINGS_ROOT_DESCRIPTION`.
    ///
    /// ⚠️ NOT Android's `SETTINGS_ROOT_DESCRIPTION`, which is that client's ACCOUNT
    /// surface and corresponds to ``Account/root`` here. The two clients split the
    /// same material differently, iOS puts sign-out on the Account tab and keeps the
    /// workspace forms behind a separate hub, so a cross-platform test plan has to
    /// name the SCREEN rather than assume the word "settings" means one thing.
    enum Settings {
        static let hubRoot = "district-workspace-settings-root"
    }

    /// The persona form's controls.
    ///
    /// ⛔ EVERY PICKER HERE WRITES A VALUE THE SAVE ROUTE COERCES RATHER THAN REFUSES,
    /// so a test that drives the wrong one still passes and the damage is a persona
    /// nobody chose. Naming them individually is what lets a test say which control it
    /// moved. ⚠️ The engine, voice and tuning controls moved to ``VoiceStudio``.
    enum Persona {
        static let root = "district-persona-root"
        static let name = "district-persona-name"
        static let greeting = "district-persona-greeting"
        static let personality = "district-persona-personality"
        static let language = "district-persona-language"
        static let answerLength = "district-persona-answer-length"
        /// ⚠️ THE RETRY IN THE PANEL SHOWN INSTEAD OF THE PICKERS when the catalogue did
        /// not load. It re-reads the catalogue ALONE, so a test that presses it is not
        /// asserting anything about the three text fields above it.
        static let engineRetry = "district-persona-engine-retry"
        static let save = "district-persona-save"
        /// ⛔ A FORBIDDEN SURFACE: pressing it places a real, billed call to the agent.
        static let preview = "district-persona-preview"
    }

    /// The persona preview sheet.
    ///
    /// ⛔ BOTH CONTROLS ARE FORBIDDEN SURFACES FOR AN AUTOMATED RUN. Starting one spends
    /// a rate-limit slot and starts a billed session; the End button is listed so a test
    /// that somehow reaches a live session can be written to stop it.
    enum PersonaPreview {
        static let root = "district-persona-preview-root"
        static let start = "district-persona-preview-start"
        static let end = "district-persona-preview-end"
        static let status = "district-persona-preview-status"
        static let level = "district-persona-preview-level"
    }

    /// The dynamic-persona rule editor, iOS-first.
    enum Routing {
        static let root = "district-routing-root"
        static let add = "district-routing-add"
        /// ⛔ A FORBIDDEN SURFACE: the save REPLACES every stored rule.
        static let save = "district-routing-save"
        static let rowBase = "district-routing-row"
        static func row(_ id: Int) -> String {
            A11yID.row(rowBase, String(id))
        }

        static func field(_ id: Int) -> String {
            "\(row(id))-field"
        }

        static func ruleOperator(_ id: Int) -> String {
            "\(row(id))-operator"
        }

        static func value(_ id: Int) -> String {
            "\(row(id))-value"
        }

        static func voice(_ id: Int) -> String {
            "\(row(id))-voice"
        }

        static func model(_ id: Int) -> String {
            "\(row(id))-model"
        }

        static func instruction(_ id: Int) -> String {
            "\(row(id))-instruction"
        }

        static func remove(_ id: Int) -> String {
            "\(row(id))-remove"
        }
    }

    enum Rooms {
        static let root = "district-rooms-root"
        static let meetingRowBase = "district-rooms-meeting-row"
        static func meeting(_ id: String) -> String {
            A11yID.row(meetingRowBase, id)
        }
    }

    /// The scheduling hub, its nine sections and the two drill-downs.
    ///
    /// ⚠️ iOS-FIRST THROUGHOUT: Android has no scheduling surface at all, so nothing here
    /// is ported and the names are chosen to match the WEB's section paths (`event-types`,
    /// not `eventTypes`) so a cross-client test plan can address the same screen by the
    /// same word on both.
    enum Scheduling {
        static let root = "district-scheduling-root"
        static let notice = "district-scheduling-notice"
        /// ⚠️ THE HAND-OFF INTO THE BROWSER. It kept this name when "Open scheduler" was
        /// deleted beside it, because a test pressing "the way out of the app" should not
        /// have to change its identifier for a relabelling.
        static let open = "district-scheduling-open"
        static let link = "district-scheduling-link"
        /// ⛔ A FORBIDDEN SURFACE: it provisions a tenancy and writes a DNS record.
        static let enable = "district-scheduling-enable"

        /// One row of the hub's section list, suffixed with the section's own path
        /// segment so a test addresses `district-scheduling-section-bookings` rather than
        /// an index. See the ⛔ at the top of ``A11yID``.
        static let sectionRowBase = "district-scheduling-section"
        static func section(_ segment: String) -> String {
            A11yID.row(sectionRowBase, segment)
        }

        static let overviewRoot = "district-scheduling-overview-root"
        static let eventTypesRoot = "district-scheduling-event-types-root"
        static let eventTypeDetailRoot = "district-scheduling-event-type-root"
        static let hoursRoot = "district-scheduling-hours-root"
        static let bookingsRoot = "district-scheduling-bookings-root"
        static let bookingDetailRoot = "district-scheduling-booking-root"
        static let calendarRoot = "district-scheduling-calendar-root"
        static let teamRoot = "district-scheduling-team-root"
        static let settingsRoot = "district-scheduling-settings-root"
        static let developerRoot = "district-scheduling-developer-root"

        static let eventTypeRowBase = "district-scheduling-event-type-row"
        static func eventTypeRow(_ slug: String) -> String {
            A11yID.row(eventTypeRowBase, slug)
        }

        static let bookingRowBase = "district-scheduling-booking-row"
        static func bookingRow(_ id: String) -> String {
            A11yID.row(bookingRowBase, id)
        }

        /// The bookings filter control, and the two tab strips.
        static let bookingsView = "district-scheduling-bookings-view"
        static let settingsTabBase = "district-scheduling-settings-tab"
        static func settingsTab(_ id: String) -> String {
            A11yID.row(settingsTabBase, id)
        }

        static let developerTabBase = "district-scheduling-developer-tab"
        static func developerTab(_ id: String) -> String {
            A11yID.row(developerTabBase, id)
        }
    }
}
