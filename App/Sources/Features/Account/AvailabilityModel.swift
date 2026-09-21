import DistrictData
import DistrictModel
import Foundation
import Observation

/// Whether the signed-in person can be rung for one workspace's calls.
///
/// ⛔ IT IS A FACT ABOUT YOU IN ONE WORKSPACE, NOT ABOUT YOUR ACCOUNT, AND THE UI HAS TO
/// SAY WHICH. The same person can be available in one workspace and not in another, so a
/// bare "Available for calls" switch on an account screen is a claim this value does not
/// make. ``AvailabilityStatus/workspaceName`` exists so the row can name its scope.
///
/// ⛔ AND IT WRITES ONLY YOUR OWN MEMBERSHIP ROW. `PATCH workspace/availability` takes no
/// email and no user id — see ``CallHandlingRepository/saveAvailability(workspaceId:availableForCalls:)``
/// — so nothing here can express "set a colleague's availability" and no screen built on
/// it may imply otherwise.
struct AvailabilityStatus {
    let workspaceId: String
    let workspaceName: String
    let available: Bool

    /// ⛔ NIL MEANS "NOTHING TO EXPLAIN", WHICH IS THE ONLY STATE WITH A LIVE SWITCH. The
    /// route answers a **200** carrying `false` plus a reason for a viewer and for somebody
    /// with no `WorkspaceMember` row, so a screen that read `available` alone would draw a
    /// working toggle for someone the server will never ring. See ``AvailabilityReason``.
    let reason: String?

    var canToggle: Bool {
        reason == nil
    }
}

/// What the account screen's availability row is showing.
///
/// ⛔ `noWorkspace` IS NOT A FAILURE AND IS NOT AN EMPTY READY STATE. The account screen
/// is reachable when no workspace resolves at all (it has to be — sign-out and account
/// deletion live there), and availability is meaningless without one. The row is simply
/// not drawn, which is different from "we could not look".
enum AvailabilityState {
    case loading
    case noWorkspace
    case ready(AvailabilityStatus)
    case failed(FailureText)
}

/// The availability row on the account screen.
///
/// ⛔ IT RESOLVES THE WORKSPACE ITSELF, WHICH IS A CONSTRAINT RATHER THAN A DESIGN.
/// ``ShellView`` builds ``AccountView`` with the container and the session and no
/// ``WorkspaceSessionModel``, so the model cannot be handed one. ⛔ WHAT IT DOES **NOT**
/// DO IS RE-IMPLEMENT THE SELECTION PRECEDENCE: it drives a ``WorkspaceSessionModel`` of
/// its own instead. That precedence (this device's choice, then the account default, then the server's index 0, each
/// resolved against the list the server just sent) is exactly the rule a second copy would
/// get wrong, and the shell's own ⛔ says never to re-sort and re-derive it.
///
/// ⚠️ THE COST IS ONE EXTRA `workspace/list` READ WHEN THE ACCOUNT TAB OPENS. Stated
/// plainly rather than hidden: it is an idempotent GET with no side effects, the selection
/// store it reads is shared through `UserDefaults` so the two models cannot disagree about
/// which workspace is active, and the alternative was a duplicated precedence rule. If
/// ``AccountView`` is ever given the shell's session model, delete the local one and take
/// the entry from it.
///
/// ⛔ THE TOGGLE IS OPTIMISTIC ABOUT NOTHING. It adopts the server's echo, which carries
/// the value actually written, so a refused or partially-applied write can never leave the
/// switch claiming a state the workspace does not hold.
@MainActor
@Observable
final class AvailabilityModel {
    private(set) var state: AvailabilityState = .loading

    /// True only while a write is genuinely in flight, which is what disables the switch
    /// so one drag cannot become two writes.
    private(set) var saving = false

    /// ⛔ A FAILED WRITE'S SENTENCE, SEPARATE FROM ``state``. A refusal must not blank the
    /// row: the value on screen is still the last one the server confirmed, and replacing
    /// it with an error would lose the only true thing on the row.
    private(set) var writeFailure: FailureText?

    private let repository: CallHandlingRepository
    private let workspaces: WorkspaceSessionModel

    init(container: AppContainer) {
        repository = container.callHandling
        workspaces = WorkspaceSessionModel(container: container)
    }

    /// Resolve the workspace, then read this person's availability in it.
    func load() async {
        state = .loading
        writeFailure = nil
        await workspaces.load()
        guard let entry = workspaces.selectedEntry else {
            // ⛔ EVERY VACANT AND FAILED LIST STATE LANDS HERE, INCLUDING THE FAILURES. A
            // list we could not read is not an availability problem, and reporting it on
            // this row would put a workspace-wide outage under a personal switch. The row
            // disappears; the rest of the account screen is unaffected.
            state = .noWorkspace
            return
        }
        switch await repository.availability(workspaceId: entry.id) {
        case let .success(response):
            state = .ready(AvailabilityStatus(
                workspaceId: entry.id,
                workspaceName: entry.name,
                available: response.availableForCalls,
                reason: response.reason
            ))
        case let .failure(error):
            state = .failed(FailureText.from(error))
        }
    }

    /// Make yourself available, or not.
    ///
    /// ⛔ REFUSED WHEN THE READ CARRIED A REASON. A viewer and somebody with no member row
    /// both get a 200 with `available: false`, so the only thing stopping a write that
    /// cannot succeed is this guard plus the switch being drawn as a line of text instead.
    func setAvailable(_ value: Bool) async {
        guard !saving else { return }
        guard case let .ready(status) = state, status.canToggle else { return }
        saving = true
        writeFailure = nil
        let result = await repository.saveAvailability(
            workspaceId: status.workspaceId,
            availableForCalls: value
        )
        saving = false
        switch result {
        case let .success(response):
            // ⛔ THE SERVER'S VALUE, NOT THE ONE ASKED FOR. The PATCH echoes what it wrote.
            state = .ready(AvailabilityStatus(
                workspaceId: status.workspaceId,
                workspaceName: status.workspaceName,
                available: response.availableForCalls,
                reason: response.reason
            ))
        case let .failure(error):
            // ⚠️ THE ROW KEEPS THE LAST CONFIRMED VALUE. Nothing was written, so flipping
            // the switch back is the honest thing to draw; the sentence goes beside it.
            writeFailure = FailureText.from(error)
        }
    }

    func dismissFailure() {
        writeFailure = nil
    }
}

/// Every sentence the availability row says.
///
/// ⛔ THE TWO REASONS GET TWO SENTENCES, WHICH IS THE WHOLE POINT OF NOT COLLAPSING THEM.
/// A viewer has no business being rung and can do nothing about it; somebody with no
/// `WorkspaceMember` row holds their role through the owner fallback and CAN be fixed, by
/// being added to the workspace properly. One generic "you are not available" line would
/// leave the second person with no idea that anything is wrong or what to ask for.
enum AvailabilityCopy {
    static let cardTitle = "Calls to you"

    static let rowTitle = "Available for calls"

    /// ⛔ NAMES THE WORKSPACE, ALWAYS. It is a per-workspace fact about you, and an
    /// unqualified switch on an account screen reads as an account-wide setting — which
    /// would be wrong in the one direction that matters, since the same person can be
    /// available elsewhere.
    static func rowSubtitle(_ workspaceName: String) -> String {
        "Ring my phone for calls in \(workspaceName)."
    }

    /// ⚠️ A VIEWER. Answered with no database read at all, and nothing they can change.
    static let reasonRole = "You are in this workspace as a viewer, so calls are never rung to you."

    /// ⛔ NOT A PERMISSION PROBLEM AND NOT AN ERROR. The person holds their role through the
    /// workspace's owner fallback, so there is no membership row to set — and the ring
    /// fan-out reads exactly that table. The remedy is somebody adding them properly, which
    /// is what this sentence asks for.
    static let reasonNoMemberRow = "You are not listed as a member of this workspace, so calls cannot "
        + "be rung to you. Ask an administrator to add you."

    /// ⚠️ A REASON THIS BUILD HAS NEVER SEEN. It says what is true (no ringing) and does not
    /// invent a cause.
    static let reasonUnknown = "Calls are not being rung to you in this workspace."

    static let loadFailed = "Could not read whether calls ring to you."
}
