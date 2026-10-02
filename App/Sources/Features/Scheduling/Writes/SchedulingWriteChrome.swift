import SwiftUI

/// What one scheduling-admin write is doing, and what it came to.
///
/// ⛔ ONE STATE FOR EVERY WRITE SHEET ON THE SURFACE. Two parallel enums (one with a
/// bare `saved` beside a separate notice, one carrying the sentence) drew the same
/// outcome two ways, and every fix had to be made twice.
///
/// ⛔ A SUCCESS CARRIES A SENTENCE RATHER THAN BEING A BARE `saved`, BECAUSE SOME OF
/// THESE WRITES DO NOT HAVE ONE FIXED OUTCOME. `recordings.deleteAll` answers a TALLY
/// and a partial failure is a **200**, so "all deleted" is a sentence this client has
/// to compose from the numbers rather than one it may assume; the reschedule names the
/// new time because "Booking moved" alone does not let an operator check they moved it
/// to the day they meant. The web flashes exactly these strings and they are ported
/// rather than re-invented.
///
/// ⚠️ NO `savedButStale`, WHICH IS THE DIFFERENCE FROM ``SettingsSaveState`` AND IS A
/// PROPERTY OF THE ROUTE RATHER THAN A SIMPLIFICATION. Every workspace-settings write
/// answers `{"success": true}` and has to be re-read; every scheduling-admin write here
/// either ECHOES the row it wrote or answers nothing and hands the re-read to the screen
/// that owns the list, so a fifth case would be a state no code path could reach.
///
/// ⚠️ ``failed(_:)`` KEEPS THE OPERATOR'S EDITS, same rule as the settings surface: a
/// refused save that also discarded what somebody typed is two losses for one fault.
enum SchedulingWriteState {
    case idle
    case working
    /// The web's own flash for this op.
    case done(String)
    case failed(FailureText)

    var isWorking: Bool {
        if case .working = self {
            return true
        }
        return false
    }

    var failure: FailureText? {
        guard case let .failed(text) = self else { return nil }
        return text
    }

    var notice: String? {
        guard case let .done(message) = self else { return nil }
        return message
    }
}

/// The container every scheduling write sheet draws in: a heading, an optional
/// subtitle and the body, in a scroll view.
///
/// ⛔ NO `NavigationStack` AND NO TOOLBAR, matching `MessagingAccountSheet` and
/// `CreateContactSheet`. `ShellView` registers `navigationDestination(for:)` once per
/// tab; a stack inside a sheet is a second registration waiting to happen, gives a
/// nested bar and a back gesture that dismisses nothing, and none of these sheets has
/// anywhere to navigate to. The dismissal is an explicit button in the body.
///
/// ⚠️ A `ScrollView`, ALWAYS. The webhook form is 7 checkboxes plus 22 more, and a
/// `VStack` that overflows on a small phone with Larger Text silently clips its submit
/// button, which is the one control the sheet exists for.
///
/// ⚠️ TWO INITIALISERS, ONE SHELL. A form that owns its own buttons passes only the
/// body; a confirm-style sheet passes the two labels, the write's state and the two
/// actions, and the shell draws the outcome line and the buttons under the body.
struct SchedulingWriteSheet<Content: View>: View {
    let title: String
    let subtitle: String?
    private let confirm: Confirm?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    /// The confirm bar a sheet asks the shell to draw.
    ///
    /// ⚠️ THE CONFIRM BUTTON IS THE ONE ELEMENT EVERY UI TEST ON SUCH A SHEET HAS TO
    /// ADDRESS, and it lives inside the shell rather than at the call site, so the
    /// identifier has to be passed in. Optional because a sheet with no test yet should
    /// not have to invent one.
    private struct Confirm {
        let cancelLabel: String
        let confirmLabel: String
        let destructive: Bool
        let confirmEnabled: Bool
        let confirmIdentifier: String?
        let state: SchedulingWriteState
        let onCancel: () -> Void
        let onConfirm: () -> Void
    }

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        confirm = nil
        self.content = content()
    }

    /// ⛔ `content`, `onCancel` AND `onConfirm` ARE LAST AND CONTIGUOUS, which is what
    /// lets a call site use MULTIPLE TRAILING CLOSURES. One trailing closure beside two
    /// parenthesised ones is a `multiple_closures_with_trailing_closure` violation on
    /// every sheet that uses this shell; all-trailing is not.
    init(
        title: String,
        subtitle: String?,
        cancelLabel: String,
        confirmLabel: String,
        destructive: Bool = false,
        confirmEnabled: Bool = true,
        confirmIdentifier: String? = nil,
        state: SchedulingWriteState,
        @ViewBuilder content: () -> Content,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        confirm = Confirm(
            cancelLabel: cancelLabel,
            confirmLabel: confirmLabel,
            destructive: destructive,
            confirmEnabled: confirmEnabled,
            confirmIdentifier: confirmIdentifier,
            state: state,
            onCancel: onCancel,
            onConfirm: onConfirm
        )
        self.content = content()
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                header
                content
                if let confirm {
                    SchedulingWriteOutcome(state: confirm.state)
                    buttons(confirm)
                }
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
                // ⚠️ THE SHEET'S OWN HEADING IS THE HEADER FOR VoiceOver. Without it
                // the first element read is whatever control happens to be first, and
                // on a destructive sheet that is the thing the operator most needs to
                // hear last.
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ THE CONFIRM BUTTON IS DISABLED WHILE THE WRITE IS IN FLIGHT AND THE CANCEL
    /// BUTTON IS NOT. Leaving a destructive submit live under a spinner is how one tap
    /// becomes two requests; leaving the way out live is how somebody escapes a request
    /// that has stalled.
    ///
    /// ⚠️ THE STYLE IS NAMED RATHER THAN INLINE IN A TERNARY. `.districtDestructive`
    /// resolves through `ButtonStyle where Self == DistrictButtonStyle`, and a
    /// leading-dot pair inside a ternary at a generic parameter is exactly where that
    /// inference gets fragile.
    private func buttons(_ confirm: Confirm) -> some View {
        let style: DistrictButtonStyle = confirm.destructive ? .districtDestructive : .districtPrimary
        return VStack(spacing: DistrictSpacing.tight) {
            Button(confirm.confirmLabel, action: confirm.onConfirm)
                .buttonStyle(style)
                .disabled(!confirm.confirmEnabled || confirm.state.isWorking)
                .accessibilityIdentifier(confirm.confirmIdentifier ?? "")
                // ⛔ NO ⌘↩ ON A DESTRUCTIVE CONFIRM; see ``KeyboardShortcut/districtSubmit``.
                .keyboardShortcut(confirm.destructive ? nil : .districtSubmit)
            Button(confirm.cancelLabel, action: confirm.onCancel)
                .buttonStyle(.districtSecondary)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One labelled field: the label, the control, then a hint or an error.
struct SchedulingWriteField<Content: View>: View {
    let label: String
    var hint: String?
    var error: String?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            content
            if let hint, error == nil {
                SchedulingWriteHint(text: hint)
            }
            SchedulingWriteRejection(message: error)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The muted sentence under a field, carrying a limit or a consequence.
///
/// ⚠️ ITS OWN COMPONENT SO EVERY HINT RESOLVES THE PALETTE THE SAME WAY. The
/// alternative is `DistrictColors.resolve(colorScheme)` repeated at a dozen call sites,
/// which is where somebody eventually writes `.resolve(.light)` and the hint disappears
/// in dark mode.
struct SchedulingWriteHint: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A validation refusal, which is not a failure and must not be drawn as one.
///
/// ⚠️ NO REQUEST WAS SPENT. "That did not save" would be describing something that
/// never happened; what these say is what to change before trying. A refused WRITE is
/// ``SchedulingWriteFailureLine``.
struct SchedulingWriteRejection: View {
    let message: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let message {
            Text(message)
                .font(DistrictType.caption)
                .foregroundStyle(DistrictColors.resolve(colorScheme).destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One refused write, as a sentence and, where it is honest, an offer.
///
/// ⛔ A FAILURE IS NEVER RENDERED AS AN ABSENCE, which is the rule ``FailureText``
/// exists to enforce, and it is why this takes the whole value rather than a `String`:
/// the ACTION decides whether a retry is offered, and a retry offered for a role
/// refusal is worse than none at all.
///
/// ⚠️ A SHEET WHOSE OWN SUBMIT BUTTON IS STILL LIVE PASSES NO `onRetry`. There the
/// retry IS the submit button, and a second one beside it would be two ways to send
/// the same request, the more dangerous of them the one that did not re-check the
/// form.
struct SchedulingWriteFailureLine: View {
    let failure: FailureText
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(DistrictColors.resolve(colorScheme).destructive)
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ RETRY IS DRAWN ONLY FOR `.retry`. `.signIn` is unreachable from the admin RPC
    /// (a 401 collapses to `forbidden` inside `SchedulingAdminError`), so there is no
    /// sign-in control here to go stale.
    private var controls: some View {
        HStack(spacing: DistrictSpacing.tight) {
            if failure.action == .retry, let onRetry {
                Button(SchedulingWriteCopy.retry, action: onRetry)
                    .buttonStyle(.districtSecondary)
            }
            if let onDismiss {
                Button(SchedulingWriteCopy.dismiss, action: onDismiss)
                    .buttonStyle(.districtGhost)
            }
        }
    }
}

/// A positive sentence after a write that landed.
struct SchedulingWriteNoticeLine: View {
    let message: String
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(DistrictColors.resolve(colorScheme).success)
            if let onDismiss {
                Button(SchedulingWriteCopy.dismiss, action: onDismiss)
                    .buttonStyle(.districtGhost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a write came to, as one line under the form.
///
/// ⛔ A SUCCESS AND A FAILURE ARE THE SAME SLOT AND NOT THE SAME TONE. Both have to
/// appear in the place the operator is already looking, under the button they
/// pressed, and a green sentence rendered in the failure's register (or the reverse)
/// is how somebody reads "3 deleted, 2 could not be deleted" as done.
struct SchedulingWriteOutcome: View {
    let state: SchedulingWriteState
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        switch state {
        case .idle, .working:
            EmptyView()
        case let .done(message):
            SchedulingWriteNoticeLine(message: message, onDismiss: onDismiss)
        case let .failed(failure):
            SchedulingWriteFailureLine(failure: failure, onRetry: onRetry, onDismiss: onDismiss)
        }
    }
}

/// Cancel beside the one button that spends a request, for a form that draws its own.
struct SchedulingWriteButtons: View {
    let saveTitle: String
    let saving: Bool
    var enabled = true
    let saveIdentifier: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopy.cancel) {
                onCancel()
            }
            .buttonStyle(.districtGhost)
            .disabled(saving)
            .accessibilityIdentifier(A11yID.SchedulingWrites.editorCancel)
            .keyboardShortcut(.cancelAction)
            Button(saving ? SchedulingWriteCopy.saving : saveTitle) {
                onSave()
            }
            .buttonStyle(.districtPrimary)
            .disabled(saving || !enabled)
            .accessibilityIdentifier(saveIdentifier)
            .keyboardShortcut(.districtSubmit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tick box with an optional badge beside its label.
///
/// ⚠️ A `Toggle` WITH `.switch` RATHER THAN A CHECKBOX, because iOS has no checkbox
/// and `.checkbox` is macOS-only. The semantics a screen reader reports are the
/// same; the shape is the platform's.
struct SchedulingWriteToggleRow: View {
    let label: String
    let isOn: Binding<Bool>
    var badge: String?
    var enabled = true

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DistrictSpacing.hairline) {
                Text(label)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                if let badge {
                    Text(badge)
                        .font(DistrictType.labelSmall)
                        .foregroundStyle(Tone.danger.ink(colors))
                        .padding(.horizontal, DistrictSpacing.hairline)
                        .background(
                            Tone.danger.fill(colors),
                            in: RoundedRectangle(cornerRadius: DistrictRadius.badge)
                        )
                }
            }
        }
        .disabled(!enabled)
    }
}

/// A read-only `label: value` line, for the facts a write sheet states and cannot
/// change.
struct SchedulingWriteFact: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(value)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Names the image row still spells

// ⚠️ `SchedulingWritesBImageRow.swift` STILL SPELLS THE PRE-MERGE NAMES and belongs to
// another change set. These aliases point it at the one implementation above; delete
// them when that file is renamed.
typealias SchedulingWritesBState = SchedulingWriteState
typealias SchedulingWritesBHint = SchedulingWriteHint
typealias SchedulingWritesBNotice = SchedulingWriteOutcome
