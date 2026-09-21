import SwiftUI

// The confirmations, the shared notice strip, and nothing else.
//
// ⛔ EVERY IRREVERSIBLE OR BILLABLE WRITE ON THESE SURFACES IS COMMITTED FROM HERE AND
// NOWHERE ELSE. A release takes a live line out of service; a submit files a regulated
// application in the customer's name; A2P and toll-free verification each pay a carrier fee
// and enter a review a repeat cannot undo; a lookup costs money per tap. ⚠️ Reapplying a
// number's routing is deliberately NOT confirmed: it is idempotent and converges, and a
// confirmation on it would train the operator to dismiss the ones that matter.
//
// ⛔ AND A FAILED IRREVERSIBLE WRITE DOES NOT HAND ITS BUTTON BACK. A dialog cleared only
// on success, gated only on "not running", would re-enable a destructive button live,
// directly under its own failure sentence. So the submit is gated on
// ``NumberWriteState/isArmed``, which answers false
// while a write is in flight AND after a failure that cannot prove the write did not land;
// the model re-checks the same thing, because a disabled button is not something anything
// else can make a claim about.
//
// ⚠️ EACH CONFIRMATION NAMES WHAT HAPPENS IN THE UNITS THE OPERATOR THINKS IN rather than
// asking "are you sure". "This cannot be undone" tells nobody what they are weighing; "your
// callers reach nothing" does.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

/// Draws whichever confirmation is open, and nothing when none is.
///
/// ⛔ AN EXHAUSTIVE SWITCH WITH NO `default`, so a case added to ``NumberConfirmation`` and
/// forgotten here fails the build rather than producing a screen where the model believes a
/// confirmation is open and the operator sees nothing.
struct NumberConfirmationHost: View {
    let model: NumberProvisioningModel

    var body: some View {
        ScrollView {
            open
        }
        // ⛔ A WRITE IN FLIGHT CANNOT BE SWIPED AWAY. It has nowhere else to report its
        // outcome, and on this surface the outcome may be an irreversible release.
        .interactiveDismissDisabled(model.numberWrite.isRunning || model.carrierWrite.isRunning)
    }

    @ViewBuilder
    private var open: some View {
        if let confirmation = model.confirmation {
            content(confirmation)
        }
    }

    @ViewBuilder
    private func content(_ confirmation: NumberConfirmation) -> some View {
        switch confirmation {
        case let .release(phoneNumber):
            NumberConfirmationShell(
                title: MarketplaceCopy.releaseConfirmTitle,
                description: MarketplaceCopy.releaseConfirmBody(phoneNumber),
                submitLabel: MarketplaceCopy.releaseConfirmAction,
                variant: .destructive,
                state: model.numberWrite,
                onSubmit: { Task { await model.release(phoneNumber: phoneNumber) } },
                onClose: { model.dismissConfirmation() }
            )
        case let .submitRegistration(bundleId, country):
            NumberConfirmationShell(
                title: MarketplaceCopy.submitConfirmTitle,
                description: MarketplaceCopy.submitConfirmBody(country: country),
                submitLabel: MarketplaceCopy.submitConfirmAction,
                variant: .destructive,
                state: model.registrationWrite,
                onSubmit: { Task { await model.submitRegistration(bundleId: bundleId) } },
                onClose: { model.dismissConfirmation() }
            )
        case .a2p:
            NumberConfirmationShell(
                title: MarketplaceCopy.a2pConfirmTitle,
                description: MarketplaceCopy.a2pConfirmBody,
                submitLabel: MarketplaceCopy.a2pConfirmAction,
                variant: .primary,
                state: model.carrierWrite,
                onSubmit: { Task { await model.submitA2P() } },
                onClose: { model.dismissConfirmation() }
            )
        case .tfv:
            NumberConfirmationShell(
                title: MarketplaceCopy.tfvConfirmTitle,
                description: MarketplaceCopy.tfvConfirmBody,
                submitLabel: MarketplaceCopy.tfvConfirmAction,
                variant: .primary,
                state: model.carrierWrite,
                onSubmit: { Task { await model.submitTollFree() } },
                onClose: { model.dismissConfirmation() }
            )
        case .lookup:
            NumberConfirmationShell(
                title: MarketplaceCopy.lookupConfirmTitle,
                description: MarketplaceCopy.lookupConfirmBody,
                submitLabel: MarketplaceCopy.lookupConfirmAction,
                variant: .primary,
                state: model.lookupWrite,
                onSubmit: { Task { await model.lookup() } },
                onClose: { model.dismissConfirmation() }
            )
        }
    }
}

/// The shared shell: a title, a sentence, and the two ways out.
///
/// ⛔ THE SUBMIT IS GATED ON THE WRITE STATE, NOT ONLY ON "NOT RUNNING", so a destructive
/// button cannot come back live under its own failure sentence.
/// ``NumberWriteState/isArmed`` answers false while a write is in flight AND after a failure
/// that cannot prove the write did not land.
///
/// ⚠️ CLOSE STAYS ENABLED IN THAT STATE AND IS RELABELLED. It is the only way out, and
/// "Cancel" would claim the operator is calling off something that may already have happened.
struct NumberConfirmationShell: View {
    let title: String
    let description: String
    let submitLabel: String
    let variant: DistrictButtonVariant
    let state: NumberWriteState
    let onSubmit: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(title)
                .font(DistrictType.titleLarge)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(description)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            NumberWriteNotice(state: state)
            controls
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: DistrictSpacing.row) {
            Button(state.isRunning ? MarketplaceCopy.working : submitLabel, action: onSubmit)
                .buttonStyle(DistrictButtonStyle(variant: variant))
                .disabled(!state.isArmed)
            Button(state.refusedRepeat ? MarketplaceCopy.close : MarketplaceCopy.cancel, action: onClose)
                .buttonStyle(.districtGhost)
                .disabled(state.isRunning)
        }
        .padding(.top, DistrictSpacing.tight)
    }
}

/// One write's notice, and the second sentence that explains a control that is gone.
///
/// ⛔ TWO SENTENCES WHEN THE WRITE CANNOT BE REPEATED, AND THE SERVER'S IS STILL FIRST. The
/// mapped failure says what went wrong; ``MarketplaceCopy/writeUnrepeatable`` says what it
/// means for an irreversible write and why the button is gone. Dropping the first re-authors
/// a remedy into a shrug; dropping the second leaves a dead button with no explanation, which
/// reads as a broken screen.
///
/// ⚠️ A `done` IS NOT ALWAYS A CONGRATULATION AND MUST NOT BE RED. A release whose monthly
/// charge could not be ended lands there, carrying the warning inside the success.
struct NumberWriteNotice: View {
    let state: NumberWriteState

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let notice = state.notice {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(notice)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(state.isFailure ? colors.destructive : colors.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if state.refusedRepeat {
                    Text(MarketplaceCopy.writeUnrepeatable)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
