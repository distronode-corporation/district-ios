import DistrictData
import DistrictModel
import SwiftUI

/// The setup wizard, as a sheet over the overview: the web's six steps, in its order and
/// with its words, most of them run here (see ``SetupWizardModel``).
///
/// ⚠️ A SHEET WITH ITS OWN `NavigationStack`, NOT A ``Route``, as ``DeleteAccountView`` is: the
/// flow is modal, and a restored back stack must never land a person in its middle. Where they
/// left off is the service's to say (``SetupFlow/firstOpen(_:)``).
///
/// ⛔ THE SHELL KEEPS THE THREE ACTIONS THAT MEAN THE SAME ON EVERY STEP: Finish later, Back,
/// Skip. A step's own primary action is a save whose shape only the step knows, so each step
/// draws it (the web replaces Cloudscape's Next the same way).
struct SetupWizardView: View {
    @State private var model: SetupWizardModel
    @State private var handOff: AppLinkHandOff?

    private let container: AppContainer
    private let onRenamed: () -> Void
    private let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(
        container: AppContainer,
        workspaceId: String,
        workspaceName: String,
        onRenamed: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: SetupWizardModel(
            container: container,
            workspaceId: workspaceId,
            workspaceName: workspaceName
        ))
        self.container = container
        self.onRenamed = onRenamed
        self.onClose = onClose
    }

    private static let top = "district-setup-top"

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                        content
                    }
                    .id(Self.top)
                    .padding(DistrictSpacing.gutter)
                    .districtReadableWidth()
                }
                // ⚠️ A NEW STEP OPENS AT ITS TOP, not wherever the last one was scrolled to.
                .onChange(of: model.active) { proxy.scrollTo(Self.top, anchor: .top) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(SetupCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ⚠️ THE PHONE PAD HAS NO RETURN KEY, so without this a number field's keyboard
                // could not be put away and covered the step's buttons.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(SetupCopy.done) {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                        )
                    }
                    .accessibilityIdentifier(A11yID.Setup.keyboardDone)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(SetupCopy.finishLater, action: onClose)
                        .disabled(model.isMoving)
                        .accessibilityIdentifier(A11yID.Setup.finishLater)
                }
            }
            .districtBackground()
        }
        // ⚠️ NO SWIPE AWAY MID-WRITE: the answer would land on a sheet nobody sees.
        .interactiveDismissDisabled(model.isMoving)
        .task { await model.load() }
        .sheet(item: $handOff, onDismiss: { Task { await model.refreshAfterHandOff() } }, content: { handOff in
            SafariView(url: handOff.url)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.root)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(message: SetupCopy.loading)
                .accessibilityIdentifier(A11yID.Setup.loading)
        case let .refused(refusal):
            ending(
                symbol: "person.badge.key",
                title: refusal == .notOwner ? SetupCopy.notOwnerTitle : SetupCopy.notAvailableTitle,
                message: refusal == .notOwner ? SetupCopy.notOwnerBody : SetupCopy.notAvailableBody,
                identifier: A11yID.Setup.refused
            )
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.load() } })
                .accessibilityIdentifier(A11yID.Setup.failed)
        case .finished:
            ending(
                symbol: "checkmark.circle",
                title: SetupCopy.finishedTitle,
                message: SetupCopy.finishedBody,
                identifier: A11yID.Setup.finished
            )
        case .ready:
            SetupProgressHeader(model: model)
            step
                .id(model.active)
            if let error = model.stepError {
                SetupErrorLine(text: error.message)
                    .accessibilityIdentifier(A11yID.Setup.stepError)
            }
            footer
        }
    }

    private func ending(symbol: String, title: String, message: String, identifier: String) -> some View {
        EmptyStateView(systemImage: symbol, title: title, message: message) {
            Button(SetupCopy.done, action: onClose)
                .buttonStyle(.districtPrimary)
                .accessibilityIdentifier(A11yID.Setup.done)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var step: some View {
        let open: (URL) -> Void = { handOff = AppLinkHandOff(url: $0) }
        switch model.active {
        case .business:
            SetupBusinessStep(wizard: model, container: container, open: open, onRenamed: onRenamed)
        case .number:
            SetupNumberStep(wizard: model, baseURL: container.baseURL, open: open)
        case .receptionist:
            SetupReceptionistStep(wizard: model, container: container)
        case .callers:
            SetupCallersStep(wizard: model)
        case .calls:
            SetupCallsStep(wizard: model, container: container, open: open)
        case .golive:
            SetupGoLiveStep(wizard: model, container: container)
        }
    }

    /// Back and Skip, the two moves every step shares.
    private var footer: some View {
        HStack(spacing: DistrictSpacing.tight) {
            if SetupFlow.previous(before: model.active) != nil {
                Button(SetupCopy.back) { model.back() }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.isMoving)
                    .accessibilityIdentifier(A11yID.Setup.back)
            }
            Spacer(minLength: 0)
            Button(SetupCopy.skipStep) { Task { await model.skip() } }
                .buttonStyle(.districtGhost)
                .disabled(model.isMoving)
                .accessibilityIdentifier(A11yID.Setup.skip)
        }
        .padding(.top, DistrictSpacing.tight)
    }
}

/// "Step n of 6", a segment per step, and the step's title and description.
///
/// ⚠️ THE SEGMENTS ARE ONE ACCESSIBILITY ELEMENT whose value is the sentence, and each
/// step's state is said in words, never only by its colour.
struct SetupProgressHeader: View {
    let model: SetupWizardModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        let position = SetupFlow.position(of: model.active) + 1
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            HStack(spacing: DistrictSpacing.hairline) {
                ForEach(SetupFlow.steps, id: \.self) { step in
                    Capsule()
                        .fill(fill(step))
                        .frame(height: 4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SetupCopy.progressLabel)
            .accessibilityValue(spokenProgress)
            .accessibilityIdentifier(A11yID.Setup.progress)
            Text(SetupCopy.stepOf(position, SetupFlow.steps.count))
                .font(DistrictType.label)
                .foregroundStyle(colors.mutedForeground)
                .accessibilityHidden(true)
            Text(SetupFlow.title(model.active))
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(SetupCopy.stepOf(position, SetupFlow.steps.count) + ", " + SetupFlow
                    .title(model.active))
            SetupNote(text: SetupFlow.description(model.active))
        }
    }

    private func fill(_ step: SetupStep) -> Color {
        if step == model.active {
            return colors.district
        }
        switch model.state(of: step) {
        case .done: return colors.success
        case .skipped: return colors.mutedForeground.opacity(0.5)
        default: return colors.border
        }
    }

    private var spokenProgress: String {
        SetupFlow.steps.map { step in
            let word: String = if step == model.active {
                SetupCopy.stepCurrent
            } else {
                switch model.state(of: step) {
                case .done: SetupCopy.stepDone
                case .skipped: SetupCopy.stepSkipped
                default: SetupCopy.stepTodo
                }
            }
            return SetupFlow.title(step) + ": " + word
        }
        .joined(separator: ", ")
    }
}

/// Which workspace the wizard sheet is open for, and whether step 1 renamed it.
///
/// ⚠️ A CLASS, so the flag set inside the sheet is still readable in its `onDismiss`.
@MainActor
final class SetupWizardTarget: Identifiable {
    let workspaceId: String
    let workspaceName: String
    var renamed = false

    nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    init(workspaceId: String, workspaceName: String) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
    }
}

/// Presents the wizard for a target, and tidies up after it closes.
///
/// ⚠️ THE WORKSPACE LIST IS READ AGAIN ONLY AFTER A RENAME: a reload takes the whole shell
/// through its loading state, which a close with nothing renamed must not cost. The card is
/// always asked again, because a finished wizard retires it.
private struct SetupWizardSheet: ViewModifier {
    @Binding var target: SetupWizardTarget?
    let container: AppContainer
    let workspaceSession: WorkspaceSessionModel
    let card: FinishSetupModel

    /// The target, kept past the sheet's close so `onDismiss` can read whether it renamed.
    @State private var last: SetupWizardTarget?

    func body(content: Content) -> some View {
        content
            .onChange(of: target?.id) {
                if let target {
                    last = target
                }
            }
            .sheet(item: $target, onDismiss: closed, content: { target in
                SetupWizardView(
                    container: container,
                    workspaceId: target.workspaceId,
                    workspaceName: target.workspaceName,
                    onRenamed: { target.renamed = true },
                    onClose: { self.target = nil }
                )
                .districtSheetBackground()
            })
    }

    private func closed() {
        let renamed = last?.renamed == true
        last = nil
        Task {
            if renamed {
                await workspaceSession.load()
            }
            if let workspaceId = workspaceSession.workspaceId {
                await card.refresh(workspaceId: workspaceId)
            }
        }
    }
}

extension View {
    func setupWizardSheet(
        _ target: Binding<SetupWizardTarget?>,
        container: AppContainer,
        workspaceSession: WorkspaceSessionModel,
        card: FinishSetupModel
    ) -> some View {
        modifier(SetupWizardSheet(target: target, container: container, workspaceSession: workspaceSession, card: card))
    }
}
