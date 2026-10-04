import DistrictData
import DistrictModel
import Foundation
import Observation

/// The booking assistant: its switch and its extra instructions, behind one Save.
///
/// ⚠️ THIS SHEET HELD THREE SECTIONS UNTIL 2026-10-03: recording storage, the
/// notetaker and the assistant. The server retired the first two with meeting
/// recording (`settings.storage.*` and `settings.notetaker.*` answer `unknown_op`),
/// and the web's settings tab became "Booking assistant" with the same single form.
///
/// ⛔ NOTHING IS SENT WHEN NOTHING MOVED, WHICH IS THE WEB TAB'S OWN BEHAVIOUR AND
/// NOT AN OPTIMISATION. `settings.llm.patch` with an unchanged body is a VALID no-op,
/// and it still spends a write from the workspace's 120-an-hour budget.
///
/// ⛔ AND THE ASSISTANT SCHEMA IS `z.strictObject`. Anything else in the body (an
/// API key above all) is a **400 naming the field**, which is the intended
/// behaviour: silently accepting a credential a customer believes they set is the
/// worse of the two failures. That is why there is no key field on this form and
/// must not be one.
@MainActor
@Observable
final class SchedulingAutomationModel {
    private(set) var state: SchedulingWriteState = .idle
    private(set) var llm: SchedulingLLMSettings

    private(set) var assistantEnabled: Bool
    private(set) var instructions: String
    private(set) var rejected: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: () -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        llm: SchedulingLLMSettings,
        onSaved: @escaping () -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.llm = llm
        self.onSaved = onSaved
        assistantEnabled = llm.enabled
        instructions = llm.extraInstructions
    }

    var busy: Bool {
        state.isWorking
    }

    var isDirty: Bool {
        llmChanged
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

    /// ⚠️ THE SAVED VALUES ARE ADOPTED FROM THE RESPONSE, not from the form, so a
    /// value the server normalised is what the sheet shows afterwards.
    func save() async {
        guard !busy, isDirty else { return }
        if let failure = validationFailure {
            rejected = failure
            return
        }
        state = .working
        do {
            llm = try await admin.updateLLMSettings(
                workspaceId: workspaceId,
                enabled: assistantEnabled,
                extraInstructions: instructions
            )
            assistantEnabled = llm.enabled
            instructions = llm.extraInstructions
            state = .done(SchedulingSettingsWriteCopy.automationDone)
            onSaved()
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
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
