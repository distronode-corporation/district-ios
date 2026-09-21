import DistrictModel
import SwiftUI

/// Which identity a message leaves this workspace from. Ported from Android's
/// `MessagingScreen.kt`.
///
/// ⛔ A VIEWER REACHES THIS SCREEN AND IS OFFERED NO CONTROL ON IT. The read admits a
/// viewer by design — it is the workspace's own outbound identity, not a credential —
/// and every write excludes one, so the affordances are gated rather than the screen.
/// ``MessagingModel`` re-checks the role at each write's call site regardless.
///
/// ⛔ THE PLATFORM'S OWN ACCOUNT IS DRAWN IN ITS OWN PANEL AND NEVER AS A ROW IN THE
/// LIST. That list is both the sender picker and the id space a `from` is validated
/// against, so a synthetic managed entry would be a pickable sender whose every send is
/// rejected, and `setDefault` would answer 404 for its invented id.
///
/// ⚠️ NO DEFAULT SENDER IS A STATE, NOT AN ERROR. A fresh workspace omits
/// `defaultAccountId` entirely (the key is dropped rather than nulled) and nulls
/// `managedAccount`; the screen says what that means rather than showing a blank where
/// a badge would be.
struct MessagingView: View {
    @State private var model: MessagingModel
    @State private var pendingDelete: MessagingAccount?
    @State private var confirmingDelete = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: MessagingModel(
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
                if !model.canEdit {
                    note(SettingsCopy.messagingViewerNote)
                }
                notices
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.messagingTitle)
        .task {
            await model.loadAccounts()
        }
        .sheet(isPresented: sheetPresented) {
            MessagingAccountSheet(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case let .ready(response):
            accounts(response)
            managed(response)
            channels(response)
            creatorCell
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    // MARK: - What the last write did

    /// ⛔ OUTSIDE THE LOAD SWITCH, WHICH IS THE WHOLE POINT OF THIS BLOCK EXISTING.
    /// ``MessagingModel/read()`` sets `load` to `.failed` whatever it was called for, so
    /// inside a card that only exists in `case .ready`, a BYOK account that was created
    /// successfully and then could not be read back would show "Could not load this
    /// workspace's configuration" and nothing else: no "Saved.", and the account nowhere
    /// in sight. On this surface the operator's next move after that is to make the
    /// account again, and "again" here means a second carrier account holding a second
    /// copy of the credentials. ``KnowledgeView`` and ``CapabilitiesView`` are built the
    /// same way.
    ///
    /// ⚠️ THE COST IS LOCALITY: a channel-override notice does not sit inside the
    /// channel card. That is the smaller loss. A banner a few rows from its control is
    /// still findable; a banner that is not drawn at all is not.
    private var notices: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            SettingsSaveNotice(state: model.accountSave, onReread: reload, onDismiss: model.dismissNotices)
            SettingsSaveNotice(state: model.defaultSave, onReread: reload, onDismiss: model.dismissNotices)
            SettingsSaveNotice(state: model.deleteSave, onReread: reload, onDismiss: model.dismissNotices)
            SettingsSaveNotice(state: model.channelSave, onReread: reload, onDismiss: model.dismissNotices)
            // ⚠️ NO `onReread`. The creator cell write does not re-read (the stored value
            // is not on the messaging GET), so it can never be `savedButStale` and a
            // reload would say nothing about it.
            SettingsSaveNotice(state: model.metaSave, onDismiss: model.dismissNotices)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The account list

    @ViewBuilder
    private func accounts(_ response: MessagingResponse) -> some View {
        if response.accounts.isEmpty {
            EmptyStateView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: SettingsCopy.messagingEmptyTitle,
                message: SettingsCopy.messagingEmptyBody
            )
            addButton
        } else {
            SettingsCard(eyebrow: SettingsCopy.messagingAccountsEyebrow) {
                if response.defaultAccountId == nil {
                    Text(SettingsCopy.messagingNoDefault)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.warning)
                }
                ForEach(response.accounts, id: \.id) { account in
                    accountRow(account, isDefault: account.id == response.defaultAccountId)
                }
                addButton
            }
        }
    }

    private var addButton: some View {
        Button("Add carrier account") { model.startEditing(accountId: nil) }
            .buttonStyle(.districtSecondary)
            .disabled(!model.canEditNow)
    }

    private func accountRow(_ account: MessagingAccount, isDefault: Bool) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            if isDefault {
                DistrictEyebrow(text: SettingsCopy.messagingDefaultBadge)
            }
            Text(account.label ?? MessagingCatalog.providerLabel(account.provider ?? "Account"))
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            Text(subtitle(account))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if model.canEdit {
                accountControls(account, isDefault: isDefault)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountControls(_ account: MessagingAccount, isDefault: Bool) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button("Edit") { model.startEditing(accountId: account.id) }
                .buttonStyle(.districtGhost)
                .disabled(!model.canEditNow)
            Button(SettingsCopy.messagingSetDefault) { setDefault(account) }
                .buttonStyle(.districtGhost)
                .disabled(!model.canEditNow || isDefault)
            Button(SettingsCopy.messagingDelete) { requestDelete(account) }
                .buttonStyle(.districtDestructive)
                .disabled(!model.canEditNow)
                // ⚠️ ON EACH ACCOUNT'S BUTTON, PRESENTED ONLY FOR THE ONE BEING DELETED. See
                // ``SwiftUI/Binding/dialog(_:onDismiss:)``.
                .confirmationDialog(
                    SettingsCopy.messagingDeleteConfirm,
                    isPresented: .dialog(confirmingDelete && pendingDelete?.id == account.id) {
                        confirmingDelete = false
                    },
                    titleVisibility: .visible
                ) {
                    Button(SettingsCopy.messagingDelete, role: .destructive, action: confirmDelete)
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                }
        }
        .padding(.top, DistrictSpacing.hairline)
    }

    /// ⚠️ `credentialSource` IS THE FIELD AN OPERATOR ACTUALLY NEEDS: a `byok` account
    /// bills on their own carrier account and a `managed` one bills through us.
    private func subtitle(_ account: MessagingAccount) -> String {
        let carrier = MessagingCatalog.providerLabel(account.provider ?? "unknown")
        let source = account.credentialSource == "managed" ? "billed through Distronode" : "own carrier account"
        let numbers = account.phoneNumbers.isEmpty ? "no numbers yet" : account.phoneNumbers.joined(separator: ", ")
        return "\(carrier) · \(source) · \(numbers)"
    }

    // MARK: - The platform's own numbers

    @ViewBuilder
    private func managed(_ response: MessagingResponse) -> some View {
        if let account = response.managedAccount, !account.phoneNumbers.isEmpty {
            SettingsCard(eyebrow: SettingsCopy.messagingManagedEyebrow) {
                Text(account.phoneNumbers.joined(separator: "\n"))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                Text(SettingsCopy.messagingManagedNote)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }

    // MARK: - Per-channel senders

    /// ⚠️ THE MAP IS OPEN, NOT AN ENUM OF CHANNELS. The server stores whatever key was
    /// set, so a channel added on the web has to render here rather than be dropped.
    /// ⚠️ AND THERE IS NO CLEAR: the route merges one key and echoes the map, so an
    /// override can be re-pointed and never removed from this client, which the note
    /// says rather than implying a control that does not exist.
    private func channels(_ response: MessagingResponse) -> some View {
        SettingsCard(eyebrow: SettingsCopy.messagingChannelsEyebrow) {
            if response.channelDefaults.isEmpty {
                Text(SettingsCopy.messagingNoChannelOverrides)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            } else {
                ForEach(response.channelDefaults.keys.sorted(), id: \.self) { channel in
                    SettingsReadOnlyRow(
                        label: channel,
                        value: label(forAccountId: response.channelDefaults[channel], in: response)
                    )
                }
            }
        }
    }

    /// ⚠️ AN ID THE LIST DOES NOT HOLD IS SHOWN AS THE ID. It means the override points
    /// at an account that has since been removed, which is worth seeing rather than
    /// rendering as an absence.
    private func label(forAccountId id: String?, in response: MessagingResponse) -> String? {
        guard let id else { return nil }
        return response.accounts.first { $0.id == id }?.label ?? id
    }

    // MARK: - Creator cell

    private var creatorCell: some View {
        SettingsCard(eyebrow: SettingsCopy.messagingCreatorCellEyebrow) {
            Text(SettingsCopy.messagingCreatorCellNote)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            if model.canEdit {
                SettingsField(
                    label: SettingsCopy.messagingCreatorCellLabel,
                    text: creatorCellBinding,
                    enabled: !model.metaSave.isSaving
                )
                Button(SettingsCopy.messagingCreatorCellSave, action: submitCreatorCell)
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canSaveCreatorCell)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Wiring

    /// ⛔ DERIVED FROM THE DRAFT'S PRESENCE RATHER THAN HELD AS A SECOND `@State` FLAG,
    /// so the sheet cannot outlive the draft it is editing and there is no boolean to
    /// fall out of step with the model. A swipe-down writes nil back through the setter,
    /// which is the same path Cancel takes.
    ///
    /// ⚠️ `sheet(isPresented:)` RATHER THAN `sheet(item:)`, DELIBERATELY. `item:`
    /// re-presents on an id CHANGE, and a create has one constant id for its whole life,
    /// so the content would be built once from the draft as it was at presentation and
    /// every keystroke after that would be written into the model and read back from a
    /// snapshot that never moved. The sheet reads ``MessagingModel/draft`` itself
    /// instead.
    private var sheetPresented: Binding<Bool> {
        Binding(
            get: { model.draft != nil },
            set: { presented in
                guard !presented else { return }
                model.editDraft(nil)
            }
        )
    }

    private var creatorCellBinding: Binding<String> {
        Binding(get: { model.creatorCellDraft }, set: { model.editCreatorCell($0) })
    }

    private func setDefault(_ account: MessagingAccount) {
        Task { await model.setDefault(accountId: account.id) }
    }

    private func requestDelete(_ account: MessagingAccount) {
        pendingDelete = account
        confirmingDelete = true
    }

    private func confirmDelete() {
        guard let account = pendingDelete else { return }
        pendingDelete = nil
        Task { await model.deleteAccount(accountId: account.id) }
    }

    private func submitCreatorCell() {
        Task { await model.saveCreatorCell() }
    }

    private func reload() {
        Task { await model.loadAccounts() }
    }
}
