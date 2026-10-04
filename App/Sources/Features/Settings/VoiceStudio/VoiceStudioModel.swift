import DistrictData
import DistrictModel
import Foundation
import Observation

/// The Studio's read, before and after it lands.
enum VoiceStudioLoadState {
    case loading
    /// ⛔ A FAILED READ OFFERS A RETRY AND NOTHING EDITABLE: without the catalogue there is
    /// nothing an edit could be checked against, and the PATCH refuses a chain it does not
    /// accept.
    case failed(FailureText)
    case ready(VoiceStudioSession)
}

/// What the last save did.
enum VoiceStudioSaveState {
    case idle
    case saving
    /// Written, read back, and the re-read holds what was sent: the server's `saved` label.
    case saved
    /// ⛔ WRITTEN WITH A 200, AND THE RE-READ DOES NOT HOLD WHAT WAS SENT. The PATCH ignores
    /// some values silently; the server's `saveFailed` label is shown over the re-read state,
    /// which is what the workspace really runs now.
    case mismatch
    /// ⛔ Written; only the re-read failed. Not a failure: told "not saved", an operator would
    /// save again from a state this client can no longer vouch for.
    case savedButStale(FailureText)
    /// Nothing was written (a refused chain is one of these). The edits are kept.
    case failed(FailureText)

    var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }
}

/// The native Voice Studio: one read, local edits, a save through the persona PATCH, then the
/// read again. Ported from Android's `VoiceStudioViewModel`; every rule it routes to lives in
/// `DistrictData` (``VoiceStudioSession`` and its neighbours), where it is tested on Linux.
///
/// ⛔ SINGLE FLIGHT, AND NOTHING MOVES WHILE A SAVE IS IN THE AIR. A second tap before the
/// first request returns is dropped, and every edit is refused while saving: the request was
/// built from the state on screen, and an edit landing mid-request would make the outcome
/// describe something the screen no longer shows. ⚠️ Choosing which leg to LOOK at is not an
/// edit and is allowed.
///
/// ⛔ ONLY CHANGED KEYS ARE SENT (``VoiceStudioRules/changedKeys(saved:current:)``), so a
/// teammate's save of a key this screen never touched is not undone, and after every 200 the
/// Studio is read back and compared with what was sent.
@MainActor
@Observable
final class VoiceStudioModel {
    private(set) var load: VoiceStudioLoadState = .loading
    private(set) var save: VoiceStudioSaveState = .idle

    /// ⚠️ A VIEWER NEVER REACHES THIS SCREEN (the read excludes one, and ``RouteGate`` hides
    /// the row), but a control that was not drawn is not a boundary, so every edit is gated
    /// here too.
    let canWrite: Bool

    private let repository: VoiceStudioRepository
    private let workspaceId: String

    /// ⚠️ THE REPOSITORY RATHER THAN THE CONTAINER, so a test drives a real repository over a
    /// stub transport without building an ``AppContainer``.
    init(repository: VoiceStudioRepository, workspaceId: String, role: WorkspaceRole?) {
        self.repository = repository
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    convenience init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.init(repository: container.voiceStudio, workspaceId: workspaceId, role: role)
    }

    var session: VoiceStudioSession? {
        guard case let .ready(session) = load else { return nil }
        return session
    }

    var canSave: Bool {
        canWrite && !save.isSaving && session?.isDirty == true
    }

    /// Whether the controls take edits now.
    var canEdit: Bool {
        canWrite && !save.isSaving && session != nil
    }

    // MARK: - The read

    func loadStudio() async {
        load = .loading
        save = .idle
        switch await repository.load(workspaceId: workspaceId) {
        case let .success(studio):
            load = .ready(VoiceStudioSession(studio: studio))
        case let .failure(error):
            load = .failed(FailureText.from(error))
        }
    }

    // MARK: - Edits

    func selectTier(_ tier: String) {
        edit { $0.withTier(tier) }
    }

    func applyRecipe(_ id: String) {
        edit { $0.withRecipe(id) }
    }

    func reset() {
        edit { $0.withReset() }
    }

    /// ⚠️ Not an edit: choosing which leg to look at is allowed mid-save.
    func selectLeg(_ leg: VoiceStudioLeg) {
        guard let session else { return }
        load = .ready(session.withLeg(leg))
    }

    func editMix(_ transform: (EngineMix) -> EngineMix) {
        edit { $0.withMix(transform) }
    }

    func updateHeld(_ transform: (VoiceStudioState) -> VoiceStudioState) {
        edit { $0.withHeld(transform($0.held)) }
    }

    private func edit(_ transform: (VoiceStudioSession) -> VoiceStudioSession) {
        guard canEdit, let session else { return }
        load = .ready(transform(session))
        // A new edit retires the previous save's banner: "Saved" over a dirty Studio would be
        // a claim about a state that no longer exists.
        save = .idle
    }

    // MARK: - The save

    /// Send the changed keys, then read the Studio back.
    ///
    /// ⛔ NOTHING IS SENT WHEN NOTHING CHANGED: a body carrying only `workspaceId` still spends
    /// one of thirty writes a minute.
    func saveChanges() async {
        guard canSave, let session else { return }
        let sent = session.heldFields
        let keys = session.pending
        save = .saving
        let outcome = await repository.save(workspaceId: workspaceId, fields: sent, keys: keys)
        switch outcome {
        case let .saved(studio):
            load = .ready(VoiceStudioSession(studio: studio))
            save = VoiceStudioRules.landed(sent: sent, keys: keys, reread: studio.current.fields)
                ? .saved
                : .mismatch
        case let .savedButStale(error):
            save = .savedButStale(FailureText.from(error))
        case let .notSaved(refusal):
            save = .failed(Self.failure(refusal))
        }
    }

    /// ⛔ THE TWO STUDIO REFUSALS ARE SAID AS WHAT THEY ARE, NOT AS A GENERIC 400. The
    /// service's own sentence is used when it sent one.
    static func failure(_ refusal: VoiceStudioRefusal) -> FailureText {
        switch refusal {
        case let .invalidEngineMix(message):
            FailureText(message: Self.nonEmpty(message) ?? VoiceStudioCopy.invalidEngineMix, action: .none)
        case let .modelUnavailableInRegion(message):
            FailureText(message: Self.nonEmpty(message) ?? VoiceStudioCopy.modelUnavailableInRegion, action: .none)
        case let .failed(error):
            FailureText.from(error)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
