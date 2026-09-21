import DistrictData
import DistrictModel
import Foundation

/// The writes: what can be done to a number the workspace holds, and the four
/// carrier-account submissions.
///
/// ⛔ AN EXTENSION IN ITS OWN FILE RATHER THAN MORE OF `NumberProvisioningModel.swift`, which
/// is SwiftLint's 500-line `file_length` and 300-line `type_body_length` rather than a
/// taxonomy. The cut is on a real seam: that file owns the READS and the filing paperwork,
/// this one owns everything that spends money or takes a line out of service.
///
/// ⛔ FIVE OF THE SIX WRITES HERE ARE ``NumberWriteRepeat/once``, and each for a different
/// reason: a release cannot be undone; an A2P submission pays a carrier brand fee; a
/// toll-free verification enters a manual review and churns a live number's routing; a Verify
/// enable mints a billable sender that outlives our pointer to it; a lookup is billed per
/// call. ⚠️ Only ``configure(phoneNumber:)`` is idempotent, which is why it alone has no
/// confirmation — a confirmation on a converging write trains the operator to dismiss the
/// ones that matter.
extension NumberProvisioningModel {
    // MARK: - A number the workspace already holds

    /// Reapply this number's routing.
    ///
    /// ⚠️ IDEMPOTENT, SO NO CONFIRMATION AND A FAILURE MAY RE-ARM. The route writes the same
    /// webhooks and restates the same trunk binding every time.
    ///
    /// ⛔ AND IT IS NOT THE NO-OP IT LOOKS LIKE. Restating the EU trunk binding is what keeps
    /// an EU number answered in Europe; the route fails CLOSED with a 503 rather than write
    /// number-level webhooks over a trunk-bound DID, because that degrade is a state change
    /// dressed as a no-op that answers 200.
    func configure(phoneNumber: String) async {
        guard canProvision, numberWrite.isArmed else { return }
        numberWrite = .running
        switch await repository.configureNumber(workspaceId: workspaceId, phoneNumber: phoneNumber) {
        case .success:
            numberWrite = .done(MarketplaceCopy.configureDone)
        case let .failure(error):
            numberWrite = .failed(FailureText.from(error), .after(error, .idempotent))
        }
    }

    /// Give this number back to the carrier.
    ///
    /// ⛔ COMMITTED ONLY FROM ITS CONFIRMATION, AND A FAILURE THAT DOES NOT PROVE THE WRITE
    /// WAS SKIPPED LEAVES THE CONTROL GONE. The number goes back to the carrier's pool and
    /// generally cannot be reclaimed; every call and message routed to it stops.
    ///
    /// ⛔ A **200 CARRYING `warnings` IS STILL A RELEASE**, and one of the warnings is that
    /// the monthly charge could not be ended. So the success notice CARRIES the lines rather
    /// than replacing them with "Released" — dropping them would leave an operator believing
    /// they had stopped a charge they had not.
    ///
    /// ⚠️ A **403 AFTER A SUCCESSFUL RELEASE IS THE EXPECTED ANSWER**: the ownership row the
    /// guard needs has just been deleted. That is why the 4xx branch of
    /// ``NumberWriteResubmit`` is safe here — the second attempt is also free — and why the
    /// wording must not claim the release failed.
    func release(phoneNumber: String) async {
        guard canProvision, numberWrite.isArmed else { return }
        confirmation = nil
        numberWrite = .running
        switch await repository.releaseNumber(workspaceId: workspaceId, phoneNumber: phoneNumber) {
        case let .success(response):
            let warnings = response.warningLines
            numberWrite = .done(
                warnings.isEmpty
                    ? MarketplaceCopy.releaseDone
                    : ([MarketplaceCopy.releaseWarningEyebrow] + warnings).joined(separator: " ")
            )
        case let .failure(error):
            numberWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    // MARK: - The billable lookup

    /// Look one number up at the carrier.
    ///
    /// ⛔ ONE TAP, ONE LOOKUP, AND ONLY FROM ITS CONFIRMATION. The carrier bills per request
    /// and line-type intelligence costs more than a basic one, so this must never be reached
    /// from a keystroke, from `.task`, or from a retry — which is also why the failure branch
    /// takes ``NumberWriteRepeat/once`` even though the call is a GET with no side effects.
    ///
    /// ⚠️ `valid: false` IS A REAL ANSWER THAT ALREADY COST MONEY, not an empty state: the
    /// route translates the carrier's own 404 itself. The result is kept apart from the write
    /// state so opening a new confirmation does not blank the answer being read.
    func lookup() async {
        guard canProvision, lookupWrite.isArmed else { return }
        let number = lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        confirmation = nil
        lookupWrite = .running
        switch await repository.lookupNumber(workspaceId: workspaceId, phoneNumber: number) {
        case let .success(response):
            lookupResult = NumberLookupSummary(response.info)
            lookupWrite = .idle
        case let .failure(error):
            lookupWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    // MARK: - Carrier accounts

    /// Provision a SIP trunk.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, AND A ONE-WAY DOOR. It creates an access list, its
    /// addresses and a carrier SIP domain, and opens a $25/month charge with no route in this
    /// app to end it. ⚠️ Only a workspace-lookup miss rolls the carrier side back, so a
    /// failure is not necessarily a no-op and a blind retry can double both the resources and
    /// the charge.
    func createSipTrunk() async {
        guard canProvision, carrierWrite.isArmed, sipDraft.isSubmittable else { return }
        carrierWrite = .running
        let outcome = await repository.createSipTrunk(
            workspaceId: workspaceId,
            name: sipDraft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: sipDraft.domain.trimmingCharacters(in: .whitespacesAndNewlines),
            ipAccessControlList: sipDraft.addresses
        )
        switch outcome {
        case .success:
            carrierWrite = .idle
            sipDraft = SipTrunkDraft()
            await loadSip()
        case let .failure(error):
            carrierWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    /// Turn the Verify (OTP) service on or off.
    ///
    /// ⛔ ``NumberWriteRepeat/once`` FOR AN ASYMMETRY RATHER THAN FOR THE COST OF ONE CALL.
    /// Enabling creates a real, carrier-billable sender; disabling deliberately does NOT
    /// delete it and clears only our pointer, so an enable/disable/enable loop mints unbounded
    /// orphan senders that have to be reaped by hand. Both directions are therefore treated
    /// as unrepeatable-on-an-ambiguous-failure.
    ///
    /// ⚠️ THE ANSWER IS ADOPTED RATHER THAN RE-READ: both branches echo `enabled` and the
    /// enable branch echoes the sid.
    func setVerify(enabled: Bool) async {
        guard canProvision, carrierWrite.isArmed else { return }
        carrierWrite = .running
        let outcome = await repository.setVerifyServiceEnabled(workspaceId: workspaceId, enabled: enabled)
        switch outcome {
        case let .success(response):
            carrierWrite = .idle
            verify = .ready(enabled: response.enabled, sid: response.verifyServiceSid)
        case let .failure(error):
            carrierWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    /// Submit an A2P 10DLC registration.
    ///
    /// ⛔ COMMITTED ONLY FROM ITS CONFIRMATION. It pays a one-off carrier brand fee and opens
    /// a monthly campaign fee, and **there is no status read anywhere** — so the notice below
    /// is the only report this flow will ever produce and cannot be refreshed.
    ///
    /// ⚠️ ITS ORDINARY FIRST ANSWER IS A **400 CARRYING `TRUST_BUNDLES_NOT_APPROVED`**, which
    /// is an account state rather than a fault: the TrustHub bundles are a manual, multi-day,
    /// once-per-account Console step no retry moves. It arrives as a 4xx, so the control
    /// re-arms — correctly, because resubmitting after the bundles are approved is exactly
    /// what the operator will want to do.
    func submitA2P() async {
        guard canProvision, carrierWrite.isArmed, a2pDraft.isSubmittable else { return }
        confirmation = nil
        carrierWrite = .running
        let outcome = await repository.submitA2PRegistration(
            workspaceId: workspaceId,
            registration: a2pDraft.request
        )
        switch outcome {
        case let .success(response):
            carrierWrite = .done(MarketplaceCopy.a2pSubmitted(status: response.status))
        case let .failure(error):
            carrierWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }

    /// Submit a toll-free verification.
    ///
    /// ⛔ COMMITTED ONLY FROM ITS CONFIRMATION, AND IT CHANGED A LIVE NUMBER'S ROUTING STATE.
    /// The route moves the hub's ownership row to `pending_verification` once the carrier
    /// accepts, and the review that follows is manual and takes days. **There is no status
    /// read**, so the notice below is the whole report.
    ///
    /// ⛔ THE OPT-IN URL IS SENT EVEN WHEN EMPTY, so the refusal an operator sees is the
    /// route's own actionable sentence about opt-in evidence rather than a generic
    /// missing-field message this layer invented.
    func submitTollFree() async {
        guard canProvision, carrierWrite.isArmed, tfvDraft.isSubmittable else { return }
        confirmation = nil
        carrierWrite = .running
        let outcome = await repository.submitTollFreeVerification(
            workspaceId: workspaceId,
            verification: tfvDraft.request
        )
        switch outcome {
        case let .success(response):
            carrierWrite = .done(MarketplaceCopy.tfvSubmitted(status: response.status))
        case let .failure(error):
            carrierWrite = .failed(FailureText.from(error), .after(error, .once))
        }
    }
}
