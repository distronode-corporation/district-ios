import DistrictData
import DistrictModel
import SwiftUI

/// The words every blocking surface uses, in one place.
///
/// ⛔ THE CONFIRMATION SAYS WHAT BLOCKING DOES **AND** THAT IT IS REVERSIBLE, which
/// is the whole difference between this dialog and the delete one next to it. A bare
/// "are you sure?" on a control an App Review reviewer is about to tap on camera
/// tells them nothing about the mechanism they asked to see; and a prompt that read
/// like the irreversible delete would make an operator hesitate over something they
/// can undo in one tap.
///
/// ⚠️ IT DOES NOT CLAIM THE CALLER CANNOT REACH THE WORKSPACE. Blocking hides their
/// threads and calls from these screens and stops the conversations route returning
/// them; it does not stop a phone ringing at a carrier. Wording it as "they can no
/// longer contact you" would be a promise the service does not keep.
enum ContactBlockCopy {
    static let block = "Block caller"
    static let unblock = "Unblock caller"
    static let badge = "Blocked"

    static let blockPrompt =
        "Block this caller? Their conversations and calls stop appearing in this workspace. "
            + "You can unblock them here at any time."

    static let unblockPrompt =
        "Unblock this caller? Their conversations and calls start appearing in this workspace again."

    /// ⚠️ THE BUTTON INSIDE THE DIALOG, WHICH IS NOT THE SAME STRING AS THE CONTROL
    /// THAT OPENED IT. "Block caller" on both would read as a dialog that had not
    /// registered the first tap.
    static let confirmBlock = "Block"
    static let confirmUnblock = "Unblock"
    static let cancel = "Cancel"
}

/// The "Blocked" badge.
///
/// ⛔ `.danger` RATHER THAN `.warning` OR `.neutral`, AND THE TONE IS THE MESSAGE. A
/// blocked caller is a state somebody chose and that is hiding content from this
/// screen; neutral would make it read as metadata, and a reviewer scanning a contact
/// list for evidence that blocking works needs to find it at a glance.
///
/// ⚠️ THE IDENTIFIER IS A PARAMETER because the same badge appears on a list row and
/// on a detail header, and those have to be separately addressable — a walk that
/// asserted one could not tell which screen it was standing on.
struct BlockedBadge: View {
    let identifier: String

    var body: some View {
        DistrictBadge(text: ContactBlockCopy.badge, tone: .danger)
            .accessibilityIdentifier(identifier)
    }
}

/// The block/unblock control, with its confirmation.
///
/// ⛔ IT OWNS ITS OWN DIALOG STATE AND READS THE SHARED STORE, which is what lets it
/// be dropped into two screens without either of them learning about blocking.
/// ``ContactDetailView`` already carries three `@State` confirmations and is at the
/// length where a fourth would push the file past SwiftLint's ceiling.
///
/// ⛔ THE STATE IS THE SERVER'S, ASKED OF THE STORE EVERY REDRAW RATHER THAN
/// REMEMBERED. `blocked` is not a `let` on this view: a block performed from an inbox
/// thread has to flip this control the next time the contact screen is looked at, and
/// a captured boolean could not.
///
/// ⚠️ EVERY CONTACT MUTATION EXCLUDES `viewer` SERVER-SIDE, so the caller gates this
/// on ``WorkspaceRole/allowsMutation(_:)`` and never renders it for a read-only seat.
/// The gate is an affordance; the server stays the authority.
struct ContactBlockControl: View {
    let workspaceId: String

    /// ⛔ A ``BlockSubject``, NOT A PAIR OF OPTIONALS. Exactly one identity reaches
    /// the route, and the enum is what makes "both" and "neither" unspellable at
    /// every call site. See the type in `DistrictData`.
    let subject: BlockSubject

    /// Whether the contact is blocked RIGHT NOW, read from the shared store.
    let blocked: Bool

    /// ⚠️ THE SCREEN'S OWN MUTATION FLAG, ORed WITH THE STORE'S. A rename in flight
    /// must disable this too: both end in a write against the same row.
    let busy: Bool

    let store: BlockedContactsStore

    /// ⚠️ CALLED ONLY AFTER THE SERVER CONFIRMED A **BLOCK**, never an unblock. The
    /// thread screen pops on one and stays on the other; a callback fired for both
    /// would close a screen the operator had just re-opened content on.
    var onBlocked: (() -> Void)?

    @State private var confirming = false

    var body: some View {
        Button(blocked ? ContactBlockCopy.unblock : ContactBlockCopy.block) {
            confirming = true
        }
        // ⚠️ `.districtSecondary` FOR BOTH DIRECTIONS RATHER THAN DESTRUCTIVE FOR
        // ONE. `.districtDestructive` is spoken for by Delete on the same screen,
        // and a block is reversible in one tap — giving it the same weight as
        // deleting a customer record would misstate both.
        .buttonStyle(.districtSecondary)
        .disabled(busy || store.busy)
        .accessibilityIdentifier(blocked ? A11yID.Contacts.unblock : A11yID.Contacts.block)
        // ⛔ CONFIRMED IN BOTH DIRECTIONS. Apple asks to see the mechanism, and a
        // one-tap block on a mis-touched row is a thread that silently vanishes;
        // an unconfirmed UNBLOCK is content silently coming back, which is the
        // half that is easy to forget.
        .confirmationDialog(
            blocked ? ContactBlockCopy.unblockPrompt : ContactBlockCopy.blockPrompt,
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(blocked ? ContactBlockCopy.confirmUnblock : ContactBlockCopy.confirmBlock) {
                apply()
            }
            Button(ContactBlockCopy.cancel, role: .cancel) {}
        }
    }

    /// ⚠️ THE DESIRED STATE IS COMPUTED FROM WHAT IS ON SCREEN, NOT FROM A TOGGLE.
    /// The route takes a state rather than an instruction to flip one (see
    /// ``ContactsRepository/setBlocked(workspaceId:subject:blocked:)``), so a stale
    /// read converges on the same answer instead of undoing somebody else's block.
    private func apply() {
        let target = !blocked
        Task {
            let ok = await store.setBlocked(workspaceId: workspaceId, subject: subject, blocked: target)
            guard ok, target else { return }
            onBlocked?()
        }
    }
}

/// The store's last write failure, shown beside whatever the screen was showing.
///
/// ⛔ BESIDE, NOT INSTEAD OF. A failed block does not invalidate the contact or the
/// thread on screen, and blanking it would lose what the operator was reading in
/// order to report that a moderation action did not land.
///
/// ⚠️ A SEPARATE VIEW FROM THE SCREENS' OWN FAILURE PANELS because the store is
/// shared: the same sentence can be produced by a block performed from the thread and
/// has to be dismissible from wherever it is read.
struct BlockFailureNotice: View {
    let store: BlockedContactsStore

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let failure = store.failure {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { store.clearFailure() }
                    .buttonStyle(.districtGhost)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
