import DistrictModel
import SwiftUI

/// The four destructive confirmations on this surface, as modifiers each row's own
/// button attaches.
///
/// ⛔ EVERY WRITE BELOW IS IMMEDIATE AND HAS NO UNDO, WHICH IS WHY EACH PROMPT
/// NAMES THE THING AND SAYS WHAT STOPS WORKING. `apiKeys.delete`,
/// `oauth.connections.delete`, `webhooks.delete` and `calendar.connections.delete`
/// all answer nothing at all, so there is no response to reconsider from.
///
/// ⚠️ `confirmationDialog` RATHER THAN A SHEET, matching `DevicesView`: it is the
/// platform's own destructive-action affordance, it carries the `.destructive` role
/// (which VoiceOver announces), and it cannot be dismissed into a half-state.
///
/// ⛔ ONE MODEL PER SCREEN, ONE DIALOG PER ROW, AND ONLY THE ROW THE MODEL IS ASKING
/// ABOUT PRESENTS. The model holds the pending row; every row's button carries a dialog
/// bound to `pending == this row`, so exactly one is ever up, and on a regular-width
/// layout, where a dialog is a popover, it points at the button that asked. See
/// ``SwiftUI/Binding/dialog(_:onDismiss:)``.
///
/// ⛔ THE PROMPTS ARE HOISTED TO `String` BEFORE THEY REACH THE MODIFIER. A ternary
/// or an interpolation passed straight to `.confirmationDialog` forces the type
/// checker to choose between the `LocalizedStringKey` overload and the
/// `StringProtocol` one at the call site, which is the kind of inference question
/// that produces an unreadable error. A named `String` picks the second
/// unambiguously.
extension View {
    /// Revoke one API key.
    func schedulingRevokeKeyDialogC(_ model: SchedulingAPIKeyRevokeModel, for key: SchedulingAPIKey) -> some View {
        let prompt = model.pending.map { SchedulingWriteCopyC.keyRevokePrompt($0.name) } ?? ""
        return confirmationDialog(
            prompt,
            isPresented: .dialog(model.pending?.id == key.id, onDismiss: model.cancel),
            titleVisibility: .visible
        ) {
            Button(SchedulingWriteCopyC.keyRevokeAction, role: .destructive) {
                Task { await model.confirm() }
            }
            Button(SchedulingWriteCopyC.cancel, role: .cancel, action: model.cancel)
        } message: {
            Text(SchedulingWriteCopyC.keyRevokeConfirm)
        }
    }

    /// Sign one connected app out.
    func schedulingRevokeAppDialogC(
        _ model: SchedulingOAuthConnectionRevokeModel,
        for connection: SchedulingOAuthConnection
    ) -> some View {
        let prompt = model.pending.map { SchedulingWriteCopyC.appRevokePrompt($0.clientName) } ?? ""
        return confirmationDialog(
            prompt,
            isPresented: .dialog(model.pending?.id == connection.id, onDismiss: model.cancel),
            titleVisibility: .visible
        ) {
            Button(SchedulingWriteCopyC.appRevokeAction, role: .destructive) {
                Task { await model.confirm() }
            }
            Button(SchedulingWriteCopyC.cancel, role: .cancel, action: model.cancel)
        } message: {
            Text(SchedulingWriteCopyC.appRevokeConfirm)
        }
    }

    /// Delete one webhook.
    func schedulingDeleteWebhookDialogC(
        _ model: SchedulingWebhookDeleteModel,
        for webhook: SchedulingWebhook
    ) -> some View {
        confirmationDialog(
            SchedulingWriteCopyC.webhookDeletePrompt,
            isPresented: .dialog(model.pending?.id == webhook.id, onDismiss: model.cancel),
            titleVisibility: .visible
        ) {
            Button(SchedulingWriteCopyC.webhookDeleteAction, role: .destructive) {
                Task { await model.confirm() }
            }
            Button(SchedulingWriteCopyC.cancel, role: .cancel, action: model.cancel)
        } message: {
            Text(SchedulingWriteCopyC.webhookDeleteConfirm)
        }
    }

    /// Unlink one calendar account.
    ///
    /// ⚠️ THE CANCEL BUTTON READS "Keep it connected" RATHER THAN "Cancel", because
    /// the destructive button next to it says "Disconnect" and two neutral-sounding
    /// words beside each other is where a mis-tap comes from.
    func schedulingDisconnectCalendarDialogC(
        _ model: SchedulingCalendarDisconnectModel,
        for connection: SchedulingCalendarConnection
    ) -> some View {
        let prompt = model.pending.map { SchedulingWriteCopyC.disconnectPrompt($0.accountEmail) } ?? ""
        return confirmationDialog(
            prompt,
            isPresented: .dialog(model.pending?.id == connection.id, onDismiss: model.cancel),
            titleVisibility: .visible
        ) {
            Button(SchedulingWriteCopyC.disconnectAction, role: .destructive) {
                Task { await model.confirm() }
            }
            Button(SchedulingWriteCopyC.disconnectKeep, role: .cancel, action: model.cancel)
        } message: {
            Text(SchedulingWriteCopyC.disconnectConfirm)
        }
    }
}
