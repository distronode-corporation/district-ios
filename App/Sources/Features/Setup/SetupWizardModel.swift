import DistrictData
import DistrictModel
import Foundation
import Observation

/// The setup wizard's shell: the state the service holds, the step on screen, and the one
/// write every step ends in, its own state.
///
/// ⛔ MOST OF IT RUNS HERE, BUYING RUNS ON THE WEB (Sean, 2026-11-08: "Most in app, buying on
/// web"). The business, the receptionist, what callers should know, how calls are answered,
/// the test call and the forwarding check are this client's; buying a number, the plan, a
/// calendar sign-in, the email identity and the transfer number open the web's page in a
/// sheet, and the wizard reads its state again when the sheet closes (``refreshAfterHandOff()``).
///
/// ⛔ ONE STEP WRITE AT A TIME. ``complete(_:as:)`` is the shell's single flight: Skip, a
/// step's Continue and Finish all go through it, and a second tap while one is in flight is
/// a no-op rather than a second PATCH. The flag is set before the first `await`, on the main
/// actor, so two taps dispatched before a re-render cannot both pass the guard.
///
/// ⛔ NO MOVE WHILE A STEP IS WRITING. A step's own save awaits its write and then calls
/// ``complete(_:as:)``, so Back or Skip tapped in between would be overtaken by that late
/// completion (Back undone, or the step skipped over its own save). Each step write holds
/// ``beginStepWrite()`` to its end, and ``isMoving`` disables the shell's moves until then.
///
/// ⚠️ THE REPOSITORY IS THE TEST SEAM, as on ``IntegrationsModel``: a test drives a real
/// repository over a canned transport.
@MainActor
@Observable
final class SetupWizardModel {
    enum Phase {
        case loading
        case refused(SetupRefusal)
        case failed(FailureText)
        case ready
        /// Every step is done or skipped and the service stamped `completedAt`.
        case finished
    }

    private(set) var phase: Phase = .loading
    /// The service's last answer: progress, facts, region, plan, numbers.
    private(set) var data: DistrictSetupResponse?
    private(set) var active: SetupStep = .business
    /// The last step write's refusal, shown on the step it was for.
    private(set) var stepError: FailureText?
    private(set) var isCompleting = false
    /// Step writes in flight; see ``beginStepWrite()``.
    private(set) var stepWrites = 0
    /// Bumped each time a page opened in a sheet closes, so a step showing state that page
    /// changes (step 5's transfer number and calendar) reads it again.
    private(set) var handOffsClosed = 0
    /// What step 1 learned; see ``SetupBusinessDraft``.
    private(set) var draft: SetupBusinessDraft

    let workspaceId: String
    /// The workspace's name as the service holds it: the name it opened with, then each rename's
    /// echo, so step 1 renames whenever the typed name differs from the stored one.
    private(set) var workspaceName: String
    let repository: SetupWizardRepository
    private let store: SetupDraftStore
    /// The persona's stored `language`, nil when it cannot be read.
    private let personaLanguage: @Sendable () async -> String?

    init(
        repository: SetupWizardRepository,
        workspaceId: String,
        workspaceName: String,
        store: SetupDraftStore = SetupDraftStore(defaults: .standard),
        personaLanguage: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.store = store
        self.personaLanguage = personaLanguage
        draft = store.load(workspaceId: workspaceId)
            ?? SetupBusinessDraft.initial(data: nil, personaLanguage: nil, workspaceName: workspaceName)
    }

    convenience init(container: AppContainer, workspaceId: String, workspaceName: String) {
        let workspaces = container.workspaces
        self.init(
            repository: SetupWizardRepository(client: container.api),
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            personaLanguage: { try? await workspaces.config(workspaceId: workspaceId).get().aiPersona?.language }
        )
    }

    var region: String? {
        data?.region
    }

    func state(of step: SetupStep) -> SetupStepState? {
        data?.setupProgress?.steps?.state(of: step)
    }

    // MARK: - Reading

    /// Opens the wizard where the person left off: the first step still `todo`.
    func load() async {
        phase = .loading
        switch await repository.load(workspaceId: workspaceId) {
        case let .success(response):
            guard response.setupProgress != nil else {
                phase = .refused(.notAvailable)
                return
            }
            data = response
            // ⛔ STEP 1'S LANGUAGE OPENS ON THE PERSONA'S, as the web's `initialBusinessDraft` does:
            // opening it on the app's language would let step 3 replace a French receptionist's
            // `fr-CA` with `en-US` for an owner who never touched the choice.
            if store.load(workspaceId: workspaceId) == nil {
                draft = await SetupBusinessDraft.initial(
                    data: response,
                    personaLanguage: personaLanguage(),
                    workspaceName: workspaceName
                )
            }
            if response.setupProgress?.completedAt != nil {
                phase = .finished
                return
            }
            active = SetupFlow.firstOpen(response.setupProgress)
            phase = .ready
        case let .failure(error):
            if let refusal = SetupRefusal.from(error) {
                phase = .refused(refusal)
            } else {
                phase = .failed(FailureText.from(error))
            }
        }
    }

    /// After a page opened in a sheet closes: read again, and move on if the web finished the
    /// step on screen (a number bought there marks `number` done).
    ///
    /// ⚠️ A FAILED RE-READ KEEPS THE STEP ON SCREEN. Nothing was written here, so the last
    /// answer is still the best one this client has; the step's own controls retry.
    ///
    /// ⛔ ONLY A STEP THE PAGE FINISHED MOVES ON. A step that was already done or skipped (reached
    /// by Back) stays on screen with whatever the person typed into it; only a `todo` that came
    /// back not `todo` advances.
    func refreshAfterHandOff() async {
        guard case .ready = phase else { return }
        defer { handOffsClosed += 1 }
        let step = active
        let before = state(of: step)
        guard case let .success(response) = await repository.load(workspaceId: workspaceId) else { return }
        data = response
        if response.setupProgress?.completedAt != nil {
            phase = .finished
        } else if before == .todo, state(of: step) != .todo, active == step {
            active = SetupFlow.firstOpen(response.setupProgress)
        }
    }

    /// A step saved something through the setup route, which answers the whole state.
    func adopt(_ response: DistrictSetupResponse) {
        data = response
    }

    func renamed(to name: String) {
        workspaceName = name
    }

    func updateDraft(_ next: SetupBusinessDraft) {
        draft = next
        store.save(next, workspaceId: workspaceId)
    }

    // MARK: - Moving

    /// A step write or a move in flight: Back, Skip and Finish later wait for it.
    var isMoving: Bool {
        isCompleting || stepWrites > 0
    }

    /// A step's write starts; pair it with ``endStepWrite()`` in a `defer`.
    func beginStepWrite() {
        stepWrites += 1
    }

    func endStepWrite() {
        stepWrites -= 1
    }

    /// Marks `step` and moves to the next one; true when the write landed.
    ///
    /// ⛔ THE ONLY WAY A STEP'S STATE CHANGES. A step that saved its own data calls this with
    /// `.done`; Skip calls it with `.skipped`. When the service answers with `completedAt`,
    /// the wizard is finished and the draft kept on this device is dropped.
    @discardableResult
    func complete(_ step: SetupStep, as state: SetupStepState) async -> Bool {
        guard !isCompleting else { return false }
        isCompleting = true
        defer { isCompleting = false }
        stepError = nil
        switch await repository.save(workspaceId: workspaceId, steps: [step: state]) {
        case let .success(response):
            data = response
            if response.setupProgress?.completedAt != nil {
                store.clear(workspaceId: workspaceId)
                phase = .finished
            } else {
                // ⚠️ PAST THE LAST STEP WITH ONE STILL OPEN (reached by Back), the open one.
                active = SetupFlow.next(after: step) ?? SetupFlow.firstOpen(response.setupProgress)
            }
            return true
        case let .failure(error):
            stepError = FailureText.from(error)
            return false
        }
    }

    func skip() async {
        guard !isMoving else { return }
        await complete(active, as: .skipped)
    }

    func back() {
        guard !isMoving, let previous = SetupFlow.previous(before: active) else { return }
        stepError = nil
        active = previous
    }

    func dismissStepError() {
        stepError = nil
    }
}
