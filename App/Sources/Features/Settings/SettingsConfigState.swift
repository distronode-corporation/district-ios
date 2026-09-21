import DistrictData
import DistrictModel
import Foundation

/// Whether a workspace-settings screen has the configuration it needs in order to
/// be ALLOWED to save.
///
/// ⛔ THERE IS NO FOURTH CASE, AND ADDING ONE IS THE BUG THIS TYPE EXISTS TO
/// PREVENT. Specifically there is no "we could not load, here is an empty form
/// anyway". Three of this surface's save routes REPLACE their stored value
/// wholesale rather than merging it, so a form rendered from nothing and then saved
/// does not save nothing — it DELETES the transfer directory the voice agent routes
/// live callers through, or the agent's tool allowlist. ``failed`` therefore carries
/// no configuration: a screen in that state may offer a retry and nothing else.
///
/// ⚠️ ``ready`` HOLDS THE WHOLE ``WorkspaceConfig`` rather than the one section a
/// given screen edits, because the section is not the unit of safety. `allowedTools`
/// has to be carried back complete, including entries this client's catalog does not
/// know about.
///
/// ⚠️ Ported from Android's `ConfigState`, whose header decisions are carried over
/// rather than re-derived.
enum SettingsConfigState {
    case loading
    case ready(WorkspaceConfig)
    case failed(FailureText)

    /// ⛔ THE ONLY WAY TO REACH A CONFIGURATION, so "you cannot save what you did
    /// not load" is a question about this enum rather than a convention.
    var config: WorkspaceConfig? {
        guard case let .ready(config) = self else { return nil }
        return config
    }
}

/// What happened to one section's save.
///
/// ⛔ ``savedButStale`` IS NOT A FAILURE AND MUST NOT BE DRAWN AS ONE. None of the
/// workspace-settings writes echoes the configuration it wrote, so every save is
/// followed by a re-read — which means there is a real outcome where the WRITE
/// LANDED and the READ DID NOT. Telling the operator their change did not save is
/// the dangerous direction: they would change the form back and save again, through
/// a route that replaces its stored array wholesale, from state that is now stale.
///
/// ⚠️ ``failed`` KEEPS THE OPERATOR'S EDITS. Nothing that produces this case clears
/// a draft; a failed save that also discarded what someone typed would be two losses
/// for one fault.
enum SettingsSaveState {
    case idle
    case saving
    case saved
    /// ⛔ The write LANDED; only the read back failed. Offer a re-read, never a
    /// re-save.
    case savedButStale(FailureText)
    /// Nothing was written. The edits are still on screen and still the operator's.
    case failed(FailureText)

    /// ⚠️ True only while a write is genuinely in flight — what disables every input
    /// on the screen and what makes a second tap a no-op rather than a second write.
    var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }
}

/// The three outcomes of one write plus its mandatory re-read.
///
/// ⛔ THREE, NOT TWO, AND COLLAPSING THE MIDDLE ONE INTO A FAILURE IS THE MISTAKE.
/// See the ⛔ on ``SettingsSaveState/savedButStale(_:)``.
enum SettingsSaveOutcome {
    /// The write landed and the re-read gives the new baseline to build the NEXT
    /// save on.
    case saved(WorkspaceConfig)
    case savedButStale(FailureText)
    case notSaved(FailureText)
}

/// The one place the load-then-edit rule is implemented, shared by every section
/// that hydrates from `workspace/config`.
///
/// ⛔ A STRUCT OVER THE REPOSITORY RATHER THAN A BASE CLASS, because the models are
/// `@Observable` and a shared superclass would put observable state in a type none
/// of them owns. What is shared here is the RULE, and the rule is two functions:
/// there is exactly one way to reach a configuration, and there is exactly one way a
/// save reports itself.
///
/// ⛔ ``commit(_:)`` RE-READS ON SUCCESS BECAUSE THE ROUTES DO NOT ECHO. All four
/// workspace-settings writes answer a bare `{"success": true}`, so there is no body
/// to adopt; a caller that assumed one would keep rendering its own optimistic edit
/// as though the server had confirmed it, and the NEXT wholesale save would then be
/// built on a client-side belief. ⚠️ It does NOT re-read on a failure: nothing was
/// written, so the baseline on screen is still correct, and a second request would
/// only give a flaky network a chance to turn a clear refusal into a load failure.
///
/// ⚠️ `Sendable` AND NOT `@MainActor`: it holds a `WorkspaceRepository`, which is a
/// struct wrapping the one ``ApiClient``, so a model may await it from the main actor
/// without hopping anything but the request itself.
struct SettingsConfigGateway: Sendable {
    let workspaces: WorkspaceRepository
    let workspaceId: String

    /// ⛔ `@MainActor` ON THE INITIALISER AND NOWHERE ELSE, AND THAT IS AN ISOLATION
    /// FACT RATHER THAN A PREFERENCE. ``AppContainer`` is `@MainActor`, so its stored
    /// properties are main-actor isolated and a nonisolated initialiser may not read
    /// one; a struct's members are nonisolated by default, so this has to say so. The
    /// two methods below stay nonisolated deliberately: everything they touch is a
    /// `Sendable` value, and isolating the whole type would put the request itself on
    /// the main actor for no reason.
    @MainActor
    init(container: AppContainer, workspaceId: String) {
        workspaces = container.workspaces
        self.workspaceId = workspaceId
    }

    /// ⚠️ THE SAME TWO VALUES WITHOUT THE CONTAINER, WHICH IS WHAT MAKES A SETTINGS
    /// MODEL REACHABLE FROM A TEST. ``AppContainer`` builds the process's one token
    /// coordinator and resolves a keychain-backed store; a unit test that had to
    /// construct one in order to check which rows a save sends would be testing the
    /// wrong thing and touching the device keychain to do it. The memberwise
    /// initialiser is suppressed by the one above, so this states it.
    init(workspaces: WorkspaceRepository, workspaceId: String) {
        self.workspaces = workspaces
        self.workspaceId = workspaceId
    }

    /// Read the configuration a form hydrates from.
    ///
    /// ⛔ A FAILURE IS A FAILURE, NEVER AN EMPTY CONFIGURATION. The repository
    /// already refuses to answer success with a missing `config`; this only maps the
    /// error into copy. ⚠️ A 403 here is the viewer exclusion, which is unusual on
    /// this surface and deliberate — the payload carries staff transfer numbers and
    /// the operator's own prompt.
    func load() async -> SettingsConfigState {
        switch await workspaces.config(workspaceId: workspaceId) {
        case let .success(config):
            .ready(config)
        case let .failure(error):
            .failed(FailureText.from(error))
        }
    }

    /// Turn one write's result into the outcome a screen reports, re-reading the
    /// configuration when it landed.
    func commit(_ write: Result<Void, ApiError>) async -> SettingsSaveOutcome {
        if case let .failure(error) = write {
            return .notSaved(FailureText.from(error))
        }
        switch await workspaces.config(workspaceId: workspaceId) {
        case let .success(config):
            return .saved(config)
        case let .failure(error):
            return .savedButStale(FailureText.from(error))
        }
    }
}
