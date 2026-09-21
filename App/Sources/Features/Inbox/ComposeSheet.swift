import DistrictModel
import SwiftUI

/// Start a conversation.
///
/// ⛔ WITHOUT THIS THE ONLY WAY INTO A THREAD IS A ROW THAT ALREADY EXISTS, which
/// makes the Inbox a reader rather than a client: an operator who wants to text a
/// customer first would have to open the web dashboard. This is the compose.
///
/// ⛔ TWO STEPS ON ONE SHEET, AND THE SECOND IS NOT REACHABLE UNTIL THE FIRST IS
/// SETTLED. Choosing WHO comes before choosing HOW, because the channel choices are a
/// property of the recipient — a contact's are its own stored columns, a typed
/// address's are derived from its shape (see the ⛔ on ``ComposeModel``'s channel
/// extension). Drawing both at once would offer SMS/Email segments with no addresses
/// behind them.
///
/// ⚠️ THE STRUCTURE IS ``DeskComposeSheet``'s: a `NavigationStack` with a toolbar
/// Cancel and a confirm, the draft held in `@State` on the sheet so a dismissal takes
/// it and a reopen starts clean, and the submit disabled for the whole round trip. The
/// gating and error handling are ``CreateContactSheet``'s: refused locally when the
/// role would be refused server-side, and a 4xx sentence shown verbatim.
///
/// ⚠️ THE DRAFT SURVIVES A FAILED SEND. Losing a typed message to a failed request
/// would be two losses for one fault, and on this surface the message may be the only
/// copy — nothing autosaves here, because there is no thread to save it against yet.
struct ComposeSheet: View {
    let model: ComposeModel
    /// ⛔ CALLED WITH THE RESOLVED THREAD, OR NOT AT ALL. A send whose thread could not
    /// be resolved still dismisses — the message went out — and the list behind is
    /// refreshed by the caller either way. See ``ComposeModel/landing``.
    let onSent: (Route?) -> Void

    @State private var messageText = ""
    @State private var subject = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var sending: Bool {
        if case .sending = model.sendState {
            return true
        }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    recipientSection
                    if model.recipient != nil {
                        channelSection
                        messageSection
                    }
                    failure
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // ⛔ ``ComposeModel/prepare()``, NOT A BARE READ. The model is held at the
            // inbox screen's scope so a presentation cannot rebuild it mid-flight, which
            // means a cancelled compose would otherwise reopen holding the last
            // recipient, channel and failure sentence. `prepare()` clears those and
            // re-reads the contact window; the typed message lives in this sheet's own
            // `@State` and goes with the dismissal.
            .task { await model.prepare() }
        }
    }

    // MARK: - Who

    /// ⚠️ ONE FIELD THAT BOTH FILTERS AND IS ITSELF A RECIPIENT. A stranger's number
    /// needs no mode switch: the operator types it and taps the "Message …" row. A
    /// separate "or enter a number" box would make the common case (somebody already in
    /// the CRM) and the uncommon one look equally likely.
    @ViewBuilder
    private var recipientSection: some View {
        if let recipient = model.recipient {
            chosen(recipient)
        } else {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                SettingsField(
                    label: "To",
                    // ⛔ A CLOSURE LITERAL, NEVER A BARE METHOD REFERENCE — see the
                    // custom rule in `.swiftlint.yml`.
                    text: Binding(get: { model.query }, set: { model.query = $0 }),
                    enabled: !sending
                )
                typedAddressRow
                suggestions
                contactsCaption
            }
        }
    }

    /// The armed recipient, with a way back to choosing.
    private func chosen(_ recipient: ComposeRecipient) -> some View {
        // ⚠️ THE CHANGE BUTTON DROPS BELOW AT AN ACCESSIBILITY TEXT SIZE. Its label
        // grows with everything else and takes the width the address needs, and an
        // address middle-truncated to "j…m" does not tell the operator who this
        // message is about to go to — which is the one thing this line is for.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.tight))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DistrictSpacing.tight))
        return layout {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: "To")
                Text(Self.label(for: recipient))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            Button("Change") { model.clearRecipient() }
                .buttonStyle(.districtGhost)
                .disabled(sending)
        }
    }

    /// ⚠️ DRAWN ONLY WHEN SOMETHING HAS BEEN TYPED, so an untouched sheet does not
    /// invite the operator to message an empty string.
    @ViewBuilder
    private var typedAddressRow: some View {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Button("Message \(trimmed)") { model.useTypedAddress() }
                .buttonStyle(.districtGhost)
                .disabled(sending)
        }
    }

    /// ⚠️ MATCHED ON NAME, NUMBER **AND** ADDRESS. A contact whose name is the literal
    /// "Unknown" — what the voice agent writes for an unidentified caller — is only
    /// findable by its number.
    @ViewBuilder
    private var suggestions: some View {
        switch model.contactsState {
        case .loading:
            SkeletonBlock(height: 44)
        case .ready:
            ForEach(model.matches, id: \.id) { contact in
                Button { model.choose(contact) } label: {
                    contactRow(contact)
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }
        case let .failed(failure):
            // ⛔ A CAPTION, NOT A DEAD END. Typing an address needs no CRM read, so a
            // failed suggestion list must not stop somebody composing.
            Text("\(failure.message) You can still enter a number or an email address above.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    private func contactRow(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(contact.displayName ?? contact.phoneNumber ?? contact.email ?? contact.name)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            if let detail = Self.detail(for: contact) {
                Text(detail)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DistrictSpacing.hairline)
    }

    /// ⛔ STATED, NOT SWALLOWED, exactly as the Inbox list's own partial caption is.
    /// The contacts route takes `limit` and `offset` and no search term at all, so this
    /// list is the newest window and a quieter contact is genuinely absent from it.
    /// Presenting a short list as if it were the whole CRM is the same class of mistake
    /// as reporting a degraded region's absence as "you have no workspaces".
    @ViewBuilder
    private var contactsCaption: some View {
        if case .ready = model.contactsState {
            Text("Showing your most recent contacts. For anyone else, type their number or email.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    // MARK: - How

    /// ⛔ BOTH CHANNELS DRAWN AT REST, FOR THE REASON THE THREAD COMPOSER'S PICKER IS
    /// SEGMENTED: the choice decides whether the message costs a carrier segment, and a
    /// collapsed menu shows the current value while hiding that there was a decision.
    ///
    /// ⚠️ ONE CHOICE IS STATED RATHER THAN OFFERED. A contact with only an email has
    /// nothing to pick between, and a picker with one segment invites a hunt for the
    /// other one.
    @ViewBuilder
    private var channelSection: some View {
        let choices = model.channelChoices
        if choices.count > 1 {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: "Send on")
                Picker("Send on", selection: channel) {
                    // ⚠️ BY INDEX RATHER THAN `enumerated()`, for the reason
                    // ``ComposerBar``'s own picker states: the two-parameter closure over
                    // a labelled tuple does not compile under Swift 6 mode.
                    ForEach(choices.indices, id: \.self) { index in
                        Text(ThreadChannelName.of(choices[index].channel)).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(sending)
                addressLine
            }
        } else if let only = choices.first {
            // ⚠️ THE BADGE AND THE ADDRESS STOP SHARING A LINE at an accessibility
            // size: the badge grows with its label and leaves the address a few
            // characters of a name it exists to show in full.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.hairline))
                : AnyLayout(HStackLayout(spacing: DistrictSpacing.tight))
            layout {
                DistrictBadge(text: ThreadChannelName.of(only.channel), tone: .info)
                addressLine
            }
        } else {
            // ⚠️ A CONTACT WITH NEITHER A NUMBER NOR AN ADDRESS IS LEGAL — the CRM is
            // email-first and admits phone-less rows — so this is a real state and it
            // gets a sentence rather than a disabled control with no explanation.
            Text("This contact has no phone number or email address on file.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
        }
    }

    /// ⚠️ TRUNCATED IN THE MIDDLE, never at the end: the tail of an email address is
    /// the half that says which person it is.
    @ViewBuilder
    private var addressLine: some View {
        if let target = model.target {
            Text(target.to)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
        }
    }

    /// ⛔ THROUGH ``ComposeModel/selectChannel(_:)`` AND AS A CLOSURE LITERAL. The
    /// method bounds-checks the index against the ARMED recipient's choices, which
    /// change when the recipient does; and a bare MainActor-isolated method as a
    /// `Binding` setter aborts the compiler in IRGen under Swift 6 (see the custom rule
    /// in `.swiftlint.yml`).
    private var channel: Binding<Int> {
        Binding(
            get: { model.selectedChannel },
            set: { model.selectChannel($0) }
        )
    }

    // MARK: - What

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            // ⛔ REQUIRED ON EMAIL, WHICH IS WHY IT IS A CONTROL AND NOT A CAPTION.
            // `messages/send` substitutes "Message from District" for a blank subject
            // and DELIVERS, so this is the last place a missing one can be caught —
            // and on a FIRST email that literal is the first thing the customer ever
            // sees from this workspace. ⚠️ Nothing is seeded: there is no thread to
            // derive a `Re:` from, and this client invents no topic.
            if model.requiresSubject {
                SettingsField(
                    label: "Subject",
                    text: Binding(get: { subject }, set: { subject = $0 }),
                    enabled: !sending
                )
            }
            SettingsField(
                label: "Message",
                text: Binding(get: { messageText }, set: { messageText = $0 }),
                enabled: !sending,
                multiline: true
            )
        }
    }

    /// ⚠️ THE SERVER'S OWN SENTENCE, VERBATIM. An unverified sender, an exhausted A2P
    /// registration and the per-workspace 30/min cap each need a different action from
    /// the operator, and "could not send" throws all of that away.
    @ViewBuilder
    private var failure: some View {
        if case let .failed(text) = model.sendState {
            Text(text.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(sending)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(sending ? "Sending…" : "Send") { Task { await submit() } }
                // ⛔ DISABLED FOR THE WHOLE ROUND TRIP, AND THAT GUARD IS ABOUT MONEY.
                // A send is billable carrier segments or a Postmark send, capped at
                // 30/min per workspace; a second tap must not become a second charge
                // and a message the customer receives twice.
                .disabled(!model.canSendNow(body: messageText, subject: subject))
                .keyboardShortcut(.districtSubmit)
        }
    }

    /// ⛔ THE SHEET CLOSES ON A SENT MESSAGE EVEN WHEN THE THREAD COULD NOT BE RESOLVED,
    /// and that is the deliberate half. The message has gone out, so keeping the sheet
    /// up with the text still in it would invite a second send — a second charge and a
    /// duplicate for the customer. The caller refreshes the list instead; the new
    /// thread is at the top of it.
    private func submit() async {
        guard await model.send(body: messageText, subject: subject) else { return }
        onSent(model.landing)
        dismiss()
    }

    private static func label(for recipient: ComposeRecipient) -> String {
        switch recipient {
        case let .contact(contact):
            contact.displayName ?? contact.phoneNumber ?? contact.email ?? contact.name
        case let .typed(address):
            address
        }
    }

    /// ⚠️ BOTH ADDRESSES WHERE THERE ARE BOTH, because the row is how an operator
    /// confirms they picked the right Ada.
    private static func detail(for contact: Contact) -> String? {
        let parts = [contact.phoneNumber, contact.email].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
