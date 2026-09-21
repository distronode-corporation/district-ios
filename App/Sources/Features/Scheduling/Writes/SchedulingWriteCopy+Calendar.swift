import DistrictData
import Foundation

/// The calendar half of the write copy. Split from `+Developer.swift` for the
/// 500-line `file_length` ceiling that `swiftlint --strict` promotes to an error,
/// not for a boundary in the domain.
extension SchedulingWriteCopyC {
    // MARK: - Providers

    /// ⛔ THE LABEL COMES FROM ``SchedulingCalendarFormat/providerLabel(_:)`` AND
    /// IS NOT RESTATED HERE. The read screen already renders the library's
    /// four-entry table, so a second table would let one provider be worded two ways
    /// on the same screen the day the fork adds a fifth.
    static func connectProvider(_ provider: String) -> String {
        "Connect \(SchedulingCalendarFormat.providerLabel(provider))"
    }

    // MARK: - CalDAV

    static let caldavTitle = "Connect a CalDAV calendar"
    static let caldavPresetLabel = "Where the calendar lives"
    static let caldavServerUrlLabel = "Server URL"
    static let caldavServerUrlHint = "The base address of the CalDAV server."
    static let caldavUsernameLabel = "Username"
    static let caldavPasswordLabel = "App password"
    static let caldavPasswordHint = "An app-specific password from the provider, not the account password."
    static let caldavConnectAction = "Connect calendar"
    static let caldavConnecting = "Connecting…"
    static let caldavConnected = "Calendar connected"

    /// ⛔ NAMES THE ADDRESS THE SERVER RESOLVED, NOT THE USERNAME THAT WAS SENT.
    /// CalDAV usernames are frequently not email addresses, and echoing back the
    /// submitted one would label the connection with something the provider does
    /// not recognise.
    static func caldavConnectedTo(_ accountEmail: String) -> String {
        "\(caldavConnected): \(accountEmail)"
    }

    static let caldavServerUrlMissing = "Enter the server URL."
    static let caldavUsernameMissing = "Enter the username."
    static let caldavPasswordMissing = "Enter the app password."
    static let caldavServerUrlNotAUrl = "That does not look like a server address. It should start with https://"
    static let caldavServerUrlNotHttps =
        "The server address must start with https:// — an app password sent over http:// travels in the clear."
    static let caldavServerUrlIsIp = "Enter the server's hostname rather than an IP address."

    /// ⛔ THE FORK'S OWN 4xx TEXT NEVER REACHES THE SCREEN. The admin RPC answers
    /// a CODE and a status and deliberately not the remote message, so there is
    /// nothing more specific available — and the three things worth checking are
    /// named here instead.
    static let caldavRefused = "Could not connect. Check the server, username and app password."

    static let caldavPresetICloud = "iCloud"
    static let caldavPresetICloudNote = "Apple's calendar. Create an app-specific password at appleid.apple.com."
    static let caldavPresetFastmail = "Fastmail"
    static let caldavPresetFastmailNote = "Fastmail's calendar. Create an app password in Fastmail settings."
    static let caldavPresetNextcloud = "Nextcloud"
    static let caldavPresetNextcloudNote = "Your own Nextcloud server, at its DAV address."
    static let caldavPresetCustom = "Other server URL"
    static let caldavPresetCustomNote = "Any other CalDAV server."

    // MARK: - The calendars inside one account

    static let calendarsConflictsLabel = "Checked for conflicts"
    static let calendarsConflictsHint = "A booking is refused when it clashes with an event on a checked calendar."
    static let calendarsDestinationLabel = "Receives bookings"
    static let calendarsDestinationHint = "New bookings are written to this calendar."
    static let calendarsSaveAction = "Save changes"
    static let calendarsSaving = "Saving…"
    static let calendarsSaved = "Calendars saved"
    static let calendarsLoading = "Loading calendars…"

    static func calendarsTitle(_ accountEmail: String) -> String {
        "Calendars in \(accountEmail)"
    }

    // MARK: - Disconnecting

    static let disconnectAction = "Disconnect"
    static let disconnectKeep = "Keep it connected"
    static let disconnectConfirm = "Bookings stop syncing to it. Existing events stay."
    static let disconnected = "Calendar disconnected"
    /// ⛔ `calendar.connections.delete` CAN REMOVE THE DESTINATION CONNECTION AND
    /// THE CATALOG DOES NOT REFUSE IT. A tenancy left with no destination writes
    /// new bookings nowhere, so the screen that offers this has to say so once the
    /// re-read comes back.
    static let disconnectedLastDestination =
        "No calendar receives new bookings now. Connect one, or choose a calendar in another account."

    static func disconnectPrompt(_ accountEmail: String) -> String {
        "Disconnect \(accountEmail)?"
    }

    // MARK: - The OAuth round trip

    /// ⚠️ SAID BEFORE THE BROWSER OPENS, because the consent screen is the
    /// provider's own page and the app has nothing to show while it is up.
    static let connectHandOffNote = "Finish in the browser, then come back — this page re-reads itself."
    static let connectNotConfigured = "Calendar connections are not set up on this scheduler yet."
    static let connectNotReadyYet = "Scheduling is still being set up for this workspace. Try again shortly."
}
