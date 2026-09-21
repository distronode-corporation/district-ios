import DistrictModel
import SwiftUI

// The carrier-account surface: which carriers are connected, the workspace's SIP trunks, and
// the one-time-passcode service.
//
// ⛔ THREE THINGS ON THIS SCREEN ARE ONE-WAY OR ASYMMETRICAL AND EACH SAYS SO BEFORE IT IS
// USED, not after:
//   - creating a SIP trunk opens a $25/month charge and there is NO DELETE on that route, so
//     nothing in this app can take it down;
//   - enabling one-time passcodes mints a carrier-billable sender, and DISABLING it removes
//     nothing at the carrier — it clears only our pointer, which is why an
//     enable/disable/enable loop mints orphans somebody reaps by hand;
//   - a managed carrier's account figures are Distronode's plus every other managed tenant's,
//     so the row reports connectivity only and the caption says why rather than looking like
//     a failed read.
//
// ⚠️ THE THREE READS HERE ALL ADMIT `viewer` while every write excludes it, so a viewer sees
// the panels and no controls. ⛔ A viewer must not see a dead control.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

struct CarrierSection: View {
    let model: NumberProvisioningModel

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            NumberWriteNotice(state: model.carrierWrite)
            carrier
            verify
            sip
            if !model.canProvision {
                Text(MarketplaceCopy.viewerCannotProvision)
                    .font(DistrictType.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Which carriers are connected

    @ViewBuilder
    private var carrier: some View {
        switch model.carrier {
        case .loading:
            SkeletonBlock(height: 72)
        case let .ready(entries, connected, refused):
            MarketplacePanel {
                DistrictEyebrow(text: MarketplaceCopy.carrierEyebrow)
                ForEach(connected + refused, id: \.self) { name in
                    if let entry = entries[name] {
                        CarrierRow(name: name, entry: entry)
                    }
                }
            }
        case .notConnected:
            // ⛔ AN ACCOUNT STATE, NOT A FAULT, AND NO RETRY. The route answers this as an
            // ordinary 200, so a red failure would tell an operator their app is broken while
            // their account is merely new.
            EmptyStateView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: MarketplaceCopy.carrierNoneTitle,
                message: MarketplaceCopy.carrierNoneBody
            )
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.carrierEyebrow,
                failure: failure,
                onRetry: { Task { await model.loadCarrier() } }
            )
        }
    }

    // MARK: - One-time passcodes

    @ViewBuilder
    private var verify: some View {
        switch model.verify {
        case .loading:
            SkeletonBlock(height: 56)
        case let .ready(enabled, _):
            SettingsCard(eyebrow: MarketplaceCopy.verifyEyebrow) {
                SettingsReadOnlyRow(
                    label: MarketplaceCopy.verifyEyebrow,
                    value: enabled ? MarketplaceCopy.verifyOn : MarketplaceCopy.verifyOff
                )
                // ⛔ THE CAPTION DIFFERS BY DIRECTION BECAUSE THE OPERATIONS ARE NOT MIRROR
                // IMAGES. Enabling creates a billable sender; disabling deletes nothing at the
                // carrier and only stops us using it.
                Text(enabled ? MarketplaceCopy.verifyDisableCaption : MarketplaceCopy.verifyEnableCaption)
                    .font(DistrictType.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if model.canProvision {
                    Button(
                        enabled
                            ? MarketplaceCopy.verifyDisableAction
                            : MarketplaceCopy.verifyEnableAction
                    ) {
                        Task { await model.setVerify(enabled: !enabled) }
                    }
                    .buttonStyle(DistrictButtonStyle(variant: enabled ? .secondary : .primary))
                    .disabled(!model.carrierWrite.isArmed)
                }
            }
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.verifyEyebrow,
                failure: failure,
                onRetry: { Task { await model.loadVerify() } }
            )
        }
    }

    // MARK: - SIP trunks

    @ViewBuilder
    private var sip: some View {
        switch model.sip {
        case .loading:
            SkeletonBlock(height: 72)
        case let .ready(trunks):
            SipCard(model: model, trunks: trunks)
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.sipEyebrow,
                failure: failure,
                onRetry: { Task { await model.loadSip() } }
            )
        }
    }
}

/// One carrier's account, as `provider/status` reports it.
///
/// ⛔ A MANAGED ROW REPORTS CONNECTIVITY ONLY AND THE CAPTION SAYS WHY. `getAccountInfo`
/// describes the AUTHENTICATING account, which for a managed provider is the platform's own —
/// so a name, a balance or a number count here would be Distronode's figures plus every other
/// managed tenant's. Without the caption the missing fields read as a failed read.
///
/// ⛔ AND A REFUSED ROW IS CONTENT RATHER THAN A FAILURE. It arrives inside a 200, and its
/// remedy ("reconnect the account") is a different sentence from "connect a carrier".
struct CarrierRow: View {
    let name: String
    let entry: ProviderStatusEntry

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack(spacing: DistrictSpacing.tight) {
                Text(name)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                DistrictBadge(
                    text: entry.connected
                        ? MarketplaceCopy.carrierConnected
                        : MarketplaceCopy.carrierRefusedBadge,
                    tone: entry.connected ? .success : .danger
                )
                Spacer(minLength: 0)
            }
            detail
        }
        .padding(.top, DistrictSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        if !entry.connected {
            // ⛔ THE REMEDY, WHICH IS A DIFFERENT SENTENCE FROM "connect a carrier". These
            // credentials exist and were rejected, so reconnecting the account is the fix.
            Text(MarketplaceCopy.carrierRefused)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        } else if entry.managed == true {
            Text(MarketplaceCopy.carrierManaged)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let accountName = entry.accountName {
                Text(accountName)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
            }
            if let balance = entry.balance {
                Text(MarketplaceCopy.carrierBalance(balance, currency: entry.currency))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            if let count = entry.numberCount {
                Text(MarketplaceCopy.carrierNumberCount(count))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }
}

/// The SIP trunks, and the one-way create.
///
/// ⛔ THE ONE-WAY CAPTION IS ABOVE THE FORM RATHER THAN BESIDE THE BUTTON. There is no DELETE
/// on this route, so the $25/month charge a create opens cannot be ended from the app, and
/// telling the operator after the tap is telling them too late.
struct SipCard: View {
    let model: NumberProvisioningModel
    let trunks: [SipTrunk]

    var body: some View {
        SettingsCard(eyebrow: MarketplaceCopy.sipEyebrow) {
            if trunks.isEmpty {
                Text(MarketplaceCopy.sipEmptyBody)
                    .font(DistrictType.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(trunks, id: \.id) { trunk in
                    SettingsReadOnlyRow(
                        label: trunk.domain,
                        value: MarketplaceCopy.sipTrunkMeta(
                            status: trunk.status,
                            addresses: trunk.ipAccessControlList.count
                        )
                    )
                    // ⚠️ A ROW WITH NO CARRIER SIDS IS A BILLING ITEM WITH NOTHING BEHIND IT,
                    // which the list can genuinely report for a row written before real
                    // provisioning existed. Worth surfacing rather than hiding.
                    if trunk.domainSid == nil, trunk.ipAclSid == nil {
                        Text(MarketplaceCopy.sipUnprovisioned)
                            .font(DistrictType.caption)
                    }
                }
            }
            if model.canProvision {
                form
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        Text(MarketplaceCopy.sipOneWay)
            .font(DistrictType.caption)
            .fixedSize(horizontal: false, vertical: true)
        SettingsField(
            label: MarketplaceCopy.sipNameLabel,
            text: Binding(get: { model.sipDraft.name }, set: { model.sipDraft.name = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.sipDomainLabel,
            text: Binding(get: { model.sipDraft.domain }, set: { model.sipDraft.domain = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        Text(MarketplaceCopy.sipDomainCaption)
            .font(DistrictType.caption)
        SettingsField(
            label: MarketplaceCopy.sipIpLabel,
            text: Binding(get: { model.sipDraft.ipAddresses }, set: { model.sipDraft.ipAddresses = $0 }),
            enabled: !model.carrierWrite.isRunning,
            multiline: true
        )
        Button(MarketplaceCopy.sipCreateAction) {
            Task { await model.createSipTrunk() }
        }
        .buttonStyle(.districtPrimary)
        .disabled(!model.sipDraft.isSubmittable || !model.carrierWrite.isArmed)
    }
}
