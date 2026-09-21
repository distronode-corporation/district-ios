import SwiftUI

/// The flag. One optional note, one Report button, one confirmation.
///
/// ⛔ A SHEET RATHER THAN AN `.alert` WITH A TEXT FIELD, for the reason
/// `RenameContactSheet` gives: an alert's `TextField` cannot be disabled while a
/// write is in flight and gives the failure nowhere to land, so a failed report would
/// dismiss the alert and drop the server's own sentence somewhere the operator is no
/// longer looking. Here the failure stays in the sheet beside the note they typed.
///
/// ⛔ IT DOES NOT DISMISS ITSELF ON SUCCESS. Apple's ask is that the reviewer SEE the
/// flag being accepted, and a sheet that closed the instant the request landed would
/// be indistinguishable on video from one that failed. The confirmation is the
/// screen, and Done is the way out.
///
/// ⚠️ ONE SHEET REACHED FROM TWO PLACES — an inbox thread and a call — differing only
/// in ``ReportTarget``. Two sheets would be two things a reviewer has to watch once
/// each, and two sets of identifiers for the same mechanism.
struct ReportSheet: View {
    @State private var model: ReportContentModel

    /// ⚠️ THE STORAGE IS NOT THE BINDING. ``note`` below clamps every write to the
    /// route's limit, so nothing may bind to this property directly.
    @State private var noteText = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, target: ReportTarget) {
        _model = State(
            initialValue: ReportContentModel(container: container, workspaceId: workspaceId, target: target)
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(model.headline)
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            content
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⛔ `.contain` FIRST, or this identifier is inherited by the note field and
        // both buttons and none of them can be addressed. Same trap `SignInView`'s
        // root documents, measured there rather than reasoned about.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Report.root)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .sending:
            form
        case let .done(sentence):
            accepted(sentence)
        case let .failed(sentence):
            // ⚠️ THE FORM STAYS UNDER THE FAILURE, WITH THE NOTE STILL IN IT. The
            // write carries an idempotency key minted once per sheet, so pressing
            // Report again collapses onto the first attempt rather than filing a
            // second ticket — which is why the control is left armed at all.
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                Text(sentence)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                form
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(ReportCopy.noteLabel)
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(colors.mutedForeground)
                // ⚠️ OPTIONAL, AND THE PLACEHOLDER SAYS SO. Guideline 1.2 asks for a
                // mechanism to FLAG content; requiring an explanation would make the
                // flag conditional on the reporter being able to articulate why.
                TextField(ReportCopy.notePrompt, text: note, axis: .vertical)
                    .lineLimit(3 ... 6)
                    .disabled(model.isSending)
                    .districtField()
                    .accessibilityIdentifier(A11yID.Report.note)
            }
            HStack(spacing: DistrictSpacing.tight) {
                Button(ReportCopy.cancel) { dismiss() }
                    .buttonStyle(.districtGhost)
                    .disabled(model.isSending)
                    .accessibilityIdentifier(A11yID.Report.cancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.isSending ? "Reporting…" : ReportCopy.submit) {
                    Task { await model.submit(note: noteText) }
                }
                .buttonStyle(.districtPrimary)
                .disabled(model.isSending)
                .accessibilityIdentifier(A11yID.Report.submit)
                .keyboardShortcut(.districtSubmit)
            }
        }
    }

    private func accepted(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(sentence)
                .font(DistrictType.body)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.Report.confirmation)
            Button("Done") { dismiss() }
                .buttonStyle(.districtPrimary)
        }
    }

    /// The note, capped at what the route will take.
    ///
    /// ⛔ A CLAMPED BINDING RATHER THAN A VALIDATION MESSAGE, because the only thing
    /// an over-long note can do is 400 the request AFTER the server has claimed the
    /// idempotency key — which leaves a real row behind with no ticket. Refusing the
    /// keystroke is the cheaper refusal. ⚠️ The limit is a MIRROR of the server's
    /// (see ``ReportCopy/noteLimit``); if the two disagree the server is right.
    private var note: Binding<String> {
        Binding(
            get: { noteText },
            set: { noteText = String($0.prefix(ReportCopy.noteLimit)) }
        )
    }
}
