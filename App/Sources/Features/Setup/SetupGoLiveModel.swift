import DistrictData
import DistrictModel
import Foundation
import Observation

/// Step 6, "Test and go live": the test call, the forwarding check, the summary, and Finish.
///
/// ⛔ THE TEST CALL AND THE FORWARDING CHECK EACH PLACE A REAL CALL ON THE PLATFORM'S CARRIER
/// ACCOUNT, so each is its own single flight, set before the first `await`, and neither is
/// ever retried by this client. The service limits both per day and says so in its refusal.
///
/// ⛔ THE CONSENT IS RECORDED BY THE SERVICE, in its own words for the owner's language, when
/// the test call is placed; this client sends only the phone. The step shows the same words
/// (``SetupCopy/goliveConsentWording``) beside the button.
///
/// ⚠️ THE FORWARDING CHECK IS HIDDEN WHILE THE SERVICE SAYS `available: false` (no verifier in
/// the region), and polled every two seconds while it is pending, for at most two minutes.
///
/// ⚠️ THE SUMMARY IS NOT A SUMMARY OF DEFAULTS. When the reads behind it fail it is left out,
/// rather than showing "no greeting" and "every call" for a workspace that has both.
@MainActor
@Observable
final class SetupGoLiveModel {
    enum CallStatus: Equatable {
        case calling
        case failed(String)
    }

    struct Summary: Equatable {
        let greeting: String
        let mode: String
        let ringSeconds: Int
    }

    var mobile = ""
    var businessLine = ""
    var mode: ForwardingCheckMode = .all

    private(set) var callStatus: CallStatus?
    private(set) var mobileError = false
    private(set) var isCalling = false
    private(set) var forwarding: ForwardingCheckResponse?
    private(set) var lineError = false
    private(set) var isStartingCheck = false
    private(set) var checkError: String?
    private(set) var summary: Summary?

    private let wizard: SetupWizardModel
    private let workspaces: WorkspaceRepository
    private let callHandling: CallHandlingRepository
    private let pollInterval: Duration
    private let pollLimit: Int

    init(
        wizard: SetupWizardModel,
        workspaces: WorkspaceRepository,
        callHandling: CallHandlingRepository,
        pollInterval: Duration = .seconds(2),
        pollLimit: Int = 60
    ) {
        self.wizard = wizard
        self.workspaces = workspaces
        self.callHandling = callHandling
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
    }

    var hasNumber: Bool {
        (wizard.data?.numbersHeld ?? 0) > 0
    }

    var checkIsPending: Bool {
        forwarding?.forwardingCheck?.isPending == true
    }

    // MARK: - Reading

    func load() async {
        async let forwardingRead = wizard.repository.forwardingCheck(workspaceId: wizard.workspaceId)
        async let config = workspaces.config(workspaceId: wizard.workspaceId)
        async let handling = callHandling.callHandling(workspaceId: wizard.workspaceId)
        let (forwardingResult, configResult, handlingResult) = await (forwardingRead, config, handling)
        forwarding = try? forwardingResult.get()
        if case let .success(config) = configResult, case let .success(handling) = handlingResult {
            summary = Summary(
                greeting: config.aiPersona?.greeting?.trimmed ?? "",
                mode: handling.callHandling,
                ringSeconds: handling.appRingSeconds
            )
        }
        if checkIsPending {
            await pollForwarding()
        }
    }

    // MARK: - The test call

    func callMe() async {
        guard !isCalling, hasNumber else { return }
        guard let phone = SetupWire.e164(mobile, region: wizard.region) else {
            mobileError = true
            return
        }
        isCalling = true
        defer { isCalling = false }
        mobileError = false
        callStatus = nil
        switch await wizard.repository.placeTestCall(workspaceId: wizard.workspaceId, phone: phone) {
        case .success:
            callStatus = .calling
        case let .failure(error):
            callStatus = .failed(FailureText.from(error).message)
        }
    }

    // MARK: - The forwarding check

    func startCheck() async {
        guard !isStartingCheck, !checkIsPending else { return }
        guard let line = SetupWire.e164(businessLine, region: wizard.region) else {
            lineError = true
            return
        }
        isStartingCheck = true
        lineError = false
        checkError = nil
        let result = await wizard.repository.startForwardingCheck(
            workspaceId: wizard.workspaceId,
            businessLine: line,
            mode: mode
        )
        isStartingCheck = false
        switch result {
        case let .success(response):
            forwarding = response
            await pollForwarding()
        case let .failure(error):
            checkError = FailureText.from(error).message
        }
    }

    /// ⚠️ A FAILED POLL IS RETRIED ON THE NEXT TICK, as the web's is; the limit is what ends it.
    func pollForwarding() async {
        var ticks = 0
        while checkIsPending, ticks < pollLimit, !Task.isCancelled {
            ticks += 1
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            if case let .success(next) = await wizard.repository.forwardingCheck(workspaceId: wizard.workspaceId) {
                forwarding = next
            }
        }
    }

    /// The sentence for the check on screen, or nil before the first one.
    var checkSentence: String? {
        guard let check = forwarding?.forwardingCheck else { return nil }
        if check.isPending {
            return SetupCopy.goliveCheckPending
        }
        if check.hasPassed {
            return SetupCopy.goliveCheckPassed
        }
        return check.failure == "dial_failed" ? SetupCopy.goliveCheckDialFailed : SetupCopy.goliveCheckFailed
    }

    var attemptsSentence: String? {
        guard let left = forwarding?.attemptsLeft else { return nil }
        return left == 1 ? SetupCopy.goliveAttemptsLeftOne : SetupCopy.goliveAttemptsLeft(left)
    }

    // MARK: - Finish

    func finish() async {
        await wizard.complete(.golive, as: .done)
    }
}
