import DistrictData
import DistrictL10n
import DistrictModel
import Foundation
import Observation

/// Two-step verification on the signed-in account: whether it is on, turning it on with an
/// authenticator app, and turning it off.
///
/// ⛔ A FRESH `2fa-change` RE-AUTHENTICATION BEFORE EVERY CHANGE, AND THE SERVICE ENFORCES IT.
/// A fresh sign-in at the person's provider, or their password and (when two-step verification
/// is already on) its code, earns a proof bound to this installation and this action
/// (``NativeReauthRepository``); `enroll` checks it, `confirm` and `disable` spend it. No
/// passkeys (Sean, 2026-11-08: "Yes, SSO or password"); two-step accounts re-authenticate with
/// their code (2026-11-07). The re-authentication is the one ``DeleteAccountModel`` runs, with
/// its wording.
///
/// ⛔ THE SECRET, ITS URI, ITS QR CODE AND THE RECOVERY CODES ARE CREDENTIALS. They live in this
/// model only, are never logged (the core's DTOs redact their descriptions, and nothing here
/// prints them), and ``leave()`` drops them when the screen closes.
///
/// ⛔ SINGLE-FLIGHT ACROSS EVERY CALL. ``busy`` is checked and set before the first suspension,
/// on the main actor, so two taps dispatched before a re-render send one request. A second
/// password attempt would cost one of the few a minute the service allows, and a second
/// confirm would answer `MFA_NOT_PENDING` over codes already shown.
@MainActor
@Observable
final class TwoStepModel {
    /// What a re-authentication is for.
    enum Intent: Equatable {
        case turnOn
        case turnOff
    }

    enum Step: Equatable {
        /// The first read of the status.
        case loading
        /// The status could not be read; ``failure`` says why, and Retry reads it again.
        case loadFailed
        /// On or off, since when, and how many recovery codes are left.
        case overview
        /// The ways to confirm it is you, before the change.
        case reauth(Intent)
        /// The password, and once the service asks for it, the authenticator code.
        case password(Intent, needsCode: Bool)
        /// The new secret as a QR code and a key, and the code that proves the app has it.
        case scan
        /// The recovery codes, shown this once.
        case recoveryCodes
    }

    /// A new secret, held only while ``Step/scan`` is on screen.
    struct Enrollment: Equatable {
        let secret: String
        let otpauthURI: String
        /// The PNG inside the service's `data:` URL, or nil when it is not one.
        let qrPNG: Data?
    }

    typealias SSO = @MainActor (ReauthProvider) async -> SSOReauthOutcome

    private(set) var step: Step = .loading
    private(set) var busy = false
    private(set) var status: MfaStatusResponse?
    /// A refusal or a failure, as one sentence saying what to do.
    private(set) var failure: String?
    /// What the last change did ("Two-step verification is on."), until the next action.
    private(set) var notice: String?
    private(set) var enrollment: Enrollment?
    private(set) var recoveryCodes: [String] = []

    var password = ""
    var code = ""
    /// The authenticator's code that confirms enrolment (``Step/scan``).
    var totp = ""

    private let settings: TwoStepSettingsRepository
    private let reauth: NativeReauthRepository
    private let sso: SSO

    init(settings: TwoStepSettingsRepository, reauth: NativeReauthRepository, sso: @escaping SSO) {
        self.settings = settings
        self.reauth = reauth
        self.sso = sso
    }

    /// ⚠️ THE STATUS'S OWN FLAG IS THE WEBSITE'S RULE, NOT THE APP'S. `canDisable` is false for
    /// an account with no password because a browser re-proves the password to turn it off; an
    /// app's `2fa-change` proof stands in for it, so such an account turns it off here after a
    /// fresh sign-in at its provider (the core's ``MfaStatusResponse/canDisable``).
    var signsInWithoutPassword: Bool {
        status.map { $0.enrolled && !$0.canDisable } ?? false
    }

    var canSubmitPassword: Bool {
        guard !busy, !password.isEmpty, case let .password(_, needsCode) = step else { return false }
        return !needsCode || !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canConfirm: Bool {
        !busy && step == .scan && !totp.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await read()
    }

    // ── Steps ───────────────────────────────────────────────────────────────

    func begin(_ intent: Intent) {
        guard !busy, step == .overview, let status else { return }
        // ⚠️ THE STATUS DECIDES WHICH CHANGE IS OFFERED: a stale button never starts the other.
        guard status.enrolled == (intent == .turnOff) else { return }
        failure = nil
        notice = nil
        step = .reauth(intent)
    }

    func usePassword() {
        guard !busy, case let .reauth(intent) = step else { return }
        failure = nil
        clearReauthFields()
        step = .password(intent, needsCode: false)
    }

    /// One step back: from the password to the ways to confirm, from there to the overview,
    /// and from the new secret to the overview (the unconfirmed secret is dropped).
    func back() {
        guard !busy else { return }
        failure = nil
        clearReauthFields()
        switch step {
        case let .password(intent, _):
            step = .reauth(intent)
        case .reauth, .scan:
            dropEnrollment()
            step = .overview
        case .loading, .loadFailed, .overview, .recoveryCodes:
            break
        }
    }

    func reauthenticate(with provider: ReauthProvider) async {
        guard !busy, case let .reauth(intent) = step else { return }
        busy = true
        failure = nil
        defer { busy = false }

        switch await sso(provider) {
        case .proved:
            await change(intent)
        case .cancelled:
            break
        case .stateMismatch, .noCode:
            failure = DeleteAccountCopy.errorSignInNotVerified
        case .couldNotOpen:
            failure = DeleteAccountCopy.errorSheetDidNotOpen
        case let .refused(error):
            failure = DeleteAccountModel.reauthFailure(error, sso: true).message
        }
    }

    func submitPassword() async {
        guard canSubmitPassword, case let .password(intent, needsCode) = step else { return }
        busy = true
        failure = nil
        defer { busy = false }

        let typedCode = needsCode ? code.trimmingCharacters(in: .whitespaces) : nil
        let result = await reauth.reauthenticate(action: .twoFactorChange, password: password, code: typedCode)
        password = ""
        switch result {
        case .success:
            code = ""
            await change(intent)
        case let .failure(error) where error.code == "MFA_REQUIRED":
            // ⚠️ NOT A FAILURE: two-step verification is on, and its code goes with the password.
            step = .password(intent, needsCode: true)
        case let .failure(error) where error.code == "NO_PASSWORD_SET":
            step = .reauth(intent)
            failure = DeleteAccountCopy.errorNoPassword
        case let .failure(error):
            if error.code == "mfa_code_invalid" {
                code = ""
            }
            failure = DeleteAccountModel.reauthFailure(error, sso: false).message
        }
    }

    /// Turns the factor on with the authenticator's code, and shows the recovery codes.
    func confirm() async {
        guard canConfirm else { return }
        busy = true
        failure = nil
        defer { busy = false }

        let typed = totp.trimmingCharacters(in: .whitespaces)
        switch await settings.confirm(totp: typed) {
        case let .success(confirmed):
            totp = ""
            dropEnrollment()
            recoveryCodes = confirmed.backupCodes
            // ⚠️ ON NOW, WHATEVER THE NEXT READ SAYS: a read that fails after this must not show it off.
            status = MfaStatusResponse(
                enrolled: true,
                enrolledAt: Self.now(),
                backupCodesRemaining: confirmed.backupCodes.count,
                canDisable: status?.canDisable ?? true
            )
            step = .recoveryCodes
        case let .failure(error) where error.code == "mfa_code_invalid":
            totp = ""
            failure = Self.sentence(error)
        case let .failure(error):
            totp = ""
            await refused(error, during: .confirm)
        }
    }

    /// The recovery codes are saved: drop them and read the status again.
    func finishRecoveryCodes() async {
        guard !busy, step == .recoveryCodes else { return }
        busy = true
        defer { busy = false }
        recoveryCodes = []
        notice = TwoStepCopy.turnedOn
        await read()
    }

    /// ⛔ THE SCREEN IS CLOSING: nothing secret outlives it. An unconfirmed secret stays pending
    /// on the service, which replaces it on the next enrolment.
    func leave() {
        dropEnrollment()
        recoveryCodes = []
        totp = ""
        clearReauthFields()
    }

    // ── Changes ─────────────────────────────────────────────────────────────

    enum Change: Equatable {
        case enroll
        case confirm
        case disable
    }

    /// The proof stands: make the change it was earned for. Runs inside the caller's busy window.
    private func change(_ intent: Intent) async {
        switch intent {
        case .turnOn:
            switch await settings.enroll() {
            case let .success(response):
                enrollment = Enrollment(
                    secret: response.secret,
                    otpauthURI: response.otpauthUri,
                    qrPNG: Self.png(fromDataURL: response.qrDataUrl)
                )
                totp = ""
                step = .scan
            case let .failure(error):
                await refused(error, during: .enroll)
            }
        case .turnOff:
            switch await settings.disable() {
            case .success:
                notice = TwoStepCopy.turnedOff
                // ⚠️ OFF NOW, WHATEVER THE NEXT READ SAYS, as after a confirm.
                status = MfaStatusResponse(
                    enrolled: false,
                    enrolledAt: nil,
                    backupCodesRemaining: 0,
                    canDisable: status?.canDisable ?? true
                )
                await read()
            case let .failure(error):
                await refused(error, during: .disable)
            }
        }
    }

    /// Where a refused change leaves the screen, and the sentence for it.
    private func refused(_ error: ApiError, during change: Change) async {
        let outcome = Self.refusal(error, during: change)
        failure = outcome.message
        switch outcome.next {
        case .stay:
            break
        case let .reauth(intent):
            dropEnrollment()
            step = .reauth(intent)
        case .reread:
            dropEnrollment()
            let message = failure
            await read()
            // ⚠️ THE READ'S OWN FAILURE, IF ANY, IS THE MORE URGENT ONE; otherwise the refusal stays.
            if step == .overview {
                failure = message
            }
        }
    }

    enum Next: Equatable {
        /// Stay on this step and try again.
        case stay
        /// The proof is gone: confirm it is you again, for this change.
        case reauth(Intent)
        /// What is on is no longer known, or no longer what this screen showed: read it again.
        case reread
    }

    /// ⛔ BRANCHED ON THE CODE, NEVER ON THE MESSAGE. A code the core's catalog has reads the
    /// catalog's sentence in either language (``ApiErrorText``); one it lacks reads the
    /// service's own (``ApiError/localizedMessage``), and only then a fallback.
    static func refusal(_ error: ApiError, during change: Change) -> (message: String, next: Next) {
        let intent: Intent = change == .disable ? .turnOff : .turnOn
        switch (error, error.code) {
        case (.transport, _):
            // ⛔ A CONFIRM OR A DISABLE LOST IN TRANSPORT MAY HAVE HAPPENED: never claim either way.
            switch change {
            case .enroll: return (TwoStepCopy.errorOfflineNothingChanged, .stay)
            case .confirm: return (TwoStepCopy.errorOutcomeUnknownOn, .reread)
            case .disable: return (TwoStepCopy.errorOutcomeUnknownOff, .reread)
            }
        case (.decoding, _):
            switch change {
            case .enroll: return (TwoStepCopy.errorTryAgain, .stay)
            case .confirm: return (TwoStepCopy.errorOutcomeUnknownOn, .reread)
            case .disable: return (TwoStepCopy.errorOutcomeUnknownOff, .reread)
            }
        case (_, "reauth_required"):
            // ⚠️ A NEW PROOF MEANS A NEW SECRET for turning on: the old one is dropped.
            return (TwoStepCopy.errorProofExpired, .reauth(intent))
        case (_, "MFA_ALREADY_ENABLED"), (_, "MFA_NOT_STARTED"), (_, "MFA_NOT_PENDING"):
            return (sentence(error), .reread)
        case (_, "server_error"):
            return (TwoStepCopy.errorTryAgain, .stay)
        case (.http(401, _, _), _):
            return (SessionCopy.sessionHasEndedPlease, .stay)
        default:
            return (sentence(error), .stay)
        }
    }

    /// The catalog's sentence for the code, else the service's, else a fallback.
    static func sentence(_ error: ApiError) -> String {
        error.code.flatMap { ApiErrorText.sentence(for: $0) }
            ?? error.localizedMessage
            ?? TwoStepCopy.errorTryAgain
    }

    /// The PNG inside `data:image/png;base64,...`, or nil for anything else.
    static func png(fromDataURL url: String) -> Data? {
        let prefix = "data:image/png;base64,"
        guard url.hasPrefix(prefix) else { return nil }
        return Data(base64Encoded: String(url.dropFirst(prefix.count)), options: .ignoreUnknownCharacters)
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

    /// The status, into ``status`` and the overview, or the reason it could not be read.
    private func read() async {
        switch await settings.status() {
        case let .success(read):
            status = read
            failure = nil
            step = .overview
        case let .failure(error):
            failure = Self.loadFailure(error)
            // ⚠️ A STATUS ALREADY SHOWN STAYS ON SCREEN under the failure; only a first read fails
            // to the Retry step.
            step = status == nil ? .loadFailed : .overview
        }
    }

    static func loadFailure(_ error: ApiError) -> String {
        switch (error, error.code) {
        case (.transport, _): TwoStepCopy.errorOfflineLoad
        case (.http(401, _, _), _): SessionCopy.sessionHasEndedPlease
        case (.decoding, _), (_, "server_error"): TwoStepCopy.errorLoad
        default: error.code.flatMap { ApiErrorText.sentence(for: $0) } ?? TwoStepCopy.errorLoad
        }
    }

    /// This moment as the service writes an instant (ISO-8601 UTC with milliseconds).
    private static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func dropEnrollment() {
        enrollment = nil
        totp = ""
    }

    private func clearReauthFields() {
        password = ""
        code = ""
    }
}

/// ⛔ REDACTED FOR `print`, `dump` AND EVERY OTHER MIRROR-BASED PRINT, as the core's
/// ``MfaEnrollResponse``: all three fields are the secret.
extension TwoStepModel.Enrollment: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: ["secret": "<redacted>", "otpauthURI": "<redacted>", "qrPNG": "<redacted>"])
    }

    var description: String {
        "Enrollment(secret: <redacted>, otpauthURI: <redacted>, qrPNG: <redacted>)"
    }

    var debugDescription: String {
        description
    }
}

/// ⛔ THE MODEL HOLDS THE SECRET, THE RECOVERY CODES AND A TYPED PASSWORD: a `dump` of it shows
/// none of them.
extension TwoStepModel: CustomReflectable {
    nonisolated var customMirror: Mirror {
        Mirror(self, children: ["contents": "<redacted>"])
    }
}
