import DistrictData
import DistrictModel

// ⛔ NOT REDUNDANT, AND LINUX CANNOT TELL YOU THAT. `MessagingAccountDraft` lives in
// DistrictNetwork, and `DistrictData` importing it does NOT re-export it: inside the
// package every module already has it in scope, so `swift test` builds clean and the
// App target is the only consumer that needs the import spelled out. Since nothing
// under `App/` compiles on Linux, this class of error can only be found on a Mac.
import DistrictNetwork
import Foundation
import Observation

/// The messaging screen's state machine. Ported from Android's `MessagingViewModel`.
///
/// ⚠️ ``MessagingLoadState`` AND ``MessagingProbeState`` LIVE IN `MessagingState.swift`.
/// They live apart to keep this file under the 500-line `file_length` ceiling that
/// `swiftlint --strict` makes an error, not because they belong to something else.
///
/// ⛔ NOTHING HERE IS EVER REPLAYED. ``load()`` is the only idempotent call on the
/// type; every write is invoked from a press and from nothing else. A replayed create
/// would mint a second carrier account and a replayed delete would remove whichever
/// account had since taken the id's place in the operator's head.
///
/// ⛔ EVERY WRITE RE-CHECKS THE ROLE AT ITS OWN CALL SITE rather than trusting that the
/// UI hid the control. ``canEdit`` is a UX gate; the server's `requireWorkspaceRole` is
/// the boundary. A viewer reaches this screen, so "the button was not drawn" is the
/// kind of assumption that survives until someone adds a keyboard shortcut.
///
/// ⛔ A WRITE THAT LANDED RE-READS, AND A FAILED RE-READ DOES NOT OVERWRITE THE WRITE'S
/// OWN NOTICE. They are separate fields precisely so "the change landed" and "we could
/// not re-read the list" can both be true and both be said. Telling an operator their
/// change failed when only the read did invites them to make it again — and on this
/// surface "again" can mean a second carrier account. That outcome has a name,
/// ``SettingsSaveState/savedButStale(_:)``, and the screen must draw it outside
/// `case .ready`: ``read()`` sets `load` to `.failed` whatever it was called for, so a
/// notice drawn only inside `.ready` would turn a successful create followed by a failed
/// GET into nothing but "Could not load this workspace's configuration".
///
/// ⛔ A WRITE THAT WAS REFUSED DOES NOT RE-READ, EXCEPT FROM THE THREE ROW CONTROLS.
/// This is ``SettingsConfigGateway/commit(_:)``'s rule and the reasoning is its: nothing
/// was written, so the list on screen is still correct, and a second request only gives
/// a flaky network the chance to turn a clear refusal into a load failure. ⚠️ THE ROW
/// CONTROLS ARE THE EXCEPTION because their commonest refusal is a **404**, which means
/// the list itself is stale and re-reading is the fix. ``saveAccount()`` is not, and the
/// difference is its FORM: it is the only write whose sheet is still open afterwards,
/// so a load failure there disables a form holding unsaved carrier secrets whose only
/// escape discards them.
///
/// ⛔ EVERY WRITE HOLDS ITS SAVE STATE AT `saving` UNTIL ITS RE-READ HAS FINISHED.
/// Settling the state first would leave ``busy`` false for the whole GET, with every row
/// control live against a list still showing pre-write rows, beside "Saved.". A deleted
/// account would stay drawn with a working Delete for the length of the read, and
/// pressing it would send a request the route 404s. ⚠️ THAT WINDOW IS ALSO THIS TYPE'S
/// ONLY SEQUENCING. There is no generation counter on the reads and none is needed:
/// every write is gated on ``canEditNow``, which is gated on ``busy``, so two of these
/// can no longer be in flight at once and two responses cannot land out of order.
///
/// ⚠️ THE UPSERT'S RESPONSE IS NEVER USED TO PATCH THE LIST. It echoes ids only, and
/// the route trims the label, may substitute a generated provider name and filters the
/// numbers; a row rebuilt from the request would show what was typed rather than what
/// was stored.
@MainActor
@Observable
final class MessagingModel {
    private(set) var load: MessagingLoadState = .loading
    private(set) var accountSave: SettingsSaveState = .idle
    private(set) var defaultSave: SettingsSaveState = .idle
    private(set) var channelSave: SettingsSaveState = .idle
    private(set) var deleteSave: SettingsSaveState = .idle
    private(set) var metaSave: SettingsSaveState = .idle
    private(set) var probe: MessagingProbeState = .idle

    /// ⚠️ Non-nil exactly while the add/edit form is open. Nil is "not editing
    /// anything".
    private(set) var draft: MessagingDraft?

    /// How many probes have been STARTED.
    ///
    /// ⛔ RETIRING A DISPLAYED PROBE RESULT AND RETIRING THE IN-FLIGHT ONE ARE TWO
    /// DIFFERENT ACTS, AND BOTH ARE NEEDED. ``testCredentials()`` awaits a real carrier
    /// round trip, and writing ``probe`` unconditionally afterwards would let a result
    /// outlive the form it was asked about: test Twilio keys, Cancel, open a new form,
    /// type Sinch keys, and the first probe returns and renders a green "Those
    /// credentials work" about keys the carrier never saw. Editing one character of the
    /// auth token mid-probe is the one-action version. Every path that clears ``probe``
    /// goes through ``retireProbe()``, which bumps this, and a probe that comes back
    /// on a stale number is DROPPED rather than shown.
    ///
    /// ⚠️ NOT A LOCK, AND DELIBERATELY NOT. A probe writes nothing — it is one
    /// authenticated read against the carrier — so nothing here tries to hold the screen
    /// for the length of one. Cancelling and pressing Test again is two presses and two
    /// calls, which is what the operator asked for; what must never survive is the
    /// ANSWER to a question about a form that is gone.
    private var probeGeneration = 0

    /// ⛔ NEVER PRE-FILLED, AND THE REASON IS THE ONE THE WORKSPACE RENAME RECORDS:
    /// nothing this client can read returns the stored creator cell number (it is not
    /// on the messaging GET and the write does not echo it), so a field seeded from
    /// what we know could only be blank — which is the shape that writes a blank over a
    /// real value.
    private(set) var creatorCellDraft = ""

    /// ⛔ False for `viewer` and for a role that did not parse.
    let canEdit: Bool

    private let messaging: MessagingRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        messaging = container.messaging
        self.workspaceId = workspaceId
        canEdit = WorkspaceRole.allowsMutation(role)
    }

    var response: MessagingResponse? {
        guard case let .ready(value) = load else { return nil }
        return value
    }

    var accounts: [MessagingAccount] {
        response?.accounts ?? []
    }

    var busy: Bool {
        accountSave.isSaving || defaultSave.isSaving || channelSave.isSaving
            || deleteSave.isSaving || metaSave.isSaving || isProbing
    }

    var isProbing: Bool {
        if case .running = probe {
            return true
        }
        return false
    }

    /// ⛔ EDITING REQUIRES A SUCCESSFUL READ, WHICH IS NOT THE SAME RULE AS THE CONFIG
    /// SECTIONS' AND IS NOT AS STRICT AS THEIRS. Nothing here is a wholesale replace —
    /// an account is created and edited BY ID and the route merges `providerConfig`
    /// field-wise — so a form built from nothing could not delete a stored value the
    /// way a blank `callDirectory` does. It is gated anyway for a narrower reason: an
    /// EDIT needs the account it is editing, and "add an account" offered against a
    /// list that failed to load invites a duplicate of one already there.
    var canEditNow: Bool {
        guard case .ready = load else { return false }
        return canEdit && !busy
    }

    /// ⛔ Blank writes an empty string rather than clearing nothing, so the button
    /// demands one.
    var canSaveCreatorCell: Bool {
        canEditNow && !creatorCellDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⚠️ AN IDEMPOTENT GET, WHICH IS WHAT MAKES REPLAYING IT SAFE. It also DISCARDS
    /// any open draft, and that is the safe direction: a fresh read means the client's
    /// belief about which accounts exist has been replaced, and an edit form still
    /// pointing at an id from before is how a save lands on the wrong row.
    ///
    /// ⚠️ NAMED `loadAccounts` RATHER THAN `load`, which is taken by the state property
    /// above. A method and a property of the same name compile and make every
    /// assignment inside the method read as though it might be doing something else.
    func loadAccounts() async {
        load = .loading
        draft = nil
        retireProbe()
        await read()
        // ⛔ THE BANNERS ARE RETIRED ONLY ON A SUCCESSFUL READ, which is the same guard
        // the persona and capability forms put on their drafts and for a stricter
        // reason: a `savedButStale` notice is the ONLY record that a write landed, and
        // clearing it on a reload that then failed would destroy that record while
        // showing "Could not load" in its place. On success there is a fresh list, so a
        // banner about the previous one is a claim about state that has been replaced.
        guard case .ready = load else { return }
        accountSave = .idle
        defaultSave = .idle
        channelSave = .idle
        deleteSave = .idle
        metaSave = .idle
    }

    /// Open the form, for a new account or for one that exists.
    ///
    /// ⚠️ SILENTLY DOES NOTHING FOR AN ID THE READ DOES NOT HOLD, rather than falling
    /// back to a create. A stale row is the ordinary cause, and turning "edit the
    /// account that is gone" into "add a new one" is how a duplicate carrier account
    /// gets made.
    func startEditing(accountId: String?) {
        guard canEditNow else { return }
        guard let accountId else {
            draft = MessagingDraft()
            retireProbe()
            return
        }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        draft = MessagingDraft.editing(account)
        retireProbe()
    }

    /// Replace the open draft, or close the form with nil.
    ///
    /// ⛔ ANY EDIT RETIRES A PROBE RESULT, INCLUDING ONE THAT HAS NOT COME BACK YET. A
    /// green "credentials verified" sitting under a key that has since been retyped is a
    /// claim about a value nobody tested, and the in-flight case is the easy one to miss:
    /// clearing only the DISPLAYED result lets the request carry on and overwrite it.
    /// ``retireProbe()`` is what closes both.
    func editDraft(_ next: MessagingDraft?) {
        guard next == nil || draft != nil else { return }
        draft = next
        retireProbe()
    }

    /// Create or edit the account in the open draft.
    ///
    /// ⛔ THE ONLY NON-IDEMPOTENT CALL ON THIS SCREEN when the draft has no
    /// `accountId`: the route mints `acct-<uuid>` inside the transaction, so two
    /// deliveries are two accounts with two copies of the credentials. It is guarded by
    /// ``busy`` for the whole round trip and by the draft being cleared on success, so
    /// a second press cannot re-send the same create. ⛔ Nothing retries it.
    ///
    /// ⛔ A **502** IS NOT A REFUSAL AND IS NOT WORDED AS ONE. The route separates it
    /// from its three 403s on purpose: the carrier-ownership probe could not reach the
    /// carrier, so the number stays unclaimed either way and trying again shortly is
    /// both safe and the correct advice. ⚠️ ``FailureText`` refuses to render any 5xx
    /// body — several routes return raw exception text there — so this is the one place
    /// that has to reach past it, which the ⛔ on ``MessagingRepository`` asks for by
    /// name.
    func saveAccount() async {
        guard canEditNow, let current = draft, current.canSave else { return }
        accountSave = .saving
        let outcome = await messaging.saveAccount(
            workspaceId: workspaceId,
            account: MessagingAccountDraft(
                activeProvider: current.provider,
                credentialSource: current.credentialSource,
                providerConfig: current.providerConfig(includingProvider: false),
                accountId: current.accountId,
                label: current.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                // ⚠️ nil RATHER THAN `false` WHEN UNTICKED. The route makes the first
                // account of a workspace the default regardless; sending false would
                // not stop that and would claim an instruction nobody gave.
                makeDefault: current.makeDefault ? true : nil
            )
        )
        switch outcome {
        case .success:
            draft = nil
            retireProbe()
            // ⛔ THE RE-READ HAPPENS INSIDE THE `saving` WINDOW, so the list cannot be
            // operated on while it is still the pre-write one. See the ⛔ on the class.
            accountSave = await rereadAfterWrite()
        case let .failure(error):
            // ⚠️ THE DRAFT SURVIVES. Losing a typed credential because the save was
            // refused would be two losses for one fault, and the refusal is often
            // something the operator can act on.
            //
            // ⛔ AND THERE IS NO RE-READ HERE, WHICH IS THE ONE PLACE THIS TYPE DIVERGES
            // FROM ITS OWN ROW CONTROLS. Nothing was written, so the list is still
            // right; and a trailing GET on the same dead connection that just refused
            // the POST would set `load` to `.failed`, which drops ``canEditNow`` and
            // silently turns Save and Test into no-ops on a sheet that is still open,
            // still enabled and still holding the typed carrier secrets. The only way
            // out of that state would be to discard them.
            accountSave = .failed(Self.writeFailure(error))
        }
    }

    /// ⚠️ Idempotent and reversible, which is why it is a row control rather than a
    /// confirmed action.
    func setDefault(accountId: String) async {
        guard canEditNow else { return }
        defaultSave = .saving
        let result = await messaging.setDefaultAccount(
            workspaceId: workspaceId,
            accountId: accountId
        )
        defaultSave = await commit(result)
    }

    /// ⚠️ MERGES ONE KEY server-side and echoes the whole map. There is no way to CLEAR
    /// an override from this client, which the screen says rather than implying one.
    func setChannelDefault(channel: String, accountId: String) async {
        guard canEditNow else { return }
        channelSave = .saving
        let result = await messaging.setChannelDefault(
            workspaceId: workspaceId,
            channel: channel,
            accountId: accountId
        )
        channelSave = await commit(result)
    }

    /// Remove one account.
    ///
    /// ⛔ THE CONFIRMATION IS THE SCREEN'S AND HAS ALREADY HAPPENED, and it is not a
    /// formality: this releases the hub's claim on every phone number only this account
    /// held, so another tenant can then take one. Re-adding the account does not take
    /// them back — it re-proves ownership at the carrier, which only works if nobody
    /// else got there first. ⛔ Not retried.
    ///
    /// ⚠️ A **404** MEANS THE LIST ON SCREEN IS STALE rather than that anything is
    /// broken, and the re-read below is what fixes it.
    func deleteAccount(accountId: String) async {
        guard canEditNow else { return }
        deleteSave = .saving
        let result = await messaging.deleteAccount(
            workspaceId: workspaceId,
            accountId: accountId
        )
        deleteSave = await commit(result)
    }

    func editCreatorCell(_ value: String) {
        creatorCellDraft = value
        metaSave = .idle
    }

    /// Write the workspace's creator cell number.
    ///
    /// ⚠️ NO RE-READ. The stored value is not on the messaging GET, so re-reading could
    /// not confirm it — and letting a failed list read replace a successful save notice
    /// would report a fault that did not happen. Same call as the workspace rename.
    func saveCreatorCell() async {
        guard canSaveCreatorCell else { return }
        metaSave = .saving
        let result = await messaging.saveCreatorCell(
            workspaceId: workspaceId,
            creatorCellNumber: creatorCellDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        metaSave = state(from: result)
        // ⚠️ CLEARED ONLY ON SUCCESS, so a failure leaves the typed number on screen.
        if case .success = result {
            creatorCellDraft = ""
        }
    }

    /// Ask the carrier whether the typed credentials authenticate.
    ///
    /// ⛔ A PROBE IS NOT A SAVE AND NOTHING HERE WRITES ANYTHING. The route answers a
    /// failed credential check with HTTP **200** and `{success:false, error}` on
    /// purpose, so "these keys are wrong" is a normal answer rather than a server
    /// fault; the repository deliberately does not run the envelope guard over it, and
    /// this is where that answer becomes ``MessagingProbeState/rejected(_:)`` rather
    /// than a transport failure.
    ///
    /// ⛔ ONE PRESS, ONE AUTHENTICATED THIRD-PARTY CALL FROM THE PLATFORM'S OWN EGRESS,
    /// with the credentials in the body, capped at 10/min per workspace by a Redis
    /// limiter that FAILS OPEN. Nothing may call this from a redraw, a retry or a loop.
    ///
    /// ⛔ OFFERED ONLY WHEN THE DRAFT ACTUALLY HOLDS THE CREDENTIALS. On an ordinary
    /// edit the secret boxes are deliberately blank, and sending blanks would report
    /// the carrier's 401 as though the STORED credentials were broken.
    /// ⛔ THE ANSWER IS DROPPED IF THE FORM IT WAS ASKED ABOUT IS GONE. The generation
    /// is taken before the request and compared after it; anything that retires a probe
    /// in the meantime (a keystroke, Cancel, opening another account, a reload, a
    /// successful save) has moved it on. See ``probeGeneration``.
    func testCredentials() async {
        guard canEditNow, let current = draft, current.canTest else { return }
        probeGeneration += 1
        let generation = probeGeneration
        probe = .running
        let outcome = await messaging.testCredentials(
            workspaceId: workspaceId,
            providerConfig: current.providerConfig(includingProvider: true)
        )
        guard generation == probeGeneration else { return }
        switch outcome {
        case let .success(response) where response.success:
            probe = .passed(response.detail)
        case let .success(response):
            // ⚠️ THE CARRIER'S OWN WORDS, FORWARDED. A blank counts as absent, the same
            // normalisation `ApiErrorEnvelope` follows.
            let message = response.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            probe = .rejected(message.isEmpty ? Self.probeRefusedFallback : message)
        case let .failure(error):
            // ⛔ A TRANSPORT OR STATUS FAILURE IS NOT EVIDENCE ABOUT THE CREDENTIALS.
            // "We could not ask" and "your keys do not authenticate" are different
            // facts.
            probe = .unreachable(FailureText.from(error))
        }
    }

    /// ⚠️ Retires every banner without a re-read.
    func dismissNotices() {
        guard !busy else { return }
        accountSave = .idle
        defaultSave = .idle
        channelSave = .idle
        deleteSave = .idle
        metaSave = .idle
    }

    // MARK: - Internals

    /// Retire the probe: the result on screen AND any request still in flight.
    ///
    /// ⛔ THE INCREMENT IS THE LOAD-BEARING HALF. Setting ``probe`` to `.idle` only
    /// retires what is displayed; bumping the generation is what makes the returning
    /// request discard itself. Nothing may clear ``probe`` without going through here.
    private func retireProbe() {
        probeGeneration += 1
        probe = .idle
    }

    /// One write's re-read, reported as the outcome of the WRITE.
    ///
    /// ⛔ CALLED ONLY AFTER A WRITE THAT LANDED, AND IT NEVER REPORTS A FAILURE. A read
    /// that fails after a write that succeeded is
    /// ``SettingsSaveState/savedButStale(_:)`` — the change IS stored and the list on
    /// screen is out of date — which is a different sentence from "that did not save"
    /// and, on a surface where making a change again means a second carrier account,
    /// the difference is the whole point.
    private func rereadAfterWrite() async -> SettingsSaveState {
        switch await messaging.accounts(workspaceId: workspaceId) {
        case let .success(response):
            load = .ready(response)
            return .saved
        case let .failure(error):
            return .savedButStale(FailureText.from(error))
        }
    }

    /// One row control's write plus its re-read, inside a single `saving` window.
    ///
    /// ⛔ THE RE-READ RUNS BEFORE THIS RETURNS, so the caller's state is still `.saving`
    /// for the whole of it and ``busy`` keeps every control off a list that has not been
    /// refreshed yet.
    ///
    /// ⚠️ IT RE-READS AFTER A FAILURE TOO, which ``saveAccount()`` deliberately does
    /// not. The commonest refusal these three earn is a **404**, and a 404 means the row
    /// on screen is already gone: re-reading is the fix rather than an extra chance to
    /// fail. There is no open form here for a load failure to strand.
    private func commit(_ write: Result<some Any, ApiError>) async -> SettingsSaveState {
        guard case let .failure(error) = write else {
            return await rereadAfterWrite()
        }
        await read()
        return .failed(FailureText.from(error))
    }

    /// ⛔ DOES NOT TOUCH ANY SAVE STATE. See the ⛔ on the class: a failed re-read must
    /// not overwrite a successful write's notice.
    private func read() async {
        switch await messaging.accounts(workspaceId: workspaceId) {
        case let .success(response):
            load = .ready(response)
        case let .failure(error):
            load = .failed(FailureText.from(error))
        }
    }

    private func state(from result: Result<some Any, ApiError>) -> SettingsSaveState {
        switch result {
        case .success: .saved
        case let .failure(error): .failed(FailureText.from(error))
        }
    }

    /// ⛔ THE 502 IS THE ONE 5xx IN THIS APP WHOSE BODY IS SHOWN. ``FailureText``
    /// refuses to render a 5xx verbatim because several routes return raw exception
    /// messages there, but `handleUpsert`'s 502 is an authored sentence naming the
    /// number and the carrier and it means "we could not ASK", not "that number is not
    /// yours". ⚠️ Retryable, deliberately: the number stays unclaimed, so trying again
    /// shortly is exactly the right thing to do.
    private static func writeFailure(_ error: ApiError) -> FailureText {
        guard error.httpStatus == 502, let message = error.message, !message.isEmpty else {
            return FailureText.from(error)
        }
        return FailureText(message: message, action: .retry)
    }

    private static let probeRefusedFallback = "The carrier refused those credentials."
}

/// ⚠️ `private` SO IT IS FILE-SCOPED. A helper this small on a stdlib type is exactly
/// the kind of thing that collides with an identically-named one elsewhere in the module.
private extension String {
    /// ⚠️ nil FOR A BLANK, because a label the operator cleared must be OMITTED from
    /// the body rather than sent as `""` — the route substitutes a title-cased provider
    /// name for a missing label and would store the empty string instead.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
