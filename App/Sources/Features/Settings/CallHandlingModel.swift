import DistrictData
import DistrictModel
import Foundation
import Observation

/// One workspace's answering setting, as the screen holds it.
///
/// ⚠️ TWO SCALARS RATHER THAN THE RESPONSE DTO, so the DRAFT and the BASELINE are the
/// same type and can be compared. `success` has nothing to do with either.
struct CallHandlingSetting: Equatable {
    var mode: String
    var ringSeconds: Int
}

/// The read behind the "how calls are answered" screen.
///
/// ⛔ THERE IS NO CASE FOR "we could not load, here is a control anyway", and the reason
/// is milder here than on the rest of this surface but still real. `workspace/call-handling`
/// writes SCALARS and its PATCH accepts either field alone, so an empty save cannot delete
/// an array the way `saveTools` or `saveDirectory` can — but a picker seeded from a guess
/// would still let an operator "confirm" a mode they never chose, and the mode decides
/// whether their phone rings at all.
enum CallHandlingState {
    case loading
    case ready(CallHandlingSetting)
    case failed(FailureText)
}

/// How this workspace answers a call, and how long the app is given to.
///
/// ⛔ THE PATCH ECHOES WHAT IT WROTE, WHICH MAKES THIS THE ONE SCREEN ON THIS SURFACE
/// WITH NO RE-READ AND THEREFORE NO ``SettingsSaveState/savedButStale(_:)`` STATE. Every
/// other workspace-settings save answers a bare `{"success": true}` and has to ask again;
/// this one adopts its own response as the new baseline. A caller that copied the re-read
/// would spend a request to learn what it had already been told, and would invent a
/// failure mode that cannot happen.
///
/// ⛔ ONLY WHAT CHANGED IS SENT, AND THAT IS NOT AN OPTIMISATION. A workspace can hold a
/// mode this build has never heard of — the server normalises an unrecognised STORED value
/// on the way OUT but refuses an unrecognised one on the way IN — so a save that posted
/// the whole form would take an operator who nudged the ring duration and hand them a
/// 400 about a mode they never touched. Sending only the changed field leaves it alone.
///
/// ⛔ AND THE ROLE IS RE-CHECKED AT THE WRITE'S CALL SITE, NOT ONLY WHERE THE BUTTON IS
/// DRAWN. A control that was not drawn is not a boundary; the read admits a viewer and
/// the write refuses one, so this screen is reachable read-only by design.
///
/// ⚠️ TAKES THE CONTAINER, like every other model here, so the one ``ApiClient`` and its
/// two credential closures cannot be bypassed.
@MainActor
@Observable
final class CallHandlingModel {
    private(set) var load: CallHandlingState = .loading

    /// What the operator has changed, or nil before the first successful read.
    ///
    /// ⛔ SEPARATE FROM THE BASELINE SO "WHAT CHANGED" IS ANSWERABLE. One value would
    /// make every save a full-form post, which is the thing the ⛔ on this type forbids.
    private(set) var draft: CallHandlingSetting?

    private(set) var save: SettingsSaveState = .idle

    /// ⚠️ FROM THE ROLE THE ROUTE ALREADY RESOLVED, and fail-closed on nil — see
    /// ``WorkspaceRole/allowsMutation(_:)``.
    let canWrite: Bool

    private let repository: CallHandlingRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        repository = container.callHandling
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    /// ⚠️ AN IDEMPOTENT GET WITH NO SIDE EFFECTS, so replaying it costs nothing and the
    /// retry button is honest.
    func load() async {
        load = .loading
        switch await repository.callHandling(workspaceId: workspaceId) {
        case let .success(response):
            let setting = CallHandlingSetting(
                mode: response.callHandling,
                ringSeconds: response.appRingSeconds
            )
            load = .ready(setting)
            draft = setting
        case let .failure(error):
            load = .failed(FailureText.from(error))
            // ⛔ THE DRAFT IS DISCARDED ON A FAILED RE-READ. Keeping it would leave a
            // live picker sitting on a baseline this client can no longer vouch for.
            draft = nil
        }
    }

    /// ⛔ REFUSED FOR A MODE THIS BUILD CANNOT SEND. The picker only offers the three it
    /// knows, so this is unreachable from the UI; it is the guard that keeps it that way
    /// if a fourth is ever added to the list without being added to the copy.
    func select(mode: String) {
        guard canWrite, CallHandling.isKnown(mode) else { return }
        guard var next = draft else { return }
        next.mode = mode
        draft = next
    }

    /// ⛔ CLAMPED HERE RATHER THAN REFUSED AT THE REPOSITORY. The stepper's own bounds
    /// stop this being reachable; clamping means a stepper wired one off cannot produce a
    /// 400 the operator would read as a refusal of something they typed.
    func setRing(_ seconds: Int) {
        guard canWrite else { return }
        guard var next = draft else { return }
        next.ringSeconds = CallHandling.clampRing(seconds)
        draft = next
    }

    /// Whether there is anything to save.
    ///
    /// ⚠️ FALSE WHEN NOTHING CHANGED, which is what keeps the button from spending a
    /// request that the route would answer 400 for an empty body.
    var isDirty: Bool {
        guard let draft, case let .ready(baseline) = load else { return false }
        return draft != baseline
    }

    var canSave: Bool {
        canWrite && isDirty && !save.isSaving
    }

    /// Send only what changed, then adopt the echo.
    func saveChanges() async {
        guard canWrite, !save.isSaving else { return }
        guard let draft, case let .ready(baseline) = load, draft != baseline else { return }
        save = .saving
        let result = await repository.saveCallHandling(
            workspaceId: workspaceId,
            callHandling: draft.mode == baseline.mode ? nil : draft.mode,
            appRingSeconds: draft.ringSeconds == baseline.ringSeconds ? nil : draft.ringSeconds
        )
        switch result {
        case let .success(response):
            // ⛔ THE SERVER'S VALUES, NOT THE DRAFT'S. They arrive normalised, so adopting
            // the echo is what stops the screen claiming a value the workspace does not
            // hold.
            let adopted = CallHandlingSetting(
                mode: response.callHandling,
                ringSeconds: response.appRingSeconds
            )
            load = .ready(adopted)
            self.draft = adopted
            save = .saved
        case let .failure(error):
            // ⚠️ THE DRAFT IS KEPT. Nothing was written, and a failed save that also
            // discarded the operator's edits would be two losses for one fault.
            save = .failed(FailureText.from(error))
        }
    }

    /// ⛔ THE ONLY WAY A BANNER LEAVES THE SCREEN WITHOUT ANOTHER WRITE. Every model on
    /// this surface has one; the ones that had no caller left a stale refusal beside a
    /// fresh "Saved." with nothing to press.
    func dismissNotices() {
        save = .idle
    }
}
