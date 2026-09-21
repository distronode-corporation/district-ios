import SwiftUI

/// Add a contact.
///
/// ⛔ REQUIRES A NAME PLUS EITHER A PHONE OR AN EMAIL, NOT BOTH. Contacts became
/// email-first and the database deliberately admits any number of phone-less rows
/// per workspace, so demanding a number here would refuse legitimate input.
/// (`contacts/bulk-create` DISAGREES and requires a phone per row, silently
/// counting an email-only row as invalid; that inconsistency is server-side and
/// is not smoothed over here. Bulk create is not ported at all.)
///
/// ⚠️ ONLY EVER PRESENTED FOR A ROLE THE SERVER WOULD ADMIT — every contacts
/// mutation excludes `viewer` — and ``ContactsModel/create(name:phoneNumber:email:)``
/// refuses again on the way out, so the gate does not depend on this view being
/// the only caller.
///
/// ⛔ NO `NavigationStack` AND NO TOOLBAR. The two buttons are in the sheet's own
/// body deliberately: a stack here would be a second `Route.self` destination
/// registration waiting to happen the first time someone adds a link, and the
/// sheet has nowhere to navigate to.
struct CreateContactSheet: View {
    let model: ContactsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// ⚠️ `@State`, WHICH SURVIVES A REDRAW BUT NOT A SCENE RESTORE. Android
    /// needed `rememberSaveable` here because its activity is destroyed by a
    /// rotation or a dark-mode toggle; SwiftUI does not destroy a presented
    /// sheet's state for either. ⛔ It is still the only place in this app that
    /// holds typed input, so if this ever moves into a pushed destination it
    /// needs `@SceneStorage` or the same bug arrives by a different route.
    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var saving: Bool {
        if case .saving = model.createState {
            return true
        }
        return false
    }

    /// A name is mandatory; one contact method is mandatory; which one is the
    /// user's choice.
    private var hasContactMethod: Bool {
        !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        !saving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasContactMethod
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text("Add contact")
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            field("Name", text: $name)
            field("Phone number", text: $phone)
            field("Email", text: $email)
            hint
            failure
            buttons
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }

    // MARK: - Pieces

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            TextField(label, text: text)
                .disabled(saving)
                .districtField()
        }
    }

    /// ⚠️ GUIDANCE, NOT AN ERROR, because it is the normal starting state of the
    /// form. It appears only once a name has been typed, so an untouched sheet
    /// does not open with a complaint.
    @ViewBuilder
    private var hint: some View {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasContactMethod {
            Text("Enter a phone number or an email address.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ A **409** LANDS HERE AS THE ROUTE'S "already exists" SENTENCE RATHER
    /// THAN AS A SERVER FAULT: the database enforces one contact per phone and
    /// per lowercased email per workspace, and ``FailureText`` shows a 4xx message
    /// verbatim precisely so that stays true.
    @ViewBuilder
    private var failure: some View {
        if case let .failed(text) = model.createState {
            Text(text.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
        }
    }

    private var buttons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button("Cancel", action: cancel)
                .buttonStyle(.districtGhost)
                .disabled(saving)
                .keyboardShortcut(.cancelAction)
            Button(saving ? "Adding…" : "Add", action: submit)
                .buttonStyle(.districtPrimary)
                .disabled(!canSubmit)
                .keyboardShortcut(.districtSubmit)
        }
    }

    // MARK: - Actions

    /// ⚠️ THE LIST IS REFRESHED BEFORE THIS RETURNS, INSIDE `create`, so the sheet
    /// stays up showing "Adding…" until the rows behind it are correct. Dismissing
    /// first would drop the operator onto a list that does not yet contain the
    /// contact they just made.
    private func submit() {
        Task {
            await model.create(name: name, phoneNumber: phone, email: email)
            if case .created = model.createState {
                model.clearCreateState()
                dismiss()
            }
        }
    }

    private func cancel() {
        model.clearCreateState()
        dismiss()
    }
}
