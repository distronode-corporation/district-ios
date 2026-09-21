import DistrictModel
import SwiftUI

/// One contact in full, with the four mutations a detail screen offers.
///
/// ⚠️ EVERY MUTATING CONTROL IS GATED ON THE ROLE, which is false for a `viewer`.
/// All four contacts mutations exclude that role server-side, so offering the
/// controls would guarantee a 403 the user can do nothing about. The gate is an
/// affordance, not a security boundary — the server still enforces.
struct ContactDetailView: View {
    let workspaceId: String
    let contactId: String

    /// ⛔ STORED RATHER THAN ONLY HANDED TO THE MODELS, BECAUSE THE ROOM DESTINATION
    /// CARRIES IT AND MUST CARRY THE REAL ONE. `Route.activeRoom`'s role is what decides
    /// whether ``ActiveRoomModel`` may publish, and it fails CLOSED on nil — so deriving one
    /// from a boolean at the call site (`canMutate ? .client : nil`) would be this screen
    /// inventing a publish right the workspace list never granted.
    let role: WorkspaceRole?

    @State private var model: ContactDetailModel

    /// ⛔ ITS OWN MODEL, BECAUSE STARTING A ROOM IS NOT EDITING A CONTACT.
    /// ``ContactDetailModel``'s four mutations all end in a re-read of the same row and
    /// share one `saving` flag; this one mints a room, spends a METERED and unrecallable
    /// message, and then navigates. Folding it in would put an irreversible send behind the
    /// flag that guards a rename.
    @State private var videoCall: ContactVideoCallModel

    /// ⛔ THE CONTAINER'S ONE STORE, NOT A `@State` OF ITS OWN. A block performed on
    /// an inbox thread has to flip this screen's control and badge, and the inbox is
    /// a different tab with a different model — see the ⛔ on
    /// ``BlockedContactsStore``.
    private let blocked: BlockedContactsStore

    @Environment(\.dismiss) private var dismiss

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, contactId: String) {
        self.workspaceId = workspaceId
        self.contactId = contactId
        self.role = role
        blocked = container.blockedContacts
        _model = State(
            initialValue: ContactDetailModel(
                container: container,
                workspaceId: workspaceId,
                contactId: contactId,
                role: role
            )
        )
        _videoCall = State(
            initialValue: ContactVideoCallModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    var body: some View {
        content
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            // ⛔ `.contain` FIRST, or the dossier section below inherits this and the
            // two become indistinguishable. See SignInView's note.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Contacts.detailRoot)
            .task { await model.load() }
            // ⛔ THE BLOCKED SET IS RE-READ HERE AS WELL AS ON THE LIST, AND THIS
            // SCREEN IS NOT REACHED ONLY FROM THE LIST. A push notification opens a
            // contact by id, so the list's own read may never have run — and
            // ``BlockedContactsStore/isBlocked(_:in:)`` answers false for a
            // workspace it has not loaded, which would hide the badge on a caller
            // who is blocked. ⚠️ Separate `.task` from the contact load so one
            // failing does not skip the other; the store's read is silent by
            // design.
            .task { await blocked.refresh(workspaceId: workspaceId) }
            // ⛔ THE DOSSIER POLL, AND SWIFTUI OWNS ITS LIFETIME. `.task(id:)` runs
            // at most one instance, cancels it when this view disappears, and
            // starts a fresh one when the model bumps the generation — which it
            // does only on the transition INTO an in-flight status. An
            // unstructured `Task` stored in the model would need its own
            // cancellation and would be one forgotten `cancel()` away from
            // re-reading a contact nobody is looking at.
            .task(id: model.pollGeneration) { await model.pollWhileEnriching() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: "Loading contact…")
        case let .content(loaded):
            ContactDetailContentView(
                loaded: loaded,
                model: model,
                videoCall: videoCall,
                blocked: blocked,
                workspaceId: workspaceId,
                role: role,
                onDelete: deleteAndPop
            )
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    /// ⚠️ POPS ONLY ON SUCCESS. A failed delete leaves the contact on screen with
    /// the failure beside it, because the record is still there.
    private func deleteAndPop() {
        Task {
            if await model.delete() {
                dismiss()
            }
        }
    }
}

/// The loaded contact.
private struct ContactDetailContentView: View {
    let loaded: LoadedContact
    let model: ContactDetailModel
    let videoCall: ContactVideoCallModel
    /// The shared blocked set. See the ⛔ on ``ContactDetailView/blocked``.
    let blocked: BlockedContactsStore
    let workspaceId: String
    /// ⛔ THE ROLE AS THE WORKSPACE LIST REPORTED IT, carried through rather than derived.
    /// See the ⛔ on ``ContactDetailView/role``.
    let role: WorkspaceRole?
    let onDelete: () -> Void

    @State private var renaming = false
    @State private var confirmingDelete = false

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var contact: Contact {
        loaded.contact
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                identity
                attributes
                DossierSection(
                    contact: contact,
                    canMutate: model.canMutate,
                    busy: loaded.saving,
                    isEnrichable: model.isEnrichable,
                    isClearable: model.isClearable,
                    onEnrich: enrich,
                    onClearIntel: clearIntel
                )
                mutationFailure
                videoCallSection
                controls
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .sheet(isPresented: $renaming) {
            RenameContactSheet(initial: contact.name, saving: loaded.saving, onSave: rename)
        }
    }

    // MARK: - The contact's own fields

    /// ⚠️ EMAIL-FIRST: SHOW WHICHEVER IDENTIFIERS EXIST rather than assuming a
    /// phone number. A phone-less contact is legal, and any number of them coexist
    /// in one workspace.
    private var identity: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(contact.displayName ?? "Unnamed contact")
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
            // ⛔ IN THE HEADER, ABOVE THE IDENTIFIERS, BECAUSE IT CHANGES WHAT THE
            // REST OF THE SCREEN MEANS. A blocked caller's timeline is still
            // readable here and their threads are gone from the Inbox, so a badge
            // further down would leave the two screens looking like they disagreed.
            if blocked.isBlocked(contact.id, in: workspaceId) {
                BlockedBadge(identifier: A11yID.Contacts.blockedBadge)
            }
            if let phone = contact.phoneNumber {
                Text(phone)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
            if let email = contact.email {
                Text(email)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
            if contact.phoneNumber == nil, contact.email == nil {
                Text("No phone or email")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }

    /// ⚠️ `company` IS DELIBERATELY NOT HERE. It is written by the DGI pipeline
    /// rather than typed by the operator, and `clear-intel` nulls it alongside
    /// `intelligence` — so it belongs in ``DossierSection``, where clearing it is
    /// not a surprise.
    @ViewBuilder
    private var attributes: some View {
        card("Latest context", contact.latestContextSummary)
        card("Budget", contact.budget)
        card("Timeline", contact.timeline)
        card("Website", contact.website)
        card("Added", ContactDates.readable(contact.createdAt))
    }

    /// ⚠️ Rendered only when the value is present AND not blank. `contacts/update`
    /// writes `""` into budget, timeline and website on every edit, so blank is
    /// the common case rather than the exotic one.
    @ViewBuilder
    private func card(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContactCard(label: label, value: value)
        }
    }

    // MARK: - Mutations

    /// ⚠️ SHOWN ALONGSIDE THE CONTACT, NOT INSTEAD OF IT: a failed rename does not
    /// invalidate the data already on screen, and blanking it would lose what the
    /// operator was reading.
    @ViewBuilder
    private var mutationFailure: some View {
        if let failure = loaded.mutationFailure {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                Button("Dismiss") { model.clearMutationFailure() }
                    .buttonStyle(.districtGhost)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DistrictSpacing.gutter)
            .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        }
    }

    /// ⚠️ Only ever composed for a role the server would admit; a viewer gets the
    /// caption instead, stated up front rather than discovered by tapping
    /// something that 403s.
    @ViewBuilder
    private var controls: some View {
        if model.canMutate {
            Button("Rename") { renaming = true }
                .buttonStyle(.districtSecondary)
                .disabled(loaded.saving)
            // ⛔ THE GUIDELINE 1.2 CONTROL, AND IT SITS BETWEEN RENAME AND DELETE
            // RATHER THAN BESIDE DELETE. A block is reversible in one tap and a
            // delete is not; grouping them would invite the mis-tap the
            // confirmation exists to catch. ⚠️ `.contact(contact.id)` rather than
            // the number: the id is exact and survives the number changing.
            ContactBlockControl(
                workspaceId: workspaceId,
                subject: .contact(contact.id),
                blocked: blocked.isBlocked(contact.id, in: workspaceId),
                busy: loaded.saving,
                store: blocked
            )
            BlockFailureNotice(store: blocked)
            Button("Delete contact") { confirmingDelete = true }
                .buttonStyle(.districtDestructive)
                .disabled(loaded.saving)
                // ⛔ CONFIRMED, BECAUSE A DELETE IS IRREVERSIBLE and a mis-tap in a
                // list costs a customer record. ⚠️ On the button, so the popover a
                // regular-width layout draws points at it.
                .confirmationDialog(
                    "Delete this contact? This cannot be undone.",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: onDelete)
                    Button("Cancel", role: .cancel) {}
                }
        } else {
            Text("Read-only access, editing is disabled.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    // MARK: - Video call

    /// Start a video room and send the contact its guest link.
    ///
    /// ⛔ ONE TAP IS ONE METERED, UNRECALLABLE MESSAGE. The button disables the moment an
    /// attempt starts and there is no retry on a failed send: a timeout means the invitation
    /// may already have reached the customer, so a second attempt is a second charge and a
    /// duplicate. See the ⛔ on ``ContactVideoCallModel``.
    ///
    /// ⛔ THE NAVIGATION IS A `NavigationLink` OVER THE ALREADY-MINTED NAME, never a
    /// button that assembles one at the destination. `Route.activeRoom`'s own ⛔ requires
    /// the full `meet_<workspaceId>_<suffix>` string in the value, because rebuilding a name
    /// is precisely where a `video_` one — one character away, billable, and capped at one
    /// concurrent session across the estate — could be produced by mistake.
    ///
    /// ⛔ SCREEN SHARE IS OUT OF SCOPE, and not because nobody got to it: it needs a
    /// Broadcast Upload Extension and an App Group, i.e. a new target and an entitlement.
    /// ⛔ SO IS AN AI-AVATAR (`video_`) ROOM: unmintable here by construction, billable,
    /// and concurrency-capped. Neither is re-litigable from a contact screen.
    @ViewBuilder
    private var videoCallSection: some View {
        if videoCall.canStart {
            switch videoCall.phase {
            case .idle:
                Button(ContactVideoCopy.action, action: startVideoCall)
                    .buttonStyle(.districtSecondary)
                    .disabled(loaded.saving || ContactVideoCallModel.target(for: contact) == nil)
            case .starting:
                Button(ContactVideoCopy.starting) {}
                    .buttonStyle(.districtSecondary)
                    .disabled(true)
            case let .sent(room):
                NavigationLink(value: Route.activeRoom(
                    workspaceId: workspaceId,
                    role: role,
                    roomName: room.value
                )) {
                    Text(ContactVideoCopy.action)
                }
                .buttonStyle(.districtPrimary)
            case let .failed(failure):
                videoCallFailure(failure)
            }
        }
    }

    /// ⚠️ SHOWN BESIDE THE CONTACT, NOT INSTEAD OF IT, and the only control offered is
    /// Dismiss. Whether the attempt is worth repeating is the model's claim to make, and for
    /// a failed SEND the answer is no. See the ⛔ in
    /// ``ContactVideoCallModel/invite(contact:target:room:credential:)``.
    private func videoCallFailure(_ failure: FailureText) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") { videoCall.reset() }
                .buttonStyle(.districtGhost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func startVideoCall() {
        Task { await videoCall.start(with: contact) }
    }

    private func rename(to name: String) {
        renaming = false
        Task { await model.rename(to: name) }
    }

    /// ⛔ ONE TAP, NO RETRY. See ``ContactDetailModel/enrich()``.
    private func enrich() {
        Task { await model.enrich() }
    }

    private func clearIntel() {
        Task { await model.clearIntel() }
    }
}

/// The rename form.
///
/// ⛔ A SHEET RATHER THAN AN `.alert` WITH A TEXT FIELD, DELIBERATELY. An alert's
/// `TextField` cannot be disabled while a write is in flight and gives the failure
/// nowhere to land, so a failed rename would dismiss the alert and drop its
/// sentence somewhere the operator is no longer looking. The failure lives on the
/// detail screen beside the contact; this sheet only collects the name.
///
/// ⚠️ THE DRAFT IS KEPT SEPARATE FROM THE LOADED CONTACT — it is `@State` here,
/// not a write into the model — which is what makes a failed rename leave the
/// screen showing the contact it already had.
private struct RenameContactSheet: View {
    let initial: String
    let saving: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var value: String

    init(initial: String, saving: Bool, onSave: @escaping (String) -> Void) {
        self.initial = initial
        self.saving = saving
        self.onSave = onSave
        _value = State(initialValue: initial)
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// Disabled for a blank or unchanged value: neither is an edit, and the server
    /// would reject a blank name as a validation error.
    private var canSave: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !saving && !trimmed.isEmpty && trimmed != initial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text("Contact name")
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            TextField("Contact name", text: $value)
                .disabled(saving)
                .districtField()
            HStack(spacing: DistrictSpacing.tight) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.districtGhost)
                    .disabled(saving)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(value) }
                    .buttonStyle(.districtPrimary)
                    .disabled(!canSave)
                    .keyboardShortcut(.districtSubmit)
            }
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }
}

/// Formatting for the one date this screen shows.
///
/// ⛔ THE FORMATTER IS BUILT PER CALL RATHER THAN HELD IN A `static let`.
/// `ISO8601DateFormatter` is a non-`Sendable` class, so a stored static is a
/// concurrency error under Swift 6 language mode rather than a micro-optimisation
/// worth having — and this runs once per contact screen.
///
/// ⚠️ TWO PARSES, BECAUSE THE WIRE CARRIES MILLISECONDS. Prisma serialises
/// `createdAt` as `2026-08-19T09:41:00.000Z`, which the default
/// `ISO8601DateFormatter` refuses; `.withFractionalSeconds` is required, and the
/// plain form is kept as a fallback for a row written without them.
///
/// ⚠️ FALLS BACK TO THE RAW STRING RATHER THAN TO AN EMPTY CARD. An unparseable
/// instant is still information; hiding it would look like a contact with no
/// creation date.
enum ContactDates {
    static func readable(_ iso: String) -> String {
        // ⚠️ WRITTEN OUT RATHER THAN LOOPED OVER AN ARRAY OF OPTION SETS.
        // `ISO8601DateFormatter.Options` is an `OptionSet`, so it is itself
        // `ExpressibleByArrayLiteral` — an array of them written as a nested
        // literal is ambiguous to the type checker in exactly the way that
        // produces an unreadable error.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: iso) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return iso
    }
}
