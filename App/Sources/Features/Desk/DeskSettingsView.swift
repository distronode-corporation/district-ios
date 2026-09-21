import DistrictData
import DistrictModel
import PhotosUI
import SwiftUI

/// The desk's settings: two switches, the public name and the public logo.
///
/// ⛔ THE `enabled` SWITCH CHANGES WHAT HAPPENS ON A LIVE CALL, AND THE COPY SAYS SO
/// BEFORE IT IS FLIPPED. Turning it on re-routes the agent's unresolved-call teardown
/// into this workspace's queue and lets callers ask it for the status of their own
/// requests. Both are discovered in production if they are not said here.
///
/// ⛔ THE BRAND NAME AND THE LOGO ARE PUBLISHED TO PEOPLE WHO ARE NOT OUR CUSTOMERS.
/// The name is the heading on the tenant's public thread page and the signature on
/// every team reply there; the logo is served from a Distronode-controlled domain to
/// anyone holding a thread link. Both captions state that before a value is entered.
struct DeskSettingsView: View {
    @State private var model: DeskSettingsModel
    @State private var picked: PhotosPickerItem?

    private let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        _model = State(initialValue: DeskSettingsModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    Text(DeskCopy.settingsIntro)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(DeskCopy.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .task { await model.load() }
            // ⚠️ `.task(id:)` RATHER THAN `.onChange`, so re-picking the SAME image
            // still fires: a `PhotosPickerItem` that stays selected is equal to itself
            // and an `onChange` would not run, leaving a failed upload unretryable
            // without choosing a different file.
            .task(id: picked) {
                guard let item = picked else { return }
                await read(item)
                picked = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.loadFailure {
            // ⛔ A FAILED READ RENDERS NO CONTROLS AT ALL. A switch seeded from a read
            // that failed is a control that cannot be trusted to reflect the stored
            // value, and flipping it would write a guess over live configuration.
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                Text(DeskCopy.settingsUnavailable)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                FailureView(failure: failure, onRetry: { Task { await model.load() } })
            }
        } else if let settings = model.settings {
            if !model.canWrite {
                Text(DeskCopy.viewerNote)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
            enabledCard(settings)
            notifyCard(settings)
            brandCard
            logoCard(settings)
            SettingsSaveNotice(
                state: model.save,
                onReread: { Task { await model.load() } },
                onDismiss: model.dismissNotice
            )
        } else {
            SettingsSkeleton()
        }
    }

    private func enabledCard(_ settings: DeskSettings) -> some View {
        SettingsCard(eyebrow: DeskCopy.settingsEyebrow) {
            Toggle(
                DeskCopy.enabledLabel,
                // ⛔ A CLOSURE LITERAL, NEVER A BARE METHOD REFERENCE, on every
                // `Binding` setter in this file. See `.swiftlint.yml`'s custom rule.
                isOn: Binding(
                    get: { settings.enabled },
                    set: { value in Task { await model.setEnabled(value) } }
                )
            )
            .font(DistrictType.bodySmall)
            .disabled(!model.canWrite || model.busy)
            Text(DeskCopy.enabledHelp)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notifyCard(_ settings: DeskSettings) -> some View {
        SettingsCard(eyebrow: DeskCopy.notifyLabel) {
            Toggle(
                DeskCopy.notifyLabel,
                isOn: Binding(
                    get: { settings.notifyCustomersByEmail },
                    set: { value in Task { await model.setNotifyCustomers(value) } }
                )
            )
            .font(DistrictType.bodySmall)
            .disabled(!model.canEditDependents)
            Text(DeskCopy.notifyHelp)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⛔ SAVED ON COMMIT RATHER THAN PER KEYSTROKE. A patch per character would write
    /// the tenant's public-facing heading dozens of times per edit and race its own
    /// responses.
    private var brandCard: some View {
        SettingsCard(eyebrow: DeskCopy.brandNameLabel) {
            SettingsField(
                label: DeskCopy.brandNameLabel,
                text: Binding(
                    get: { model.brandDraft ?? "" },
                    set: { model.editBrandDraft($0) }
                ),
                enabled: model.canEditDependents
            )
            .onSubmit { Task { await model.commitBrandName() } }
            Text(DeskCopy.brandNameHelp)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⛔ NO PREVIEW OF THE PICKED FILE. Drawing the local image as "your customers see
    /// this" would be a claim about an upload that may never have landed, on a page
    /// other people open. The state below is the SERVER's.
    private func logoCard(_ settings: DeskSettings) -> some View {
        SettingsCard(eyebrow: DeskCopy.logoLabel) {
            Text(settings.publicLogoUrl == nil ? DeskCopy.logoNone : DeskCopy.logoSet)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            Text(DeskCopy.logoHelp)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            logoControls(settings)
        }
    }

    private func logoControls(_ settings: DeskSettings) -> some View {
        // ⛔ EVERY VALUE THE PICKER'S LABEL CLOSURE READS IS HOISTED OUT HERE FIRST.
        // `PhotosPicker`'s label closure is `@Sendable` and does NOT inherit this
        // view's main-actor isolation, so a main-actor read inside it (`colors` is a
        // COMPUTED property, which is one) is a Swift 6 concurrency diagnostic. Same
        // shape as `ComposerBar`; `Color` and `String` are both `Sendable`, so the
        // captured values are fine.
        let ink = colors.mutedForeground
        let label = pickerLabel(settings)
        return HStack(spacing: DistrictSpacing.tight) {
            PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .compatible) {
                // ⚠️ STYLED DIRECTLY RATHER THAN THROUGH `.buttonStyle`. A
                // `PhotosPicker` is not documented to forward a custom button style to
                // its label.
                Text(label)
                    .font(DistrictType.label)
                    .foregroundStyle(ink)
                    .padding(.horizontal, DistrictSpacing.row)
                    .frame(minHeight: 44)
            }
            .disabled(!model.canEditDependents)
            if settings.publicLogoUrl != nil {
                Button(DeskCopy.removeLogo) { Task { await model.removeLogo() } }
                    .buttonStyle(DistrictButtonStyle(variant: .destructive, size: .small))
                    .disabled(!model.canWrite || model.busy)
            }
        }
    }

    private func pickerLabel(_ settings: DeskSettings) -> String {
        if model.uploading {
            return DeskCopy.uploadingLogo
        }
        return settings.publicLogoUrl == nil ? DeskCopy.uploadLogo : DeskCopy.replaceLogo
    }

    /// Read the picked item's bytes and hand them to the model.
    ///
    /// ⚠️ A NIL OR THROWING LOAD IS "COULD NOT BE READ", WHICH IS NOT THE SAME AS A
    /// REFUSED TYPE OR SIZE. Those call for different next actions and collapsing them
    /// leaves an operator re-picking the same file.
    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.refuseUnreadableLogo()
            return
        }
        await model.uploadLogo(
            data,
            mimeType: Self.mimeType(of: item),
            fileName: Self.fileName(for: item)
        )
    }

    /// ⚠️ THE TYPE COMES FROM THE ITEM, NOT FROM A FILE EXTENSION. A picker item often
    /// has no name at all, and the server's allowlist is on the MIME type — so a guess
    /// from a name would refuse legitimate images and could label a non-image as one.
    ///
    /// ⚠️ AN ITEM DECLARING NOTHING THE ROUTE ACCEPTS FALLS BACK TO ITS FIRST DECLARED
    /// TYPE, so ``DeskLogoLimits`` refuses it BY NAME rather than this function
    /// inventing a type the bytes might not be.
    private static func mimeType(of item: PhotosPickerItem) -> String {
        let declared = item.supportedContentTypes.compactMap(\.preferredMIMEType)
        if let allowed = declared.first(where: { DeskLogoLimits.allowedMimeTypes.contains($0) }) {
            return allowed
        }
        return declared.first ?? "application/octet-stream"
    }

    /// ⚠️ A FILENAME IS REQUIRED FOR THE PART TO BE A FILE AT ALL — without one the
    /// multipart part is a plain field and the route's `file instanceof File` check
    /// fails. The server stores the mime type and the byte length and never reads this
    /// name, so a stable placeholder is honest and a guessed extension would not be.
    private static func fileName(for item: PhotosPickerItem) -> String {
        _ = item
        return "logo"
    }
}
