import DistrictData
import DistrictModel
import Foundation
import Observation

/// One booking question as the form holds it.
///
/// ⚠️ `id` nil MEANS CREATE. The two ops take the same fields; only the presence
/// of the question's own id decides which one runs.
struct SchedulingQuestionForm: Equatable {
    var id: String?
    var label = ""
    var type = "text"
    var options: [String] = []
    var required = false
    var position = "0"

    var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⛔ SENT ONLY FOR A `select`, WHICH IS THE WEB'S RULE AND IS COPIED RATHER
    /// THAN IMPROVED ON. The catalog does NOT refuse `options` on a `text`, so
    /// sending `[]` there would be legal and would clear a stored list — tidier,
    /// and a different answer from the browser's for the same action, on rows both
    /// clients edit. ⚠️ The consequence is real and is the fork's rather than ours:
    /// a question that was a `select` and became a `text` KEEPS its options
    /// server-side, invisibly, because nil is "leave alone" on the patch schema.
    var wireOptions: [String]? {
        type == "select" ? options : nil
    }

    var error: String? {
        if trimmedLabel.isEmpty {
            return SchedulingWriteCopy.questionLabelMissing
        }
        if type == "select", options.isEmpty {
            return SchedulingWriteCopy.questionNeedsOption
        }
        if SchedulingEventTypeForm.whole(position, atLeast: 0) == nil {
            return SchedulingWriteCopy.questionPositionInvalid
        }
        return nil
    }
}

/// The booking form's questions: list, add, edit, reorder, delete.
///
/// ⛔ EVERY CHANGE IS ITS OWN REQUEST AND THERE IS NO SAVE BUTTON, which is the
/// web's arrangement. These are independent rows behind independent ops; a batched
/// save would have to decide what to do when the third of five is refused, and the
/// honest answers are all worse than four rows having saved and one having said so.
///
/// ⛔ REORDERING IS A PATCH OF ONE ROW'S `position`, NOT A RENUMBERING OF THE
/// LIST. The web does the same, and the consequence is worth knowing: positions
/// may collide and may have gaps. Sorting is `position` ascending on both clients,
/// so a collision renders in whatever order the list arrived — untidy, and far
/// cheaper than five writes to move one question.
///
/// ⚠️ THE LIST IS RE-READ AFTER EVERY WRITE. The create op answers the created row
/// and the patch the updated one, but neither can say where it now sits among its
/// siblings, and that is the thing on screen.
@MainActor
@Observable
final class SchedulingEventTypeQuestionsModel {
    private(set) var questions: [SchedulingQuestion] = []
    private(set) var loadState: SchedulingWriteState = .idle
    private(set) var state: SchedulingWriteState = .idle
    private(set) var validation: String?
    private(set) var notice: String?

    /// The editor sheet's contents, or nil when it is closed.
    private(set) var editing: SchedulingQuestionForm?
    /// The question a confirmation dialog is about, or nil.
    private(set) var confirmingDelete: SchedulingQuestion?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let slug: String
    private let onSaved: ([SchedulingQuestion]) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        slug: String,
        onSaved: @escaping ([SchedulingQuestion]) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.slug = slug
        self.onSaved = onSaved
    }

    var isEditing: Bool {
        editing != nil
    }

    var editorTitle: String {
        editing?.id == nil ? SchedulingWriteCopy.questionAddTitle : SchedulingWriteCopy.questionEditTitle
    }

    func load() async {
        loadState = .saving
        do {
            questions = try await admin.eventTypeQuestions(workspaceId: workspaceId, slug: slug)
                .sorted { $0.position < $1.position }
            loadState = .saved
        } catch {
            loadState = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    // MARK: - The editor sheet

    /// ⚠️ A NEW QUESTION OPENS AT THE END OF THE LIST rather than at 0, which is
    /// what "Add question" means. A literal 0 would insert it at the top.
    func beginAdd() {
        var form = SchedulingQuestionForm()
        form.position = String(questions.count)
        editing = form
        validation = nil
    }

    func beginEdit(_ question: SchedulingQuestion) {
        editing = SchedulingQuestionForm(
            id: question.id,
            label: question.label,
            type: question.type,
            options: question.options ?? [],
            required: question.required,
            position: String(question.position)
        )
        validation = nil
    }

    func updateEditing(_ transform: (inout SchedulingQuestionForm) -> Void) {
        guard var form = editing else { return }
        transform(&form)
        editing = form
    }

    func cancelEdit() {
        editing = nil
        validation = nil
    }

    /// ⚠️ A DUPLICATE IS IGNORED IN SILENCE, as on the web. It is not an error, and
    /// a sentence for it would be a complaint about a no-op.
    func addOption(_ option: String) {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateEditing { form in
            guard !form.options.contains(trimmed) else { return }
            form.options.append(trimmed)
        }
    }

    func removeOption(_ option: String) {
        updateEditing { form in
            form.options.removeAll { $0 == option }
        }
    }

    func beginDelete(_ question: SchedulingQuestion) {
        confirmingDelete = question
    }

    func cancelDelete() {
        confirmingDelete = nil
    }

    func dismissNotice() {
        notice = nil
        validation = nil
        state = .idle
    }

    // MARK: - The writes

    func submit() async {
        guard let form = editing, !state.isSaving else { return }
        if let error = form.error {
            validation = error
            return
        }
        guard let position = SchedulingEventTypeForm.whole(form.position, atLeast: 0) else { return }
        validation = nil
        state = .saving
        do {
            if let id = form.id {
                try await patch(form: form, id: id, position: position)
            } else {
                try await create(form: form, position: position)
            }
            editing = nil
            await reread()
        } catch {
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    private func create(form: SchedulingQuestionForm, position: Int) async throws {
        var draft = SchedulingQuestionDraft(
            label: form.trimmedLabel,
            type: form.type,
            required: form.required
        )
        draft.options = form.wireOptions
        draft.position = position
        _ = try await admin.createEventTypeQuestion(workspaceId: workspaceId, slug: slug, draft: draft)
        state = .saved
        notice = SchedulingWriteCopy.questionAdded
    }

    private func patch(form: SchedulingQuestionForm, id: String, position: Int) async throws {
        var changes = SchedulingQuestionChanges()
        changes.label = form.trimmedLabel
        changes.type = form.type
        changes.options = form.wireOptions
        changes.required = form.required
        changes.position = position
        _ = try await admin.patchEventTypeQuestion(
            workspaceId: workspaceId,
            slug: slug,
            id: id,
            changes: changes
        )
        state = .saved
        notice = SchedulingWriteCopy.questionSaved
    }

    /// Move one question, by writing only its own `position`.
    func reposition(_ question: SchedulingQuestion, to position: Int) async {
        guard !state.isSaving, position >= 0, position != question.position else { return }
        state = .saving
        var changes = SchedulingQuestionChanges()
        changes.position = position
        do {
            _ = try await admin.patchEventTypeQuestion(
                workspaceId: workspaceId,
                slug: slug,
                id: question.id,
                changes: changes
            )
            state = .saved
            await reread()
        } catch {
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    func delete() async {
        guard let question = confirmingDelete, !state.isSaving else { return }
        confirmingDelete = nil
        state = .saving
        do {
            try await admin.deleteEventTypeQuestion(workspaceId: workspaceId, slug: slug, id: question.id)
            state = .saved
            notice = SchedulingWriteCopy.questionDeleted
            await reread()
        } catch {
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    /// ⛔ A FAILED RE-READ DOES NOT BECOME A FAILED WRITE. The change LANDED; the
    /// list is merely out of date, and telling somebody their question did not save
    /// is what makes them add it twice.
    private func reread() async {
        do {
            questions = try await admin.eventTypeQuestions(workspaceId: workspaceId, slug: slug)
                .sorted { $0.position < $1.position }
            onSaved(questions)
        } catch {
            loadState = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }
}
