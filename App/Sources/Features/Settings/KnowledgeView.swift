import DistrictModel
import SwiftUI

/// What the agent answers from, and where the answer is composed. Ported from
/// Android's `KnowledgeScreen.kt`.
///
/// ⛔ A VIEWER REACHES THIS SCREEN AND GETS THE LIST AND THE STORED MODE, WITH NO ADD
/// FORM AND NO SELECTOR. Both reads admit `viewer` server-side and all the writes
/// exclude one, so the affordances are gated rather than the screen — and the model
/// re-checks the role at each write's call site anyway, because a control that was not
/// drawn is not a boundary.
///
/// ⛔ THE MODE SWITCH IS CONFIRMED, AND THE CONFIRMATION NAMES WHERE THE QUESTIONS GO.
/// `linked` hands this workspace's caller questions to Atlassian to compose an answer;
/// that is a data-residency change rather than a display preference, which is why the
/// route's write excludes a viewer while its read admits one.
///
/// ⚠️ THERE IS NO DELETE. ``KnowledgeRepository`` has no method for it (the route is
/// still untyped), so a document added here is removed on the website. Recorded so the
/// absence reads as a missing repository method rather than a missing button.
struct KnowledgeView: View {
    @State private var model: KnowledgeModel
    @State private var pendingMode: KnowledgeMode?
    @State private var confirmingMode = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: KnowledgeModel(
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
                if !model.canWrite {
                    viewerNote
                }
                modeCard
                if model.canWrite {
                    addCard
                }
                documents
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.knowledgeTitle)
        .task {
            await model.load()
        }
    }

    private var viewerNote: some View {
        Text(SettingsCopy.knowledgeViewerNote)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Where answers come from

    private var modeCard: some View {
        SettingsCard(eyebrow: SettingsCopy.knowledgeModeEyebrow) {
            modeBody
            // ⚠️ NO `onReread`. The mode write adopts the server's echo rather than
            // re-reading, so it can never be `savedButStale`.
            SettingsSaveNotice(state: model.modeSave, onDismiss: model.dismissNotices)
        }
    }

    /// ⛔ THREE STATES, AND THE UNREADABLE ONE IS NOT A DEFAULT. A failed mode read
    /// withholds the selector and says so rather than showing `internal`, which would
    /// claim the questions stay in region for a workspace that chose otherwise.
    @ViewBuilder
    private var modeBody: some View {
        if model.modeUnavailable {
            Text(SettingsCopy.knowledgeModeUnavailable)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        } else if let mode = model.mode {
            Text(Self.modeLabel(mode))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            if KnowledgeMode(rawValue: mode) == nil {
                // ⚠️ A MODE THIS BUILD HAS NOT LEARNED IS DISPLAYED AS ITSELF. Silently
                // rewriting it to one the operator did not choose is the failure this
                // branch exists to avoid; the read is deliberately a `String`.
                Text(SettingsCopy.knowledgeModeUnknown)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            if model.canChangeMode {
                modeButtons(current: mode)
            }
        } else {
            SkeletonBlock(height: 20)
        }
    }

    /// ⚠️ BUTTONS RATHER THAN A `Picker`. A picker's selection binding fires on the
    /// gesture, which would mean the residency confirmation appearing AFTER the value
    /// had already changed on screen; a button can ask first.
    private func modeButtons(current: String) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            ForEach(KnowledgeMode.allCases, id: \.rawValue) { option in
                Button(Self.modeLabel(option.rawValue)) { request(option) }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.modeSave.isSaving || option.rawValue == current)
                    // ⚠️ ON EACH MODE'S BUTTON, PRESENTED ONLY FOR THE ONE PRESSED. See
                    // ``SwiftUI/Binding/dialog(_:onDismiss:)``.
                    .confirmationDialog(
                        SettingsCopy.knowledgeModeConfirm,
                        isPresented: .dialog(confirmingMode && pendingMode == option) { confirmingMode = false },
                        titleVisibility: .visible
                    ) {
                        Button(SettingsCopy.knowledgeModeConfirmAction, role: .destructive, action: confirmMode)
                        Button("Cancel", role: .cancel) { pendingMode = nil }
                    }
            }
        }
    }

    // MARK: - Adding one

    private var addCard: some View {
        SettingsCard(eyebrow: SettingsCopy.knowledgeAddEyebrow) {
            SettingsField(
                label: SettingsCopy.knowledgeTitleLabel,
                text: titleBinding,
                enabled: !model.addSave.isSaving
            )
            SettingsField(
                label: SettingsCopy.knowledgeContentLabel,
                text: contentBinding,
                enabled: !model.addSave.isSaving,
                multiline: true
            )
            Text(SettingsCopy.knowledgeAddNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if model.addRejected {
                Text(SettingsCopy.knowledgeAddRejected)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
            }
            SettingsSaveNotice(state: model.addSave, onReread: reload, onDismiss: model.dismissNotices)
            Button(model.addSave.isSaving ? "Adding…" : SettingsCopy.knowledgeAdd, action: submitDocument)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canAdd)
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var documents: some View {
        switch model.list {
        case .loading:
            SettingsSkeleton()
        case let .ready(rows):
            documentList(rows)
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    @ViewBuilder
    private func documentList(_ rows: [KnowledgeDocument]) -> some View {
        if rows.isEmpty {
            EmptyStateView(
                systemImage: "doc.text",
                title: SettingsCopy.knowledgeEmptyTitle,
                message: SettingsCopy.knowledgeEmptyBody
            )
        } else {
            SettingsCard(eyebrow: SettingsCopy.knowledgeDocumentsEyebrow) {
                ForEach(rows, id: \.id) { document in
                    documentRow(document)
                }
            }
        }
    }

    /// ⚠️ THE CHUNK COUNT IS SHOWN BECAUSE IT IS WHAT THE UPLOAD COST. "This document
    /// became 400 chunks" is the only visible signal that a paste was larger than
    /// intended, and nothing else on this screen carries it.
    private func documentRow(_ document: KnowledgeDocument) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(document.title)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            Text("\(document.sourceType) · \(document.status) · \(document.chunkCount) chunks")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Wiring

    private var titleBinding: Binding<String> {
        Binding(get: { model.draftTitle }, set: { model.editTitle($0) })
    }

    private var contentBinding: Binding<String> {
        Binding(get: { model.draftContent }, set: { model.editContent($0) })
    }

    /// ⛔ ONLY THE RESIDENCY CHANGE IS CONFIRMED. Switching BACK to this workspace's
    /// own documents sends nothing anywhere new, so a prompt there would be friction
    /// that teaches people to dismiss the one that matters.
    private func request(_ option: KnowledgeMode) {
        pendingMode = option
        guard model.isResidencyChange(to: option) else {
            confirmMode()
            return
        }
        confirmingMode = true
    }

    private func confirmMode() {
        guard let option = pendingMode else { return }
        pendingMode = nil
        Task { await model.setMode(option) }
    }

    private func submitDocument() {
        Task { await model.addDocument() }
    }

    private func reload() {
        Task { await model.load() }
    }

    private static func modeLabel(_ raw: String) -> String {
        switch KnowledgeMode(rawValue: raw) {
        case .internal: SettingsCopy.knowledgeModeInternal
        case .linked: SettingsCopy.knowledgeModeLinked
        case nil: raw
        }
    }
}
