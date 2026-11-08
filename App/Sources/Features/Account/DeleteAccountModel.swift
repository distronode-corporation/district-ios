import DistrictData
import DistrictModel
import Foundation
import Observation

/// Deleting the signed-in account from the app (App Store Guideline 5.1.1(v)).
///
/// ⛔ THREE STEPS, AND THE SERVICE ENFORCES EVERY ONE OF THEM. A fresh re-authentication (a
/// fresh sign-in at the person's provider, or their password and, with two-step verification,
/// its code) earns a proof bound to this installation and this one action; the typed email then
/// spends it (`NativeReauthRepository`). Nothing here decides who may delete: a workspace owner,
/// a refused subscription cancellation or any other block is the service's answer, shown as it
/// comes (Sean, 2026-11-07: "Fresh SSO/passkey re-auth", and two-step accounts "Allow, with
/// re-auth").
///
/// ⛔ SINGLE-FLIGHT ACROSS ALL THREE CALLS. ``busy`` is checked and set before the first
/// suspension, on the main actor, so two taps dispatched before a re-render send one request.
/// A second delete would only be refused (the proof is single-use), but a second password
/// attempt costs one of the three a minute the service allows.
///
/// ⚠️ THE PASSWORD IS NOT KEPT. It is cleared after every attempt, and the typed email after a
/// deletion; the model holds nothing once the sheet closes.
@MainActor
@Observable
final class DeleteAccountModel {
    enum Step: Equatable {
        /// What is deleted and kept, and the ways to confirm it is you.
        case explain
        /// The password, and once the service asks for it, the authenticator code.
        case password(needsCode: Bool)
        /// The proof stands: the typed email and the final button.
        case confirm
    }

    /// A refusal: what went wrong, and what to do, as one sentence (or a headline and a detail).
    struct Failure: Equatable {
        let title: String?
        let message: String
    }

    typealias SSO = @MainActor (ReauthProvider) async -> SSOReauthOutcome
    typealias Deleted = @MainActor (_ externalErasurePending: Bool) async -> Void

    private(set) var step: Step = .explain
    private(set) var busy = false
    private(set) var failure: Failure?

    var password = ""
    var code = ""
    var confirmation = ""

    private let repository: NativeReauthRepository
    private let sso: SSO
    private let deleted: Deleted

    init(repository: NativeReauthRepository, sso: @escaping SSO, deleted: @escaping Deleted) {
        self.repository = repository
        self.sso = sso
        self.deleted = deleted
    }

    var canSubmitPassword: Bool {
        guard !busy, !password.isEmpty else { return false }
        guard case .password(needsCode: true) = step else { return true }
        return !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canDelete: Bool {
        !busy && step == .confirm && !confirmation.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // ── Steps ───────────────────────────────────────────────────────────────

    func usePassword() {
        guard !busy else { return }
        failure = nil
        password = ""
        code = ""
        step = .password(needsCode: false)
    }

    func back() {
        guard !busy else { return }
        failure = nil
        password = ""
        code = ""
        step = .explain
    }

    func reauthenticate(with provider: ReauthProvider) async {
        guard !busy, step == .explain else { return }
        busy = true
        failure = nil
        defer { busy = false }

        switch await sso(provider) {
        case .proved:
            step = .confirm
        case .cancelled:
            break
        case .stateMismatch, .noCode:
            failure = Failure(title: nil, message: DeleteAccountCopy.errorSignInNotVerified)
        case .couldNotOpen:
            failure = Failure(title: nil, message: DeleteAccountCopy.errorSheetDidNotOpen)
        case let .refused(error):
            failure = Self.reauthFailure(error, sso: true)
        }
    }

    func submitPassword() async {
        guard canSubmitPassword, case let .password(needsCode) = step else { return }
        busy = true
        failure = nil
        defer { busy = false }

        let typedCode = needsCode ? code.trimmingCharacters(in: .whitespaces) : nil
        let result = await repository.reauthenticate(action: .deleteAccount, password: password, code: typedCode)
        password = ""
        switch result {
        case .success:
            code = ""
            step = .confirm
        case let .failure(error) where error.code == "MFA_REQUIRED":
            // ⚠️ NOT A FAILURE: the account has two-step verification, and the code goes with
            // the password on the next try.
            step = .password(needsCode: true)
        case let .failure(error) where error.code == "NO_PASSWORD_SET":
            step = .explain
            failure = Failure(title: nil, message: DeleteAccountCopy.errorNoPassword)
        case let .failure(error):
            if error.code == "mfa_code_invalid" {
                code = ""
            }
            failure = Self.reauthFailure(error, sso: false)
        }
    }

    func delete() async {
        guard canDelete else { return }
        busy = true
        failure = nil
        defer { busy = false }

        switch await repository.deleteAccount(confirmation: confirmation.trimmingCharacters(in: .whitespaces)) {
        case let .success(pending):
            confirmation = ""
            await deleted(pending)
        case let .failure(error) where error.code == "reauth_required":
            // ⛔ THE PROOF IS GONE (expired, or spent): back to the start, said plainly.
            step = .explain
            failure = Failure(title: nil, message: DeleteAccountCopy.errorProofExpired)
        case let .failure(error):
            failure = Self.deleteFailure(error)
        }
    }

    // ── Wording ─────────────────────────────────────────────────────────────

    /// ⛔ BRANCHED ON THE CODE, NEVER ON THE MESSAGE. A code this build does not know shows the
    /// service's own sentence (``ApiError/localizedMessage``), and only then a fallback.
    static func reauthFailure(_ error: ApiError, sso: Bool) -> Failure {
        let message: String = switch (error, error.code) {
        case (.transport, _):
            DeleteAccountCopy.errorOfflineNotConfirmed
        case (_, "incorrect_password"):
            DeleteAccountCopy.errorWrongPassword
        case (_, "mfa_code_invalid"):
            DeleteAccountCopy.errorWrongCode
        case (_, "reauth_failed"):
            sso ? DeleteAccountCopy.errorWrongAccount : DeleteAccountCopy.errorNotConfirmed
        case (_, "rate_limited"):
            DeleteAccountCopy.errorTooManyAttempts
        case (.http(401, _, _), _):
            SessionCopy.sessionHasEndedPlease
        case (.decoding, _), (_, "server_error"):
            DeleteAccountCopy.errorNotConfirmed
        default:
            error.localizedMessage ?? DeleteAccountCopy.errorNotConfirmed
        }
        return Failure(title: nil, message: message)
    }

    /// ⚠️ A HEADLINE THAT SAYS NOTHING WAS DELETED, then why, exactly as the web's delete does
    /// (`deleteFailed` above the service's reason).
    static func deleteFailure(_ error: ApiError) -> Failure {
        switch (error, error.code) {
        case (.transport, _):
            Failure(title: nil, message: DeleteAccountCopy.errorOfflineNotDeleted)
        case (_, "confirmation_mismatch"):
            Failure(title: nil, message: DeleteAccountCopy.errorEmailMismatch)
        case (_, "rate_limited"):
            Failure(title: DeleteAccountCopy.notDeleted, message: DeleteAccountCopy.errorTooManyAttempts)
        case (_, "server_error"):
            // ⚠️ The service's own words here are "Internal server error", which tells nobody
            // what to do.
            Failure(title: DeleteAccountCopy.notDeleted, message: DeleteAccountCopy.errorTryAgainShortly)
        case (.http(401, _, _), _):
            Failure(title: DeleteAccountCopy.notDeleted, message: SessionCopy.sessionHasEndedPlease)
        case (.decoding, _):
            // ⛔ A 2xx THIS BUILD COULD NOT READ MAY BE A DELETION: never claim either way.
            Failure(title: nil, message: DeleteAccountCopy.errorOutcomeUnknown)
        default:
            Failure(
                title: DeleteAccountCopy.notDeleted,
                message: error.localizedMessage ?? DeleteAccountCopy.errorTryAgainShortly
            )
        }
    }
}
