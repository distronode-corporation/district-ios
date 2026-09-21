import DistrictModel
import SwiftUI

/// The booking form's questions, and the sheet that edits one of them.
///
/// ⛔ NO SAVE BUTTON ON THE LIST, BECAUSE EVERY CHANGE IS ITS OWN REQUEST. Adding,
/// editing, moving and deleting are four independent ops behind four independent
/// rows; a batched save would have to decide what to do when the third of five is
/// refused, and every answer to that is worse than four rows having saved.
///
/// ⚠️ MOVING A QUESTION WRITES ONLY ITS OWN `position`. Positions may therefore
/// collide and may have gaps — the web behaves the same way, and the alternative
/// is five writes to move one question.
struct SchedulingEventTypeQuestionsSheet: View {
    let model: SchedulingEventTypeQuestionsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                header
                list
                messages
                Button(SchedulingWriteCopy.cancel) {
                    dismiss()
                }
                .buttonStyle(.districtGhost)
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.questionsRoot)
        .task {
            await model.load()
        }
        .sheet(isPresented: editorPresented) {
            editor
        }
    }

    private var editorPresented: Binding<Bool> {
        Binding(get: { model.isEditing }, set: { presented in
            if !presented {
                model.cancelEdit()
            }
        })
    }

    private var header: some View {
        HStack {
            Text(SchedulingWriteCopy.questionsTitle)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            Spacer(minLength: 0)
            Button(SchedulingWriteCopy.questionAddTitle) {
                model.beginAdd()
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(A11yID.SchedulingWrites.questionsAdd)
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.questions.isEmpty {
            Text(SchedulingWriteCopy.questionsEmpty)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        } else {
            ForEach(model.questions, id: \.id) { question in
                questionRow(question)
            }
        }
    }

    private func questionRow(_ question: SchedulingQuestion) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(question.label)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            HStack(spacing: DistrictSpacing.tight) {
                Text(question.type)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                Spacer(minLength: 0)
                Button(SchedulingWriteCopy.edit) {
                    model.beginEdit(question)
                }
                .buttonStyle(.districtGhost)
                Button(SchedulingWriteCopy.delete) {
                    model.beginDelete(question)
                }
                .buttonStyle(.districtGhost)
                // ⚠️ ONE DIALOG PER ROW, PRESENTED ONLY FOR THE QUESTION BEING DELETED.
                // See ``SwiftUI/Binding/dialog(_:onDismiss:)``.
                .confirmationDialog(
                    SchedulingWriteCopy.questionDeleteTitle,
                    isPresented: .dialog(model.confirmingDelete?.id == question.id, onDismiss: model.cancelDelete),
                    titleVisibility: .visible
                ) {
                    Button(SchedulingWriteCopy.questionDeleteConfirm, role: .destructive) {
                        Task { await model.delete() }
                    }
                    Button(SchedulingWriteCopy.cancel, role: .cancel) {
                        model.cancelDelete()
                    }
                } message: {
                    Text(SchedulingWriteCopy.questionDeleteBody)
                }
            }
        }
        .padding(.vertical, DistrictSpacing.hairline)
        .accessibilityIdentifier(A11yID.SchedulingWrites.question(question.id))
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteFailureStrip(message: model.loadState.failure?.message)
            SchedulingWriteFailureStrip(message: model.state.failure?.message)
            SchedulingWriteNotice(message: model.notice) {
                model.dismissNotice()
            }
        }
    }

    // MARK: - The one-question editor

    @ViewBuilder
    private var editor: some View {
        if let form = model.editing {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                    Text(model.editorTitle)
                        .font(DistrictType.title)
                        .foregroundStyle(colors.foreground)
                    editorFields(form)
                    SchedulingWriteFailureStrip(message: model.validation)
                    SchedulingWriteButtons(
                        saveTitle: form.id == nil
                            ? SchedulingWriteCopy.questionAddTitle
                            : SchedulingWriteCopy.questionSaveButton,
                        saving: model.state.isSaving,
                        saveIdentifier: A11yID.SchedulingWrites.questionsSubmit,
                        onCancel: { model.cancelEdit() },
                        onSave: { Task { await model.submit() } }
                    )
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func editorFields(_ form: SchedulingQuestionForm) -> some View {
        SchedulingWriteField(label: SchedulingWriteCopy.questionLabelLabel) {
            TextField(
                SchedulingWriteCopy.questionLabelPlaceholder,
                text: Binding(
                    get: { form.label },
                    set: { value in model.updateEditing { $0.label = value } }
                )
            )
            .districtField()
            .accessibilityIdentifier(A11yID.SchedulingWrites.questionsLabel)
        }
        SchedulingWriteField(label: SchedulingWriteCopy.questionTypeLabel) {
            Picker(
                SchedulingWriteCopy.questionTypeLabel,
                selection: Binding(
                    get: { form.type },
                    set: { value in model.updateEditing { $0.type = value } }
                )
            ) {
                ForEach(SchedulingWriteCopy.questionTypes, id: \.value) { type in
                    Text(type.label).tag(type.value)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(A11yID.SchedulingWrites.questionsType)
        }
        Toggle(
            SchedulingWriteCopy.questionRequiredToggle,
            isOn: Binding(
                get: { form.required },
                set: { value in model.updateEditing { $0.required = value } }
            )
        )
        .font(DistrictType.bodySmall)
        SchedulingWriteField(
            label: SchedulingWriteCopy.questionPositionLabel,
            hint: SchedulingWriteCopy.questionPositionHint
        ) {
            TextField(
                SchedulingWriteCopy.questionPositionLabel,
                text: Binding(
                    get: { form.position },
                    set: { value in model.updateEditing { $0.position = value } }
                )
            )
            .districtField()
            .keyboardType(.numberPad)
            .accessibilityIdentifier(A11yID.SchedulingWrites.questionsPosition)
        }
        options(form)
    }

    /// ⛔ DRAWN ONLY FOR A `select`. The catalog does not refuse options on a
    /// `text`, so a form that kept the control would let somebody build a list
    /// nothing will ever show.
    @ViewBuilder
    private func options(_ form: SchedulingQuestionForm) -> some View {
        if form.type == "select" {
            SchedulingWriteField(
                label: SchedulingWriteCopy.questionOptionsLabel,
                hint: SchedulingWriteCopy.questionOptionsHint
            ) {
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    ForEach(form.options, id: \.self) { option in
                        HStack {
                            Text(option)
                                .font(DistrictType.bodySmall)
                            Spacer(minLength: 0)
                            Button(SchedulingWriteCopy.remove) {
                                model.removeOption(option)
                            }
                            .buttonStyle(.districtGhost)
                        }
                    }
                    OptionEntryField { option in
                        model.addOption(option)
                    }
                }
            }
        }
    }
}

/// One text field that adds an option and clears itself.
///
/// ⚠️ ITS OWN VIEW BECAUSE IT NEEDS `@State`, and the sheet above holds none: its
/// whole draft lives on the model so a re-render cannot lose it. This field's
/// contents are not part of the question — they are gone the moment the option is
/// on the list.
private struct OptionEntryField: View {
    let onAdd: (String) -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            TextField(SchedulingWriteCopy.questionOptionPlaceholder, text: $draft)
                .districtField()
            Button(SchedulingWriteCopy.questionAddOption) {
                onAdd(draft)
                draft = ""
            }
            .buttonStyle(.districtGhost)
        }
    }
}
