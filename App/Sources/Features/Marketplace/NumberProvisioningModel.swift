import DistrictData
import DistrictModel
import Foundation
import Observation

/// The phone-number provisioning surfaces: carrier connectivity, the regulatory filings,
/// the carrier-account setup, and the three things that can be done to a number the
/// workspace already holds.
///
/// ⛔ THERE IS NO PURCHASE HERE AND THERE MUST NOT BE. Buying a number charges a setup fee
/// AND opens a recurring monthly charge for a service consumed inside the app, which is App
/// Store Review Guideline 3.1.1: an in-app purchase or nothing. ``NumbersRepository`` has no
/// purchase method to call, `EndpointID` has no case for it, and
/// ``ApiRequestDescriptor``'s initialiser is internal — so it is unconstructible rather than
/// merely absent. ⛔ 3.1.1 covers STEERING too, so there is no URL here either: if a
/// `webURL`, an `openWeb` or a "Buy on the dashboard" action ever appears in this file, the
/// decision recorded on ``MarketplaceView`` has been reversed and should have been
/// discussed.
///
/// ⛔ FIVE INDEPENDENT READS AND SEVEN INDEPENDENT WRITES, NONE OF WHICH SHARE A STATE. The
/// reads hit different routes with different failure modes, so one shared failure would
/// blank answers the client already holds — the same call ``MarketplaceModel`` makes for its
/// two halves and ``AnalyticsModel`` for its two. The writes each carry a
/// ``NumberWriteState`` because five of them can be on screen at once and they fail for
/// unrelated reasons.
///
/// ⛔ AND A FAILED IRREVERSIBLE WRITE DOES NOT RE-ARM ITS CONTROL. A destructive button
/// handed back live under its own failure sentence invites a second irreversible write, so
/// the rule here is enforced by ``NumberWriteState/isArmed`` reading ``NumberWriteResubmit``, and by
/// ``confirmation`` being CLEARED only on the paths where the outcome is known.
///
/// ⛔ NOTHING LOADS ON ENTRY EXCEPT WHAT THE OPEN TAB NEEDS, and the filing list is
/// deliberately not free: the route refreshes every in-review bundle from the carrier on
/// read, so a screen that reloaded it on every appearance would spend a customer's own
/// carrier calls. ⛔ The lookup fires on ONE TAP ONLY, never on a keystroke, on appear or in
/// a retry loop, because the carrier bills per request.
///
/// ⚠️ A VIEWER MAY READ `provider/status`, `numbers/requirements`, `workspace/sip` and
/// `workspace/verify` and NOTHING ELSE on this surface. So the two role-gated reads are not
/// even attempted for one, and no write control is drawn — a viewer must not see a dead
/// control. ⚠️ The role is an affordance rather than a security control and errs low: a nil
/// role means "could not be established", never "assume client".
@MainActor
@Observable
final class NumberProvisioningModel {
    private(set) var carrier: CarrierStatusState = .loading

    private(set) var registrations: RegistrationsState = .loading

    private(set) var sip: SipTrunksState = .loading

    /// ⚠️ NOT `private(set)`, UNLIKE ITS NEIGHBOURS, AND THE ONE REASON IS THE SIBLING FILE.
    /// `private` is FILE scope in Swift, so ``setVerify(enabled:)`` in
    /// `NumberProvisioningModel+Writes.swift` could not adopt the write's echoed answer — and
    /// the alternatives were a second model over the same routes or a 550-line file. The
    /// invariant that only this type mutates it is held by every writer being a method ON
    /// this type; nothing in a view does.
    var verify: VerifyServiceState = .loading

    private(set) var requirements: RequirementsState = .idle

    /// The confirmation currently being collected, if any.
    ///
    /// ⛔ A WRITE IS ONLY EVER COMMITTED FROM ONE OF THESE, never straight from a tap, for the
    /// four that are irreversible or billable. See ``NumberConfirmation``.
    ///
    /// ⚠️ INTERNAL FOR THE REASON ON ``verify``: the four committing writes live in the
    /// sibling file and each clears it. ⛔ A view must go through
    /// ``requestConfirmation(_:)``, which refuses to open a dialog whose write is unarmed —
    /// setting this directly would re-arm a control a failed irreversible write had taken
    /// away.
    var confirmation: NumberConfirmation?

    // MARK: - Per-write state

    private(set) var registrationWrite: NumberWriteState = .idle

    /// ⚠️ Internal for the reason on ``verify``.
    var numberWrite: NumberWriteState = .idle

    /// ⚠️ Internal for the reason on ``verify``.
    var carrierWrite: NumberWriteState = .idle

    /// ⚠️ Internal for the reason on ``verify``.
    var lookupWrite: NumberWriteState = .idle

    /// The lookup's own answer, kept apart from its write state so a new confirmation does
    /// not blank the last result the operator is reading.
    ///
    /// ⚠️ Internal for the reason on ``verify``.
    var lookupResult: NumberLookupSummary?

    // MARK: - Forms

    var registrationDraft = RegistrationDraft()

    var sipDraft = SipTrunkDraft()

    var a2pDraft = A2PDraft()

    var tfvDraft = TollFreeDraft()

    var lookupNumber = ""

    /// Whether this member may do anything on these surfaces at all.
    ///
    /// ⛔ A REAL GATE HERE, UNLIKE ON THE MARKETPLACE'S TWO READS. Ten of the sixteen routes
    /// exclude `viewer` server-side, so a viewer is not shown the controls AND the two
    /// role-gated reads are not attempted for one — walking them into a 403 on entry would
    /// be worse than saying who to ask.
    let canProvision: Bool

    let workspaceId: String

    /// ⚠️ INTERNAL RATHER THAN `private`, for the reason on ``verify``: the six writes in
    /// `NumberProvisioningModel+Writes.swift` all go through it, and `private` is file scope.
    let repository: NumbersRepository

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        canProvision = WorkspaceRole.allowsMutation(role)
        repository = container.numbers
        self.workspaceId = workspaceId
    }

    // MARK: - Confirmations

    /// ⛔ REFUSED WHILE THE MATCHING WRITE IS UNARMED, which is what stops a dismissed
    /// failure being re-armed by reopening the dialog.
    ///
    /// ⚠️ CLOSING IS ALWAYS ALLOWED. Passing nil is the dismissal, and it must not be gated
    /// on a write state — that would trap an operator in a dialog whose button is gone.
    func requestConfirmation(_ next: NumberConfirmation?) {
        guard canProvision else { return }
        guard let next else {
            confirmation = nil
            return
        }
        guard armed(for: next) else { return }
        confirmation = next
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    /// ⚠️ TAKES A NON-OPTIONAL, DELIBERATELY. Switching over a `NumberConfirmation?` and
    /// writing `case .release:` reads as though it matches, and whether the compiler unwraps an
    /// optional inside an enum-case pattern is exactly the kind of subtlety that would make a
    /// destructive control's gate quietly always-true. The nil case is handled by the caller.
    private func armed(for confirmation: NumberConfirmation) -> Bool {
        switch confirmation {
        case .release:
            numberWrite.isArmed
        case .submitRegistration:
            registrationWrite.isArmed
        case .a2p, .tfv:
            carrierWrite.isArmed
        case .lookup:
            lookupWrite.isArmed
        }
    }

    // MARK: - Reads

    /// Which carriers this workspace has credentials for.
    ///
    /// ⛔ "NOTHING RESOLVED" IS AN ACCOUNT STATE RATHER THAN A FAULT and gets no retry
    /// button, exactly as the marketplace search's 400 does. The route answers it as an
    /// ordinary 200, so a red failure would tell an operator their app is broken while their
    /// account is merely new.
    ///
    /// ⚠️ A CARRIER THAT REFUSED ITS OWN CREDENTIALS IS CONTENT, not a failure: it arrives
    /// inside the 200 and needs a different sentence from "not connected", because one is
    /// fixable by reconnecting and the other by connecting.
    func loadCarrier() async {
        carrier = .loading
        switch await repository.providerStatus(workspaceId: workspaceId) {
        case let .success(response):
            let entries = response.providers ?? [:]
            carrier = entries.isEmpty
                ? .notConnected
                : .ready(
                    entries: entries,
                    connected: response.connectedProviders,
                    refused: response.refusedProviders
                )
        case let .failure(error):
            carrier = .failed(FailureText.from(error))
        }
    }

    /// This workspace's regulatory filings.
    ///
    /// ⛔ NOT FREE, AND NOT SAFE ON A TIMER. The route refreshes every in-review bundle from
    /// the carrier on read, so this spends a customer's own carrier calls; it is called on
    /// entry to its tab and on an explicit reload, and nowhere else.
    ///
    /// ⛔ NOT ATTEMPTED FOR A VIEWER. Both verbs exclude `viewer` server-side, so a viewer
    /// gets the "ask someone" sentence rather than a 403 that reads like a broken screen.
    func loadRegistrations() async {
        guard canProvision else {
            registrations = .ready(registrations: [], approvedCountries: [], platformCountries: [])
            return
        }
        registrations = .loading
        switch await repository.numberRegistrations(workspaceId: workspaceId) {
        case let .success(response):
            registrations = .ready(
                registrations: response.registrations,
                approvedCountries: response.approvedCountries,
                platformCountries: response.platformCountries
            )
        case let .failure(error):
            registrations = .failed(FailureText.from(error))
        }
    }

    /// The workspace's SIP trunks.
    ///
    /// ⚠️ THE READ ADMITS `viewer` while the create does not, so this one IS attempted for a
    /// viewer and only the create control is withheld.
    func loadSip() async {
        sip = .loading
        switch await repository.sipTrunks(workspaceId: workspaceId) {
        case let .success(response):
            sip = .ready(response.trunks)
        case let .failure(error):
            sip = .failed(FailureText.from(error))
        }
    }

    /// Whether the Verify (OTP) service exists.
    ///
    /// ⚠️ ADMITS `viewer`, like the SIP read.
    func loadVerify() async {
        verify = .loading
        switch await repository.verifyService(workspaceId: workspaceId) {
        case let .success(response):
            verify = .ready(enabled: response.enabled, sid: response.verifyServiceSid)
        case let .failure(error):
            verify = .failed(FailureText.from(error))
        }
    }

    /// What a country's regulator asks for.
    ///
    /// ⛔ A NULL `requirements` IS "NO REGISTRATION IS REQUIRED", NOT A FAILED LOOKUP, and
    /// the two states are separate here for that reason. ⛔ And `purchasable` is carried
    /// through both branches rather than inferred: a country can publish perfectly readable
    /// rules and still not be sellable, which is the answer an operator actually needs.
    ///
    /// ⚠️ ADMITS `viewer`: it is reference data about a country rather than anything about
    /// the workspace.
    func loadRequirements() async {
        let country = registrationDraft.trimmedCountry
        guard !country.isEmpty else { return }
        requirements = .loading
        let outcome = await repository.numberRequirements(
            workspaceId: workspaceId,
            country: country,
            numberType: registrationDraft.numberType
        )
        switch outcome {
        case let .success(response):
            requirements = response.requirements.map {
                RequirementsState.ready($0, purchasable: response.purchasable)
            } ?? .noRegulation(country: response.country, purchasable: response.purchasable)
        case let .failure(error):
            requirements = .failed(FailureText.from(error))
        }
    }

    // MARK: - Registration writes

    /// Open a draft filing.
    ///
    /// ⚠️ IDEMPOTENT BY REFUSAL RATHER THAN BY CONVERGENCE: one filing per workspace per
    /// country and number type, so a second attempt is a 409 naming the existing one. That
    /// is why this write has no confirmation and why a failure may re-arm.
    ///
    /// ⛔ A CREATED DRAFT HAS REACHED NO CARRIER, so the notice must not say "filed".
    func createRegistration() async {
        guard canProvision, registrationWrite.isArmed else { return }
        let country = registrationDraft.trimmedCountry
        guard !country.isEmpty else { return }
        registrationWrite = .running
        let outcome = await repository.createRegistration(
            workspaceId: workspaceId,
            isoCountry: country,
            numberType: registrationDraft.numberType,
            friendlyName: registrationDraft.trimmedName.isEmpty ? nil : registrationDraft.trimmedName
        )
        switch outcome {
        case .success:
            registrationWrite = .idle
            registrationDraft = RegistrationDraft()
            await loadRegistrations()
        case let .failure(error):
            registrationWrite = .failed(FailureText.from(error), .after(error, .idempotent))
        }
    }

    /// Remove one document from a draft filing.
    ///
    /// ⚠️ IDEMPOTENT: a second removal is a 404, which is the outcome the caller asked for.
    /// ⛔ A 502 changed nothing and the row is still there, because this route deletes the
    /// object before the row — so the reload is what shows the truth either way.
    func removeDocument(bundleId: String, documentId: String) async {
        guard canProvision, registrationWrite.isArmed else { return }
        registrationWrite = .running
        let outcome = await repository.deleteRegistrationDocument(
            workspaceId: workspaceId,
            bundleId: bundleId,
            documentId: documentId
        )
        switch outcome {
        case .success:
            registrationWrite = .idle
            await loadRegistrations()
        case let .failure(error):
            registrationWrite = .failed(FailureText.from(error), .after(error, .idempotent))
        }
    }

    /// File a registration with the carrier.
    ///
    /// ⛔ COMMITTED ONLY FROM ITS CONFIRMATION, and ``NumberWriteRepeat/once``: it uploads
    /// the customer's identity documents to the carrier and files a regulated application in
    /// their name. A failure that does not prove the write was skipped leaves the control
    /// GONE rather than handing it back.
    ///
    /// ⛔ AND A 422's DETAIL DOES NOT ARRIVE IN THE ERROR. The route stores the carrier's
    /// objections on the filing, so the remedy is a re-read — which is why this reloads the
    /// list on the failure path too, and why the notice says where to look.
    func submitRegistration(bundleId: String) async {
        guard canProvision, registrationWrite.isArmed else { return }
        confirmation = nil
        registrationWrite = .running
        let outcome = await repository.submitRegistration(
            workspaceId: workspaceId,
            bundleId: bundleId,
            endUserAttributes: registrationDraft.attributes
        )
        switch outcome {
        case .success:
            registrationWrite = .done(MarketplaceCopy.submitFiled)
            await loadRegistrations()
        case let .failure(error):
            registrationWrite = .failed(Self.submitFailure(error), .after(error, .once))
            await loadRegistrations()
        }
    }

    /// ⛔ A 422 IS REDIRECTED TO THE LIST RATHER THAN LEFT AS A BARE SENTENCE, because that
    /// is where the carrier's objections actually are: `ApiError` keeps only `error` and
    /// drops `failures` and `reasons`, which the route persisted on the row.
    private static func submitFailure(_ error: ApiError) -> FailureText {
        guard error.httpStatus == 422 else { return FailureText.from(error) }
        let stated = error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sentence = stated.isEmpty ? MarketplaceCopy.submitRefusedReread : stated
        return FailureText(message: "\(sentence) \(MarketplaceCopy.submitRefusedReread)", action: .none)
    }
}
