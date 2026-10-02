import DistrictData
import DistrictModel
import Foundation
import Observation

/// Recording storage, the notetaker and the booking assistant: three ops behind
/// one Save.
///
/// ⛔ ONLY THE CHANGED SECTIONS ARE SENT, WHICH IS THE WEB RECORDINGS TAB'S
/// OWN BEHAVIOUR AND NOT AN OPTIMISATION. Each of the three is a separate write
/// against the workspace's 120-an-hour budget, and `settings.llm.patch` with
/// neither field is a VALID no-op — the schema marks both optional — so a client
/// that always sent all three would spend three writes to change one toggle and
/// the server would not object. Deciding not to send is the only place that can be
/// decided.
///
/// ⛔ TURNING RECORDING ON DOES NOT MAKE RECORDING WORK. An instance with no object
/// storage records meetings that then have nowhere to upload to, and nothing about
/// this call's success says which case a workspace is in —
/// ``SchedulingStorageSettings/recordingsStorageReady`` does. The toggle is
/// disabled while that is anything but `true`, and the hint says why.
///
/// ⛔ AND BOTH THE NOTETAKER AND THE ASSISTANT SCHEMAS ARE `z.strictObject`.
/// Anything else in either body — `stt_api_key` above all — is a **400 naming the
/// field**, which is the intended behaviour: silently accepting a credential a
/// customer believes they set is the worse of the two failures. That is why there
/// is no key field on this form and must not be one.
@MainActor
@Observable
final class SchedulingAutomationModel {
    private(set) var state: SchedulingWriteState = .idle
    private(set) var storage: SchedulingStorageSettings
    private(set) var notetaker: SchedulingNotetakerSettings
    private(set) var llm: SchedulingLLMSettings

    private(set) var recordingsEnabled: Bool
    private(set) var notetakerEnabled: Bool
    private(set) var assistantEnabled: Bool
    private(set) var instructions: String
    private(set) var rejected: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: () -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        storage: SchedulingStorageSettings,
        notetaker: SchedulingNotetakerSettings,
        llm: SchedulingLLMSettings,
        onSaved: @escaping () -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.storage = storage
        self.notetaker = notetaker
        self.llm = llm
        self.onSaved = onSaved
        recordingsEnabled = storage.recordingsEnabled
        notetakerEnabled = notetaker.enabled
        assistantEnabled = llm.enabled
        instructions = llm.extraInstructions
    }

    var busy: Bool {
        state.isWorking
    }

    /// ⚠️ `recordingsStorageReady` IS OPTIONAL ON THE WIRE, and an absent value is
    /// treated as NOT ready. The cautious reading is the correct one here: the
    /// failure it guards against is a customer believing meetings are being
    /// recorded when they are being dropped.
    var canEnableRecordings: Bool {
        storage.recordingsStorageReady == true
    }

    var recordingsHint: String {
        canEnableRecordings
            ? SchedulingSettingsWriteCopy.recordingsReadyHint
            : SchedulingSettingsWriteCopy.recordingsNotReadyHint
    }

    var isDirty: Bool {
        recordingsChanged || notetakerChanged || llmChanged
    }

    func editRecordings(_ value: Bool) {
        guard canEnableRecordings || !value else { return }
        recordingsEnabled = value
        clearRejection()
    }

    func editNotetaker(_ value: Bool) {
        notetakerEnabled = value
        clearRejection()
    }

    func editAssistant(_ value: Bool) {
        assistantEnabled = value
        clearRejection()
    }

    func editInstructions(_ value: String) {
        instructions = value
        clearRejection()
    }

    /// ⛔ ENFORCED HERE THOUGH THE WEB ONLY STATES IT. `settings.llm.patch` caps
    /// `extra_instructions` at 4000 server-side, and the refusal arrives as
    /// ``SchedulingAdminError/invalidParams`` carrying a field NAME and no message
    /// — nothing an operator can act on. The web lets zod refuse it; on a phone
    /// that is a dead end.
    var validationFailure: String? {
        instructions.count > SchedulingSettingsWriteCopy.assistantInstructionsLimit
            ? SchedulingSettingsWriteCopy.assistantInstructionsTooLong
            : nil
    }

    /// ⚠️ THE THREE WRITES ARE SEQUENTIAL AND THE FIRST FAILURE STOPS THE REST.
    /// They are not one transaction and cannot be made into one, so a partial save
    /// is reachable — which is why each section's own value is adopted from ITS
    /// response as it lands, rather than all three at the end. A refusal then
    /// leaves the model holding exactly what the server holds.
    func save() async {
        guard !busy, isDirty else { return }
        if let failure = validationFailure {
            rejected = failure
            return
        }
        state = .working
        do {
            if recordingsChanged {
                storage = try await admin.setRecordingsEnabled(workspaceId: workspaceId, recordingsEnabled)
                recordingsEnabled = storage.recordingsEnabled
            }
            if notetakerChanged {
                notetaker = try await admin.setNotetakerEnabled(workspaceId: workspaceId, notetakerEnabled)
                notetakerEnabled = notetaker.enabled
            }
            if llmChanged {
                llm = try await admin.updateLLMSettings(
                    workspaceId: workspaceId,
                    enabled: assistantEnabled,
                    extraInstructions: instructions
                )
                assistantEnabled = llm.enabled
                instructions = llm.extraInstructions
            }
            state = .done(SchedulingSettingsWriteCopy.automationDone)
            onSaved()
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private var recordingsChanged: Bool {
        recordingsEnabled != storage.recordingsEnabled
    }

    private var notetakerChanged: Bool {
        notetakerEnabled != notetaker.enabled
    }

    /// ⚠️ `""` CLEARS THE INSTRUCTIONS AND nil LEAVES THEM ALONE, and this form
    /// always has a string — so an emptied box really does clear them, which is
    /// what an operator who emptied it meant.
    private var llmChanged: Bool {
        assistantEnabled != llm.enabled || instructions != llm.extraInstructions
    }

    private func clearRejection() {
        rejected = nil
        if case .failed = state {
            state = .idle
        }
    }
}
