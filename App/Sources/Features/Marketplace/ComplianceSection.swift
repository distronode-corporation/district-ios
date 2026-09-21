import SwiftUI

// Messaging compliance: A2P 10DLC and toll-free verification.
//
// ⛔ NEITHER OF THESE ROUTES HAS A STATUS READ ANYWHERE ON THE SERVER, and that changes what
// this screen can honestly claim. There is no GET, no polling endpoint and no webhook we
// receive, so what a panel shows is what the submission ANSWERED and nothing can refresh it.
// ``MarketplaceCopy/complianceNoStatus`` says so out loud, because a panel that looked
// refreshable would have an operator waiting for a change that can never arrive here.
//
// ⛔ AND BOTH SUBMISSIONS SPEND REAL MONEY NO RETRY UNDOES. A2P pays a one-off carrier brand
// fee and opens a monthly campaign fee; toll-free verification enters a slow MANUAL review and
// flips a live number's routing state to `pending_verification`. Both are therefore committed
// only from a confirmation that names the fee or the consequence, never from a tap.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

struct ComplianceSection: View {
    let model: NumberProvisioningModel

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(MarketplaceCopy.complianceNoStatus)
                .font(DistrictType.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canProvision {
                A2PCard(model: model)
                TollFreeCard(model: model)
            }
        }
    }
}

/// The A2P 10DLC form.
///
/// ⛔ THE CAMPAIGN TYPE DECIDES THE BRAND TYPE AND THE PRICE, which is why it is a closed set
/// of chips rather than a text field: `LOW_VOLUME` registers a sole-proprietor brand at
/// $1.50/month and anything else a standard brand at $10.00 — and an unrecognised value falls
/// through to `MIXED` server-side rather than being refused, so a typo would file a campaign
/// under the wrong use case silently.
///
/// ⚠️ THE THREE OPTIONAL BUSINESS FIELDS ARE NOT DECORATION. They are persisted for the manual
/// TrustHub step even when the submission is refused for missing bundles, which is exactly
/// when whoever builds that profile needs them — so a refused submission is not wasted typing.
struct A2PCard: View {
    let model: NumberProvisioningModel

    /// ⚠️ THE FOUR THE ROUTE'S USE-CASE MAP RECOGNISES. A fifth chip would file under `MIXED`.
    private let campaignTypes = ["CUSTOMER_CARE", "LOW_VOLUME", "MARKETING", "2FA"]

    var body: some View {
        SettingsCard(eyebrow: MarketplaceCopy.a2pTitle) {
            Text(MarketplaceCopy.a2pCaption)
                .font(DistrictType.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
            fields
            types
            Button(MarketplaceCopy.a2pSubmitAction) {
                model.requestConfirmation(.a2p)
            }
            .buttonStyle(.districtPrimary)
            .disabled(!model.a2pDraft.isSubmittable || !model.carrierWrite.isArmed)
        }
    }

    @ViewBuilder
    private var fields: some View {
        SettingsField(
            label: MarketplaceCopy.a2pBusinessLabel,
            text: Binding(get: { model.a2pDraft.businessName }, set: { model.a2pDraft.businessName = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.a2pEinLabel,
            text: Binding(get: { model.a2pDraft.ein }, set: { model.a2pDraft.ein = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.a2pWebsiteLabel,
            text: Binding(get: { model.a2pDraft.website }, set: { model.a2pDraft.website = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.a2pVerticalLabel,
            text: Binding(get: { model.a2pDraft.vertical }, set: { model.a2pDraft.vertical = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.a2pDescriptionLabel,
            text: Binding(
                get: { model.a2pDraft.campaignDescription },
                set: { model.a2pDraft.campaignDescription = $0 }
            ),
            enabled: !model.carrierWrite.isRunning,
            multiline: true
        )
        SettingsField(
            label: MarketplaceCopy.a2pSampleOneLabel,
            text: Binding(get: { model.a2pDraft.sampleOne }, set: { model.a2pDraft.sampleOne = $0 }),
            enabled: !model.carrierWrite.isRunning,
            multiline: true
        )
        SettingsField(
            label: MarketplaceCopy.a2pSampleTwoLabel,
            text: Binding(get: { model.a2pDraft.sampleTwo }, set: { model.a2pDraft.sampleTwo = $0 }),
            enabled: !model.carrierWrite.isRunning,
            multiline: true
        )
    }

    private var types: some View {
        HStack(spacing: DistrictSpacing.tight) {
            ForEach(campaignTypes, id: \.self) { value in
                Button(value) { model.a2pDraft.campaignType = value }
                    .buttonStyle(
                        DistrictButtonStyle(
                            variant: model.a2pDraft.campaignType == value ? .primary : .secondary,
                            size: .small
                        )
                    )
                    .disabled(model.carrierWrite.isRunning)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The toll-free verification form.
///
/// ⛔ THE OPT-IN LINK IS REQUIRED AND MUST BE THE TENANT'S OWN EVIDENCE. A reviewer opens it by
/// hand and rejects the filing days later with error 30509 if it does not load, so a submission
/// without one is refused up front — and a Distronode-owned asset could never demonstrate
/// somebody else's declared opt-in, which is why a platform-owned placeholder URL is rejected
/// by pathname.
///
/// ⚠️ THE USE CASE IS MAPPED, NOT VALIDATED: the four recognised values map to the carrier's
/// categories and anything else falls through to `OTHER`. So it is a closed set of chips rather
/// than a text field.
struct TollFreeCard: View {
    let model: NumberProvisioningModel

    private let useCases = ["Customer Support", "Marketing", "Notifications", "2FA / OTP"]

    var body: some View {
        SettingsCard(eyebrow: MarketplaceCopy.tfvTitle) {
            Text(MarketplaceCopy.tfvCaption)
                .font(DistrictType.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
            fields
            cases
            Button(MarketplaceCopy.tfvSubmitAction) {
                model.requestConfirmation(
                    .tfv(phoneNumber: model.tfvDraft.phoneNumber)
                )
            }
            .buttonStyle(.districtPrimary)
            .disabled(!model.tfvDraft.isSubmittable || !model.carrierWrite.isArmed)
        }
    }

    @ViewBuilder
    private var fields: some View {
        SettingsField(
            label: MarketplaceCopy.lookupNumberLabel,
            text: Binding(get: { model.tfvDraft.phoneNumber }, set: { model.tfvDraft.phoneNumber = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.a2pBusinessLabel,
            text: Binding(get: { model.tfvDraft.businessName }, set: { model.tfvDraft.businessName = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        SettingsField(
            label: MarketplaceCopy.tfvOptInLabel,
            text: Binding(get: { model.tfvDraft.optInImageUrl }, set: { model.tfvDraft.optInImageUrl = $0 }),
            enabled: !model.carrierWrite.isRunning
        )
        Text(MarketplaceCopy.tfvOptInCaption)
            .font(DistrictType.caption)
            .fixedSize(horizontal: false, vertical: true)
        SettingsField(
            label: MarketplaceCopy.tfvMessageLabel,
            text: Binding(
                get: { model.tfvDraft.messageContent },
                set: { model.tfvDraft.messageContent = $0 }
            ),
            enabled: !model.carrierWrite.isRunning,
            multiline: true
        )
    }

    private var cases: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(MarketplaceCopy.tfvUseCaseLabel)
                .font(DistrictType.labelSmall)
            HStack(spacing: DistrictSpacing.tight) {
                ForEach(useCases, id: \.self) { value in
                    Button(value) { model.tfvDraft.useCase = value }
                        .buttonStyle(
                            DistrictButtonStyle(
                                variant: model.tfvDraft.useCase == value ? .primary : .secondary,
                                size: .small
                            )
                        )
                        .disabled(model.carrierWrite.isRunning)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
