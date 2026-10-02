import DistrictData
import DistrictModel
import Foundation
import Observation

/// A minted key's plaintext, held only for as long as its sheet is on screen.
///
/// ⛔ A TYPE OF ITS OWN RATHER THAN A `String?` ON THE MODEL, SO THAT "is the
/// secret still here" IS ONE QUESTION ASKED IN ONE PLACE. `SchedulingAPIKeyCreated`
/// also carries `id` and `createdAt`, neither of which the show-once sheet has any
/// use for; copying across only the two fields it renders is what stops a later
/// edit deciding to keep the whole response around "for the list".
///
/// ⚠️ `Identifiable` WITH A FRESH `UUID`, NEVER THE KEY OR THE SERVER ID. A URL or
/// a credential used as a SwiftUI identity is a copy of it SwiftUI keeps; the same
/// call `SchedulingHandOff` records.
struct SchedulingAPIKeyMintedC: Identifiable {
    let id = UUID()
    /// ⚠️ THE NAME THE FAR END ECHOED, NOT THE ONE THAT WAS TYPED. The fork owns
    /// the stored value and a mismatch would label the wrong credential.
    let name: String
    /// ⛔ THE PLAINTEXT. Never logged, never persisted, never interpolated into a
    /// copyable snippet — see the type note on `SchedulingAPIKeyCreated`.
    let key: String
}

/// Mint one API key and show its plaintext exactly once.
///
/// ⛔ THE SECRET LIVES ON THIS MODEL AND NOWHERE ELSE, AND `dismissMinted()` IS THE
/// ONLY WAY OUT. The web console holds it in a modal and drops it from state when
/// the modal closes; anything native has to do the same, because a model that kept
/// the last minted key would leave a live credential in memory for as long as the
/// screen stayed up. There is no re-read: `apiKeys.list` never carries a secret,
/// so a key lost here is a key that has to be revoked and re-minted.
///
/// ⛔ AND NOTHING HERE WRITES IT ANYWHERE. No `UserDefaults`, no keychain, no log
/// line, and `failure` is built from the refusal's CODE rather than from anything
/// that was sent — so no path out of this type can carry the plaintext with it.
///
/// ⚠️ `busy` GATES THE SUBMIT BECAUSE A SECOND PRESS MINTS A SECOND CREDENTIAL, of
/// which only one is ever shown. The web's own note records the same trap wearing
/// Cloudscape's clothes: `loading` sets only `aria-disabled` there, so its buttons
/// carry `disabled` too.
@MainActor
@Observable
final class SchedulingAPIKeyCreateModel {
    /// The customer's own label for the key. Trimmed on submit, never on keystroke.
    var name = ""

    private(set) var nameError: String?
    private(set) var busy = false
    private(set) var failure: FailureText?
    private(set) var minted: SchedulingAPIKeyMintedC?
    /// ⚠️ DOES NOT TIME OUT, matching the booking-link copy button on the hub: a
    /// confirmation that reverts needs a timer whose only job is to change a label
    /// back, and the sheet is dismissed long before it would matter.
    private(set) var copied = false

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

    /// ⚠️ THE FORM IS VALID WHEN THE TRIMMED NAME IS NON-EMPTY, which is the one
    /// check the catalog's schema and the browser both make.
    var canSubmit: Bool {
        !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func create() async {
        guard !busy else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = SchedulingWriteCopyC.keyNameMissing
            return
        }
        nameError = nil
        failure = nil
        busy = true
        do {
            let created = try await repository.createAPIKey(workspaceId: workspaceId, name: trimmed)
            busy = false
            name = ""
            copied = false
            minted = SchedulingAPIKeyMintedC(name: created.name, key: created.key)
            // ⚠️ THE LIST IS RE-READ EVEN THOUGH THE CREATE ANSWERED A ROW. The
            // response is a different shape from the list's (it carries a secret
            // the list never will), so appending it locally would be the one row
            // on screen that came from somewhere else.
            onChanged()
        } catch {
            busy = false
            failure = SchedulingFailureCopy.text(forAny: error)
        }
    }

    /// ⛔ THE ONE EXIT, AND IT DROPS THE PLAINTEXT. Both routes out of the sheet
    /// (the button and a swipe dismiss) call it.
    func dismissMinted() {
        minted = nil
        copied = false
    }

    /// ⚠️ THE PASTEBOARD WRITE ITSELF LIVES IN THE VIEW. Keeping `UIPasteboard` out
    /// of the model is what lets every assertion below run without touching the
    /// simulator's shared pasteboard, which is process-wide state a test would leak.
    func markCopied() {
        copied = true
    }

    func dismissFailure() {
        failure = nil
    }
}
