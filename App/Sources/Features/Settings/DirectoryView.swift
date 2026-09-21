import DistrictModel
import SwiftUI

/// Who the agent can put a live caller through to. Ported from Android's
/// `DirectoryEditorScreen.kt`, editor included.
///
/// ⛔ THE SAVE REPLACES THE WHOLE LIST. `PATCH workspace/directory` writes
/// `callDirectory: (callDirectory || [])`, so the array this
/// form produces becomes the COMPLETE list of humans the voice agent will transfer a live
/// caller to, and an empty one removes every target while answering `{success:true}`. There
/// is no undo and no export. Three things make that safe enough to offer:
///
///   1. the form can only exist on a successful `workspace/config` read
///      (``SettingsConfigState`` has no case for "we could not load, here is an empty form
///      anyway"), so it never opens on a blank baseline;
///   2. every row carries its STORED object and overwrites only the three keys this screen
///      owns, so a key nothing here models survives the round trip — see
///      ``DirectoryDraft``;
///   3. a save that would send an empty array is CONFIRMED, naming what happens on the
///      next call rather than asking whether the operator is sure.
///
/// ⛔ `type` IS THE FIELD THIS SCREEN EXISTS FOR AS MUCH AS THE REST. `"app"` makes a
/// transfer RING THE PHONE instead of dialling a PSTN number, and it has never been
/// settable from any UI on any platform. ⚠️ An ABSENT `type` is shown as "Phone number" and
/// stays absent unless somebody picks one — writing the default in would rewrite every
/// tenant's stored config to say what it already meant.
///
/// ⚠️ HALF-FILLED ROWS ARE SHOWN, FLAGGED, AND SAVED. The server's schema has both fields
/// `.nullish()`, so a row with a name and no number is legal and already exists — it is a
/// transfer target the agent cannot use, which is exactly what an operator is here to find
/// out. Dropping it on their behalf would be a deletion nobody asked for. An ENTIRELY blank
/// row is dropped, because that is the Add button pressed and abandoned.
///
/// ⚠️ A VIEWER NEVER REACHES THIS SCREEN: `workspace/config` excludes them server-side
/// (the payload carries staff transfer numbers), which is why ``RouteGate`` hides the row
/// outright rather than offering it read-only. The model still gates every write, because a
/// control that was not drawn is not a boundary.
struct DirectoryView: View {
    @State private var model: DirectoryModel
    @State private var confirmingEmpty = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: DirectoryModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.directoryTitle)
        .task {
            await model.loadConfig()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case .ready:
            if model.notEditable {
                SettingsNotEditableNotice()
            } else if let drafts = model.drafts {
                editor(drafts)
            }
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    @ViewBuilder
    private func editor(_ drafts: [DirectoryDraft]) -> some View {
        if drafts.isEmpty {
            EmptyStateView(
                systemImage: "person.2.slash",
                title: SettingsCopy.directoryEmptyTitle,
                message: SettingsCopy.directoryEmptyBody
            )
        } else {
            SettingsCard(eyebrow: SettingsCopy.directoryTitle) {
                ForEach(drafts) { draft in
                    row(draft)
                    if draft.id != drafts.last?.id {
                        DistrictRowDivider()
                    }
                }
            }
        }
        controls
    }

    /// One target: name, number, and how it is reached.
    ///
    /// ⚠️ THE THREE CONTROLS ARE STACKED RATHER THAN IN A ROW. A phone number needs the
    /// full width to be readable, and a name beside it on a handset gives both about
    /// fifteen characters.
    private func row(_ draft: DirectoryDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            SettingsField(
                label: SettingsCopy.directoryNameLabel,
                text: nameBinding(draft),
                enabled: model.canWrite && !model.save.isSaving
            )
            SettingsField(
                label: SettingsCopy.directoryNumberLabel,
                text: numberBinding(draft),
                enabled: model.canWrite && !model.save.isSaving
            )
            typePicker(draft)
            if draft.isIncomplete {
                // ⚠️ FLAGGED, NOT REFUSED. A target with no number is one the agent cannot
                // use, which is worth saying; deleting it on the operator's behalf is not
                // this screen's decision.
                Text(SettingsCopy.directoryIncomplete)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.warning)
            }
            if model.canWrite {
                Button(SettingsCopy.directoryRemove) { model.removeRow(draft.id) }
                    .buttonStyle(.districtGhost)
                    .disabled(model.save.isSaving)
            }
        }
        .padding(.vertical, DistrictSpacing.hairline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ TWO OPTIONS AND ONLY ONE OF THEM WRITES A KEY. "Phone number" clears `type`
    /// rather than setting it to `"pstn"`, so a legacy row that never had the key keeps not
    /// having it and a row switched back from "app" ends in the same stored state as every
    /// other row. See the ⛔ on ``DirectoryDraft/type``.
    private func typePicker(_ draft: DirectoryDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SettingsCopy.directoryTypeLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            HStack(spacing: DistrictSpacing.tight) {
                typeButton(draft, title: SettingsCopy.directoryTypePstn, value: nil)
                typeButton(draft, title: SettingsCopy.directoryTypeApp, value: Self.appType)
            }
            Text(SettingsCopy.directoryTypeNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⚠️ THE STYLE IS CONSTRUCTED RATHER THAN PICKED WITH A TERNARY OF TWO IMPLICIT-MEMBER
    /// EXPRESSIONS. `.buttonStyle` is generic over its argument, so
    /// `cond ? .districtPrimary : .districtSecondary` asks the type checker to infer a
    /// style from two leading dots.
    private func typeButton(_ draft: DirectoryDraft, title: String, value: String?) -> some View {
        let selected = draft.type == value
        return Button(title) { model.editType(draft.id, value) }
            .buttonStyle(DistrictButtonStyle(variant: selected ? .primary : .secondary))
            .disabled(!model.canWrite || model.save.isSaving)
    }

    @ViewBuilder
    private var controls: some View {
        if model.canWrite {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                Text(SettingsCopy.directoryNote)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                Button(SettingsCopy.directoryAdd) { model.addRow() }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.save.isSaving)
                SettingsSaveNotice(state: model.save, onReread: reload, onDismiss: model.dismissNotices)
                Button(model.save.isSaving ? "Saving…" : SettingsCopy.directorySave, action: submit)
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canSave)
                    // ⛔ THE ONE CONFIRMATION ON THIS SCREEN, ON THE SAVE THAT ASKS FOR IT,
                    // AND IT FIRES ON WHAT WOULD BE SENT rather than on whether the list
                    // looks empty. A screen full of abandoned blank rows saves as an empty
                    // array too, and that is the case an operator would least expect to
                    // remove every transfer target.
                    .confirmationDialog(
                        SettingsCopy.directoryEmptyConfirm,
                        isPresented: $confirmingEmpty,
                        titleVisibility: .visible
                    ) {
                        Button(SettingsCopy.directoryEmptyConfirmAction, role: .destructive, action: commit)
                        Button("Cancel", role: .cancel) {}
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Wiring

    private func nameBinding(_ draft: DirectoryDraft) -> Binding<String> {
        Binding(get: { draft.name }, set: { model.editName(draft.id, $0) })
    }

    private func numberBinding(_ draft: DirectoryDraft) -> Binding<String> {
        Binding(get: { draft.phoneNumber }, set: { model.editNumber(draft.id, $0) })
    }

    /// ⛔ THE EMPTY CASE ASKS FIRST. Everything else commits straight away: replacing one
    /// number with another is an ordinary edit and a prompt on every save would teach the
    /// operator to tap through the one that matters.
    private func submit() {
        guard model.wouldSaveEmpty else {
            commit()
            return
        }
        confirmingEmpty = true
    }

    private func commit() {
        Task { await model.saveDirectory() }
    }

    private func reload() {
        Task { await model.loadConfig() }
    }

    /// The one wire value this screen writes. ⚠️ `"pstn"` is deliberately absent: it is
    /// expressed as the ABSENCE of the key. See ``typePicker(_:)``.
    private static let appType = "app"
}
