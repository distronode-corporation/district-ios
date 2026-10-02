import DistrictData
import DistrictModel
import Foundation
import Observation

/// The four ways to reach a CalDAV server.
///
/// ⚠️ ONLY TWO ARE PRESETS AT THE FAR END. `caldav.Presets` holds `icloud` and
/// `fastmail` and nothing else; Nextcloud is a server URL like any other, and it is
/// listed separately only because a host thinks of it as a product rather than as
/// "other".
enum SchedulingCaldavPresetC: String, CaseIterable, Identifiable {
    case icloud
    case fastmail
    case nextcloud
    case custom

    var id: String {
        rawValue
    }

    /// Whether this choice asks the host for a server address.
    var needsServerURL: Bool {
        self == .nextcloud || self == .custom
    }

    var label: String {
        switch self {
        case .icloud: SchedulingWriteCopyC.caldavPresetICloud
        case .fastmail: SchedulingWriteCopyC.caldavPresetFastmail
        case .nextcloud: SchedulingWriteCopyC.caldavPresetNextcloud
        case .custom: SchedulingWriteCopyC.caldavPresetCustom
        }
    }

    var note: String {
        switch self {
        case .icloud: SchedulingWriteCopyC.caldavPresetICloudNote
        case .fastmail: SchedulingWriteCopyC.caldavPresetFastmailNote
        case .nextcloud: SchedulingWriteCopyC.caldavPresetNextcloudNote
        case .custom: SchedulingWriteCopyC.caldavPresetCustomNote
        }
    }
}

/// Which box a refusal belongs to, so the form can mark it.
enum SchedulingCaldavFieldC: Equatable {
    case serverURL
    case username
    case appPassword
}

/// The `calendar.caldav.connect` body, once the form has been checked.
///
/// ⛔ A TYPE RATHER THAN A TUPLE, AND NOT ONLY BECAUSE `large_tuple` REFUSES FOUR
/// MEMBERS. Two of these four are Optionals that must be EXACTLY ONE-OF — the fork
/// prefers `server_url` when it is non-empty and only then falls back to the preset
/// table — and a positional tuple makes that invariant invisible at the call site.
///
/// ⛔ AND IT IS NEVER STORED. It is built inside `connect()`, spent on one request
/// and dropped, because `appPassword` is a live credential.
struct SchedulingCaldavParamsC {
    let preset: String?
    let serverURL: String?
    let username: String
    let appPassword: String
}

/// What is wrong with a CalDAV server URL, said to the customer.
///
/// ⚠️ NONE OF THIS IS AN SSRF BOUNDARY and it must not be described as one. The
/// fork's CalDAV client is what dials, and the private-network block belongs
/// there; a hostname that resolves to 10.x defeats every syntactic check here and
/// always will. What this buys is that the obvious probe is refused with an
/// explanation instead of a ten-second timeout, and that an app password cannot be
/// aimed at an `http://` address.
enum SchedulingCaldavURLCheckC {
    static func issue(_ value: String) -> String? {
        guard let parsed = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host, !host.isEmpty
        else {
            return SchedulingWriteCopyC.caldavServerUrlNotAUrl
        }
        guard scheme == "https" else { return SchedulingWriteCopyC.caldavServerUrlNotHttps }
        guard !isIPLiteralHost(host) else { return SchedulingWriteCopyC.caldavServerUrlIsIp }
        return nil
    }

    /// Whether this host names a machine rather than a name.
    ///
    /// ⛔ THE ALL-DIGITS CASE IS NOT PEDANTRY. `https://2130706433/` is 127.0.0.1 in
    /// decimal and Go's `net.Dial` accepts it, so a check that only knew the dotted
    /// quad would refuse the obvious spelling and pass the one an attacker would
    /// actually use. `0x7f000001` is the same trick in hex; both are caught by
    /// refusing a host with no letters in it at all.
    ///
    /// ⚠️ `URLComponents.host` KEEPS THE BRACKETS on an IPv6 literal, which is what
    /// makes that case a one-character test rather than an address parser.
    static func isIPLiteralHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return false }
        if lower.hasPrefix("[") {
            return true
        }
        if lower == "localhost" || lower.hasSuffix(".localhost") {
            return true
        }
        if lower.allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }
        guard lower.hasPrefix("0x") else { return false }
        let digits = lower.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
    }
}

/// Link a CalDAV account by server address, username and app password.
///
/// ⛔ THE APP PASSWORD IS TYPED, SENT ONCE AND FORGOTTEN. It is not logged, not
/// persisted, not echoed back and not carried into any message this model
/// produces: `failure` is built from the refusal's CODE, and the one sentence a
/// refused credential earns is a fixed string that quotes nothing. On success every
/// box including the password is cleared, so a sheet that stays mounted holds no
/// credential.
///
/// ⛔ AND IT IS NOT TRIMMED. It is bytes a provider generated; a leading or trailing
/// space may be one of them, and trimming turns a correct credential into "could
/// not connect". The username and the server URL are trimmed, because both are
/// things a person typed.
///
/// ⛔ EXACTLY ONE OF `preset` AND `server_url` IS SENT. The fork prefers
/// `server_url` when it is non-empty and only then falls back to the preset table,
/// so sending both would silently ignore whichever the host actually chose.
/// `JSONValue.object(_:)` drops the nil one, which is what makes passing nil the
/// right way to say "not this one".
@MainActor
@Observable
final class SchedulingCaldavConnectModel {
    var preset: SchedulingCaldavPresetC = .icloud
    var serverURL = ""
    var username = ""
    /// ⛔ THE CREDENTIAL. See the type note: nothing reads it except `connect()`.
    var appPassword = ""

    private(set) var erroredField: SchedulingCaldavFieldC?
    private(set) var fieldMessage: String?
    private(set) var failure: FailureText?
    private(set) var busy = false
    /// The address the server RESOLVED, not the username that was sent. ⛔ CalDAV
    /// usernames are frequently not email addresses, and the fork answers the
    /// address it discovered on the principal.
    private(set) var connectedAccountEmail: String?

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    private let onChanged: () -> Void

    init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.onChanged = onChanged
    }

    var needsServerURL: Bool {
        preset.needsServerURL
    }

    var canSubmit: Bool {
        !busy
    }

    func connect() async {
        guard !busy else { return }
        guard let params = validated() else { return }
        erroredField = nil
        fieldMessage = nil
        failure = nil
        busy = true
        do {
            let connection = try await repository.connectCaldav(
                workspaceId: workspaceId,
                username: params.username,
                appPassword: params.appPassword,
                preset: params.preset,
                serverUrl: params.serverURL
            )
            busy = false
            clearCredentials()
            connectedAccountEmail = connection.accountEmail
            onChanged()
        } catch {
            busy = false
            failure = Self.connectFailure(error)
        }
    }

    func dismissFailure() {
        failure = nil
    }

    func dismissConfirmation() {
        connectedAccountEmail = nil
    }

    // MARK: - Validation

    /// The connect body, or the first thing wrong with the form.
    ///
    /// ⚠️ THE ORDER IS THE BROWSER'S: server URL, then username, then password. It
    /// matters because only one message is shown at a time, and a person filling
    /// the form top to bottom should be told about the box they are in rather than
    /// the last one.
    private func validated() -> SchedulingCaldavParamsC? {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if needsServerURL {
            guard !trimmedServer.isEmpty else {
                return refuse(.serverURL, SchedulingWriteCopyC.caldavServerUrlMissing)
            }
            if let issue = SchedulingCaldavURLCheckC.issue(trimmedServer) {
                return refuse(.serverURL, issue)
            }
        }
        guard !trimmedUser.isEmpty else {
            return refuse(.username, SchedulingWriteCopyC.caldavUsernameMissing)
        }
        guard !appPassword.isEmpty else {
            return refuse(.appPassword, SchedulingWriteCopyC.caldavPasswordMissing)
        }
        return SchedulingCaldavParamsC(
            preset: needsServerURL ? nil : preset.rawValue,
            serverURL: needsServerURL ? trimmedServer : nil,
            username: trimmedUser,
            appPassword: appPassword
        )
    }

    private func refuse(_ field: SchedulingCaldavFieldC, _ message: String) -> SchedulingCaldavParamsC? {
        erroredField = field
        fieldMessage = message
        failure = nil
        return nil
    }

    /// ⛔ ASSIGNED EMPTY RATHER THAN LEFT ALONE, INCLUDING THE PASSWORD. The sheet
    /// may stay mounted behind a confirmation, and a credential on a live model is
    /// a credential in memory.
    private func clearCredentials() {
        appPassword = ""
        username = ""
        serverURL = ""
    }

    /// ⛔ THE FORK'S OWN 4xx TEXT IS NOT AVAILABLE AND MUST NOT BE INVENTED. A
    /// refused credential arrives as the generic `unknown`, so that one code gets
    /// the sentence naming the three things worth checking; everything else keeps
    /// the shared mapping, because "the booking system did not answer" and "you may
    /// view this but not change it" are still the right answers here.
    ///
    /// ⚠️ `decoding` IS EXCLUDED EVEN THOUGH IT COLLAPSES TO `unknown`. A response
    /// shape this build cannot read says nothing whatever about the server, the
    /// username or the password, and telling somebody to check all three would send
    /// them to re-type a credential that was almost certainly correct.
    private static func connectFailure(_ error: any Error) -> FailureText {
        let mapped = SchedulingFailureCopy.text(forAny: error)
        let admin = (error as? SchedulingAdminError) ?? .unknown
        if case .decoding = admin {
            return mapped
        }
        guard admin.uiCode == .unknown else { return mapped }
        return FailureText(message: SchedulingWriteCopyC.caldavRefused, action: .none)
    }
}
