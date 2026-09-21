import DistrictModel
import SwiftUI

/// How this workspace answers a call, and how long the app rings before the agent takes
/// it.
///
/// ⛔ THE THREE MODES ARE WORDED AS WHAT HAPPENS ON THE NEXT CALL, NEVER AS THE WIRE
/// VALUES. `ai_first`, `ai_then_app` and `app_first` are what the route validates; an
/// operator choosing between them is deciding whether their own telephone rings, and
/// ``SettingsCopy/callsModeAiThenApp`` and its two siblings are the only place that is
/// said. Anything that put an enum name on screen here would be a control nobody can
/// use.
///
/// ⛔ A VIEWER REACHES THIS SCREEN READ-ONLY, WHICH IS THE OPPOSITE CALL FROM PERSONA AND
/// CAPABILITIES. `GET workspace/call-handling` admits all three roles — nothing in that
/// payload is a staff phone number, it is a mode and a number of seconds — while the PATCH
/// excludes a viewer. So the row is drawn, the controls are not, and the model re-checks
/// the role at each write's call site anyway, because a control that was not drawn is not
/// a boundary.
///
/// ⛔ THE RING STEPPER SAYS WHEN IT DOES NOTHING. On "the agent answers everything"
/// nothing rings, so the value is stored and never used; without
/// ``SettingsCopy/callsRingNote`` an operator who set it and heard no ring would conclude
/// the setting is broken.
///
/// ⚠️ NO `savedButStale` BANNER IS POSSIBLE HERE and the absence is deliberate rather
/// than an omission: the PATCH echoes what it wrote, so ``CallHandlingModel`` adopts its
/// own response and never re-reads. That is why ``SettingsSaveNotice`` is given no
/// `onReread`.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once; SwiftUI resolves that by
/// TYPE, so a second registration here would be a runtime coin toss rather than a compile
/// error.
struct CallHandlingView: View {
    @State private var model: CallHandlingModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: CallHandlingModel(
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
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.callsTitle)
        .task {
            await model.load()
        }
    }

    private var viewerNote: some View {
        Text(SettingsCopy.callsViewerNote)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case .ready:
            if let draft = model.draft {
                modeCard(draft)
                ringCard(draft)
                saveRow
            }
        case let .failed(failure):
            failureView(failure)
        }
    }

    private func failureView(_ failure: FailureText) -> some View {
        VStack(spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: SettingsCopy.callsLoadFailedEyebrow)
            FailureView(failure: failure, onRetry: reload)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Who answers

    private func modeCard(_ draft: CallHandlingSetting) -> some View {
        SettingsCard(eyebrow: SettingsCopy.callsModeEyebrow) {
            // ⚠️ A MODE THIS BUILD HAS NOT LEARNED IS SHOWN AS ITSELF AND STAYS
            // SELECTED. Silently rewriting it to one of the three would claim a choice
            // the operator never made, and the save leaves it alone unless they pick
            // another — which is why the read is a `String` and not an enum.
            if !CallHandling.isKnown(draft.mode) {
                Text(draft.mode)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                Text(SettingsCopy.callsModeUnknown)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            ForEach(CallHandling.modes, id: \.self) { mode in
                modeRow(mode, selected: mode == draft.mode)
            }
        }
    }

    /// ⛔ A ROW PER MODE RATHER THAN A `Picker`, AND THE REASON IS THE LABELS. Each
    /// sentence is a clause about what happens on the next call, so the three do not fit
    /// a segmented control and would be truncated to uselessness in a menu — which on
    /// this screen means an operator choosing whether their phone rings from three
    /// fragments of text.
    ///
    /// ⚠️ THE WHOLE ROW IS THE TAP TARGET. ``DistrictListRow`` owns its own
    /// `contentShape`, so wrapping it in a `Button` gives the full width, the press
    /// highlight and the accessibility button trait.
    /// ⛔ THE TICK IS A TRAIT, NOT A GLYPH NAME. Which mode is chosen is the whole
    /// point of this screen, and a checkmark announced as "checkmark" after the mode's
    /// sentence says the shape rather than the state — worse, an UNSELECTED row then
    /// announces nothing at all to distinguish it. `.isSelected` is what VoiceOver
    /// reads as "selected" and what Voice Control and Switch Control both act on.
    private func modeRow(_ mode: String, selected: Bool) -> some View {
        Button {
            model.select(mode: mode)
        } label: {
            DistrictListRow(title: Self.modeLabel(mode), trailing: { tick(selected) })
        }
        .buttonStyle(.plain)
        .disabled(!model.canWrite || model.save.isSaving)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func tick(_ selected: Bool) -> some View {
        if selected {
            Image(systemName: "checkmark")
                .font(DistrictType.label)
                .foregroundStyle(colors.district)
                .accessibilityHidden(true)
        }
    }

    // MARK: - How long it rings

    private func ringCard(_ draft: CallHandlingSetting) -> some View {
        SettingsCard(eyebrow: SettingsCopy.callsRingEyebrow) {
            // ⚠️ A `Stepper` RATHER THAN A SLIDER over a five-second-wide useful range.
            // 5...30 is 26 positions; a slider on a phone cannot be landed on a specific
            // one, and the value here decides how long a caller waits.
            Stepper(
                value: ringBinding,
                in: CallHandling.minimumRingSeconds ... CallHandling.maximumRingSeconds
            ) {
                SettingsReadOnlyRow(
                    label: SettingsCopy.callsRingLabel,
                    value: SettingsCopy.callsRingValue(draft.ringSeconds)
                )
            }
            .disabled(!model.canWrite || model.save.isSaving)
            Text(SettingsCopy.callsRingNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    // MARK: - Saving

    @ViewBuilder
    private var saveRow: some View {
        if model.canWrite {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                // ⚠️ NO `onReread`: this write adopts the server's echo, so it can never
                // be `savedButStale`. See the ⚠️ on this view.
                SettingsSaveNotice(state: model.save, onDismiss: model.dismissNotices)
                Button(model.save.isSaving ? "Saving…" : SettingsCopy.callsSave, action: submit)
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canSave)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Wiring

    private var ringBinding: Binding<Int> {
        Binding(
            get: { model.draft?.ringSeconds ?? CallHandling.defaultRingSeconds },
            set: { model.setRing($0) }
        )
    }

    private func submit() {
        Task { await model.saveChanges() }
    }

    private func reload() {
        Task { await model.load() }
    }

    /// ⚠️ AN UNKNOWN MODE FALLS BACK TO ITS OWN WIRE VALUE rather than to one of the
    /// three. It is unreachable from ``CallHandling/modes``, which is the only thing this
    /// is called with; it exists so that adding a mode to that list without adding its
    /// sentence here shows the raw value instead of the wrong one.
    private static func modeLabel(_ mode: String) -> String {
        switch mode {
        case CallHandling.aiFirst: SettingsCopy.callsModeAiFirst
        case CallHandling.aiThenApp: SettingsCopy.callsModeAiThenApp
        case CallHandling.appFirst: SettingsCopy.callsModeAppFirst
        default: mode
        }
    }
}
