import DistrictData
import DistrictModel
import SwiftUI

/// The native Voice Studio: recipes on top, the signal chain Ear → Turn-taking → Brain → Voice
/// (a realtime engine is one block spanning them all), the time-to-first-word meter, where the
/// call is processed, and an editor per leg with its tuning behind Advanced. Ported from the web
/// Studio, with Android's `VoiceStudioScreen` as the sibling.
///
/// ⛔ EVERY LABEL FROM THE SERVER IS RENDERED VERBATIM, in the reader's PORTAL language. Only
/// this app's chrome (``VoiceStudioCopy``) is in Swift.
///
/// ⛔ A FAILED READ OFFERS A RETRY AND NOTHING ELSE. Without the catalogue there is nothing an
/// edit could be checked against.
struct VoiceStudioView: View {
    @State private var model: VoiceStudioModel

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: VoiceStudioModel(container: container, workspaceId: workspaceId, role: role))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(model.session?.studio.labels.heading ?? VoiceStudioCopy.title)
        // ⛔ `.contain` FIRST, or every control below inherits this identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.VoiceStudio.root)
        .task { await model.loadStudio() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        case let .ready(session):
            VoiceStudioSaveCard(model: model, session: session)
            VoiceStudioRecipesCard(model: model, session: session)
            VoiceStudioChainCard(model: model, session: session)
            VoiceStudioMeterCard(session: session)
            VoiceStudioResidencyCard(session: session)
            VoiceStudioLegEditor(model: model, session: session)
        }
    }

    private func reload() {
        Task { await model.loadStudio() }
    }
}

/// The description, saved or unsaved, what the last save did, and the save button.
struct VoiceStudioSaveCard: View {
    let model: VoiceStudioModel
    let session: VoiceStudioSession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var labels: VoiceStudioLabels {
        session.studio.labels
    }

    var body: some View {
        SettingsCard(eyebrow: labels.heading) {
            Text(labels.description)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.isDirty ? labels.unsaved : labels.allSaved)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .accessibilityIdentifier(A11yID.VoiceStudio.dirty)
            notice
            if model.canWrite {
                Button(model.save.isSaving ? VoiceStudioCopy.saving : labels.save) {
                    Task { await model.saveChanges() }
                }
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSave)
                .accessibilityIdentifier(A11yID.VoiceStudio.save)
            }
        }
    }

    /// ⛔ A SAVE THAT DID NOT HOLD SAYS SO IN THE SERVER'S WORDS, OVER THE RE-READ STATE.
    @ViewBuilder
    private var notice: some View {
        switch model.save {
        case .idle, .saving:
            EmptyView()
        case .saved:
            line(labels.saved, colors.foreground)
        case .mismatch:
            line(labels.saveFailed, colors.destructive)
        case let .savedButStale(failure):
            line("\(SettingsCopy.savedButStale) \(failure.message)", colors.mutedForeground)
        case let .failed(failure):
            line("\(labels.saveFailed) \(failure.message)", colors.destructive)
        }
    }

    private func line(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.VoiceStudio.notice)
    }
}

/// The tier switch, the recipe tiles, and how far the held engine is from its recipe.
struct VoiceStudioRecipesCard: View {
    let model: VoiceStudioModel
    let session: VoiceStudioSession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var labels: VoiceStudioLabels {
        session.studio.labels
    }

    var body: some View {
        SettingsCard(eyebrow: labels.recipesLabel) {
            tiers
            ForEach(session.tiles, id: \.id) { recipe in
                tile(recipe)
            }
            basedOn
        }
    }

    /// Stable or Latest, with the server's sentence for what the difference is.
    private var tiers: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Picker(labels.tierLabel, selection: Binding(
                get: { session.tier },
                set: { tier in model.selectTier(tier) }
            )) {
                Text(labels.tierStable).tag(VoiceStudioRecipes.stable)
                Text(labels.tierLatest).tag(VoiceStudioRecipes.latest)
            }
            .pickerStyle(.segmented)
            .disabled(!model.canEdit)
            .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.tierKind, session.tier))
            Text(labels.tierDescription)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One tile: its name, its badges, and what it would mean, all in the server's words.
    ///
    /// ⛔ THE CHANNEL IS SAID IN TEXT AS WELL AS IN A BADGE, and so is where the call goes: a
    /// residency claim has to survive a screen reader.
    private func tile(_ recipe: VoiceStudioRecipe) -> some View {
        let selected = recipe.id == session.baseRecipe
        return Button {
            model.applyRecipe(recipe.id)
        } label: {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                HStack(spacing: DistrictSpacing.tight) {
                    Text(recipe.name)
                        .font(DistrictType.titleSmall)
                        .foregroundStyle(colors.foreground)
                    if recipe.isDefault {
                        DistrictBadge(text: labels.defaultBadge, tone: .district)
                    }
                    DistrictBadge(text: recipe.channelLabel, tone: VoiceStudioChannel.tone(recipe.channel))
                }
                caption(recipe.description)
                caption(recipe.residency.text)
                caption(recipe.timeToFirstWord.text)
                if let note = recipe.note {
                    caption(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DistrictSpacing.tight)
            .districtCardSurface(bordered: selected)
        }
        .buttonStyle(.plain)
        .disabled(!model.canEdit)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(
            A11yID.VoiceStudio.handle(A11yID.VoiceStudio.recipeKind, recipe.id, selected: selected)
        )
    }

    /// "Based on Fastest, 2 changes", and Reset, once the held engine has moved off its recipe.
    @ViewBuilder
    private var basedOn: some View {
        if session.changes > 0, !session.baseName.isEmpty {
            HStack(spacing: DistrictSpacing.tight) {
                Text(VoiceStudioCopy.basedOn(session.baseName, changes: session.changes))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .accessibilityIdentifier(A11yID.VoiceStudio.basedOn)
                Spacer(minLength: DistrictSpacing.tight)
                Button(labels.reset) { model.reset() }
                    .buttonStyle(.districtSecondary)
                    .disabled(!model.canEdit)
                    .accessibilityIdentifier(A11yID.VoiceStudio.reset)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The badge tone for a channel.
///
/// ⚠️ TONE IS DECORATION HERE: the channel's NAME is always in the badge's text.
enum VoiceStudioChannel {
    static func tone(_ channel: String) -> Tone {
        switch channel {
        case "stable": .success
        case "latest": .info
        case "preview": .warning
        default: .neutral
        }
    }
}
