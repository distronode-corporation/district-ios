import DistrictData
import DistrictModel
import Foundation
import Observation

/// Step 5, "Calls, people and bookings".
///
/// ⛔ WHO ANSWERS IS SAVED HERE, through the call-handling route the Settings screen uses
/// (``CallHandlingRepository``): `ai_first`, or `app_first` with a 5 to 30 second ring. An
/// `ai_then_app` chosen earlier in Settings is shown and kept, never offered (the web's step 5
/// offers only the two). "Only when I don't pick up" is the carrier's no-answer forward, set
/// up in step 6, and is not a mode.
///
/// ⛔ THE TRANSFER NUMBER AND THE CALENDAR ARE SHOWN HERE AND CHANGED ON THE WEB'S PAGES, IN A
/// SHEET. DistrictCore 8.5.0's tools write carries the allowlist alone (no
/// `supportPhoneNumber`), and connecting a calendar is the provider's consent screen. The
/// step reads both again when the sheet closes (``refreshAfterHandOff()``).
///
/// ⛔ CALLER PROFILES ARE AN OPT-IN THAT STARTS OFF: read strictly (only `true` is on), offered
/// only on the plans that include them (Voice Studio and DGI, the web's `dgiTierAllowed`),
/// and written only when the owner flips the switch.
@MainActor
@Observable
final class SetupCallsModel {
    enum Phase {
        case loading
        case ready
        case failed(FailureText)
    }

    private(set) var phase: Phase = .loading
    private(set) var storedMode = CallHandling.aiFirst
    private(set) var storedRing = CallHandling.defaultRingSeconds
    var mode = CallHandling.aiFirst
    var ringSeconds = CallHandling.defaultRingSeconds
    private(set) var transferNumber: String?
    private(set) var calendarName: String?
    private(set) var profilesOffered = false
    private(set) var profilesOn = false
    private(set) var isSavingAnswering = false
    private(set) var isSavingProfiles = false
    private(set) var isContinuing = false
    private(set) var answeringSaved = false
    private(set) var error: FailureText?

    private let wizard: SetupWizardModel
    private let workspaces: WorkspaceRepository
    private let callHandling: CallHandlingRepository

    init(wizard: SetupWizardModel, workspaces: WorkspaceRepository, callHandling: CallHandlingRepository) {
        self.wizard = wizard
        self.workspaces = workspaces
        self.callHandling = callHandling
    }

    /// The modes offered: the web's two, and a stored third shown as itself.
    var modes: [String] {
        storedMode == CallHandling.aiThenApp
            ? [CallHandling.aiFirst, CallHandling.appFirst, CallHandling.aiThenApp]
            : [CallHandling.aiFirst, CallHandling.appFirst]
    }

    var answeringChanged: Bool {
        mode != storedMode || (mode == CallHandling.appFirst && ringSeconds != storedRing)
    }

    // MARK: - Reading

    /// ⛔ A FAILED CALL-HANDLING OR CONFIG READ IS A RETRY, NEVER A FORM OF DEFAULTS: "every call"
    /// shown for a workspace that rings the app first would be saved back over it. The calendar
    /// read is the one that may fail alone; it then says no calendar is known.
    func load() async {
        phase = .loading
        error = nil
        // ⚠️ ONE AFTER ANOTHER, NOT `async let`: see ``SetupGoLiveModel/load()``.
        let handlingResult = await callHandling.callHandling(workspaceId: wizard.workspaceId)
        let configResult = await workspaces.config(workspaceId: wizard.workspaceId)
        let connectionsResult = await wizard.repository.connections(workspaceId: wizard.workspaceId)
        switch (handlingResult, configResult) {
        case let (.success(handling), .success(config)):
            storedMode = handling.callHandling
            storedRing = handling.appRingSeconds
            mode = handling.callHandling
            ringSeconds = handling.appRingSeconds
            transferNumber = Self.transferNumber(config)
            profilesOffered = Self.profilesOffered(tier: config.subscriptionTier)
            profilesOn = config.aiPersona?.dgiEnabled == true
            calendarName = (try? connectionsResult.get()).flatMap(Self.calendarName)
            phase = .ready
        case let (.failure(error), _), let (_, .failure(error)):
            phase = .failed(FailureText.from(error))
        }
    }

    /// After a page opened in a sheet closes: the transfer number and the calendar again, the
    /// two things those pages change.
    ///
    /// ⚠️ NOT ``load()``: that resets an answering choice not yet saved, and shows the skeleton.
    /// A read that fails keeps what is on screen, as the wizard's own re-read does.
    func refreshAfterHandOff() async {
        guard case .ready = phase else { return }
        if case let .success(config) = await workspaces.config(workspaceId: wizard.workspaceId) {
            transferNumber = Self.transferNumber(config)
        }
        if case let .success(connections) = await wizard.repository.connections(workspaceId: wizard.workspaceId) {
            calendarName = Self.calendarName(connections)
        }
    }

    static func transferNumber(_ config: WorkspaceConfig) -> String? {
        config.toolConfig?.supportPhoneNumber.flatMap { $0.trimmed.isEmpty ? nil : $0 }
    }

    static func profilesOffered(tier: String?) -> Bool {
        ["voicestudio", "dgi"].contains((tier ?? "").lowercased())
    }

    /// The calendar the receptionist books into, by the Integrations screen's own rows, so the
    /// two screens can never disagree about it.
    static func calendarName(_ response: ConnectionsResponse) -> String? {
        IntegrationsModel.rows(from: response).first(where: \.isActiveProvider)?.provider.name
    }

    // MARK: - Writing

    /// Saves who answers; only the fields that changed are sent.
    func saveAnswering() async {
        guard answeringChanged, !isSavingAnswering else { return }
        isSavingAnswering = true
        wizard.beginStepWrite()
        defer {
            isSavingAnswering = false
            wizard.endStepWrite()
        }
        error = nil
        answeringSaved = false
        let result = await callHandling.saveCallHandling(
            workspaceId: wizard.workspaceId,
            callHandling: mode == storedMode ? nil : mode,
            appRingSeconds: mode == CallHandling.appFirst && ringSeconds != storedRing
                ? CallHandling.clampRing(ringSeconds) : nil
        )
        switch result {
        case let .success(response):
            // ⛔ THE ECHO IS THE NEW BASELINE, as on the Settings screen.
            storedMode = response.callHandling
            storedRing = response.appRingSeconds
            mode = response.callHandling
            ringSeconds = response.appRingSeconds
            answeringSaved = true
        case let .failure(error):
            self.error = FailureText.from(error)
        }
    }

    /// ⚠️ ONLY THE FLIP IS SENT. The persona route answers `dgi_requires_studio` for a plan
    /// without it, which is why the switch is only drawn on the plans that have it.
    func setProfiles(_ on: Bool) async {
        guard profilesOffered, on != profilesOn, !isSavingProfiles else { return }
        isSavingProfiles = true
        wizard.beginStepWrite()
        defer {
            isSavingProfiles = false
            wizard.endStepWrite()
        }
        error = nil
        switch await workspaces.savePersona(workspaceId: wizard.workspaceId, dgiEnabled: on) {
        case .success:
            profilesOn = on
        case let .failure(error):
            self.error = FailureText.from(error)
        }
    }

    /// Saves an unsaved answering choice first, so Continue never drops one.
    func saveAndContinue() async {
        guard !isContinuing else { return }
        isContinuing = true
        wizard.beginStepWrite()
        defer {
            isContinuing = false
            wizard.endStepWrite()
        }
        if answeringChanged {
            await saveAnswering()
            guard !answeringChanged else { return }
        }
        await wizard.complete(.calls, as: .done)
    }
}
