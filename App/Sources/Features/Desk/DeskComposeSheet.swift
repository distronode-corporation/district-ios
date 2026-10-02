import SwiftUI

/// Raise a ticket on a customer's behalf.
///
/// ⛔ FOR SOMETHING A CUSTOMER BROUGHT ANOTHER WAY, and the subtitle says so. The
/// agent files its own tickets at the end of a call it could not resolve; this form is
/// for a walk-in, an email or a note, which is why the opening message is stored as the
/// CUSTOMER's words rather than the team's — it is their problem, and attributing it to
/// the team would make the thread read as us talking to ourselves.
///
/// ⛔ THE DRAFT LIVES HERE AND NOT ON THE MODEL, so a dismissed sheet takes it with it
/// and a reopened one starts clean. ⚠️ It survives a FAILED submit, though: losing a
/// typed ticket to a failed request would be two losses for one fault.
///
/// ⚠️ THE THREE REQUESTER BOXES MAY ALL BE BLANK. A ticket with no contact details is
/// legitimate; what is not legitimate is sending one of them as an empty string, which
/// fails `.email()` server-side and takes the whole request down. The repository trims
/// to nil, and this form never has to know that.
struct DeskComposeSheet: View {
    let model: DeskModel

    @State private var draft = DeskComposerState()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    Text(DeskCopy.composeSubtitle)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    fields
                    requester
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(DeskCopy.composeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            SettingsField(
                label: DeskCopy.subjectLabel,
                // ⛔ A CLOSURE LITERAL, NEVER A BARE METHOD REFERENCE. A bare
                // MainActor-isolated method as a `Binding` setter aborts the compiler
                // in IRGen under Swift 6 with no `error:` line; a lint rule catches it.
                text: Binding(get: { draft.subject }, set: { draft.subject = $0 }),
                enabled: !model.creating
            )
            SettingsField(
                label: DeskCopy.messageLabel,
                text: Binding(get: { draft.message }, set: { draft.message = $0 }),
                enabled: !model.creating,
                multiline: true
            )
        }
    }

    private var requester: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            SettingsField(
                label: DeskCopy.requesterNameLabel,
                text: Binding(get: { draft.requesterName }, set: { draft.requesterName = $0 }),
                enabled: !model.creating
            )
            SettingsField(
                label: DeskCopy.requesterEmailLabel,
                text: Binding(get: { draft.requesterEmail }, set: { draft.requesterEmail = $0 }),
                enabled: !model.creating
            )
            SettingsField(
                label: DeskCopy.requesterPhoneLabel,
                text: Binding(get: { draft.requesterPhone }, set: { draft.requesterPhone = $0 }),
                enabled: !model.creating
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(DeskCopy.cancel) { dismiss() }
                .disabled(model.creating)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(DeskCopy.createAction) { Task { await submit() } }
                // ⛔ DISABLED FOR THE WHOLE ROUND TRIP. The idempotency key is minted
                // per submit and the server's claim is fail-open, so a second tap on a
                // slow network can genuinely put two tickets in a human's queue.
                // ⚠️ A DISABLED BUTTON DOES NOT STOP TWO TAPS DISPATCHED BEFORE A
                // RE-RENDER; ``DeskModel/createTicket(_:)`` refuses the second itself.
                .disabled(model.creating || !draft.isComplete)
                .keyboardShortcut(.districtSubmit)
        }
    }

    /// ⚠️ THE SHEET CLOSES ONLY ON A CONFIRMED SUCCESS. A dismissed sheet takes the
    /// draft with it, so closing on a failure would discard what was typed at exactly
    /// the moment it still needs to be sent.
    private func submit() async {
        let ok = await model.createTicket(draft)
        if ok {
            dismiss()
        }
    }
}
