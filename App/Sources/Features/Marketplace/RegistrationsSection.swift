import DistrictModel
import SwiftUI

// The regulatory-registration surface: what this workspace has filed, what a country asks
// for, and how to start and file one.
//
// ⛔ NO PURCHASE CONTROL AND NO LINK TO ONE, exactly as the marketplace tabs have none. A
// registration exists to make a purchase POSSIBLE; the purchase itself is App Store Review
// Guideline 3.1.1 territory, and ``MarketplaceCopy/purchaseElsewhere`` says only that it
// cannot be done in this app. ⚠️ It names no destination: 3.1.1 forbids the signpost as
// well as the tap.
//
// ⛔ THE WORD "DRAFT" IS LOAD-BEARING. A created filing has reached no carrier at all, so a
// row must not read as "submitted" — that is the word a customer would then use back at us
// about something that has not been filed.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

struct RegistrationsSection: View {
    let model: NumberProvisioningModel

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            if model.canProvision {
                content
            } else {
                // ⛔ A VIEWER MUST NOT SEE A DEAD CONTROL. Both verbs on this route exclude
                // `viewer`, so they are told who can rather than being walked into a 403.
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: MarketplaceCopy.registrationsEyebrow,
                    message: MarketplaceCopy.viewerCannotProvision
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        NumberWriteNotice(state: model.registrationWrite)
        startCard
        requirementsCard
        list
    }

    // MARK: - Starting one

    private var startCard: some View {
        SettingsCard(eyebrow: MarketplaceCopy.registrationStartTitle) {
            SettingsField(
                label: MarketplaceCopy.registrationCountryLabel,
                text: Binding(
                    get: { model.registrationDraft.country },
                    set: { model.registrationDraft.country = $0 }
                ),
                enabled: !model.registrationWrite.isRunning
            )
            SettingsField(
                label: MarketplaceCopy.registrationNameLabel,
                text: Binding(
                    get: { model.registrationDraft.friendlyName },
                    set: { model.registrationDraft.friendlyName = $0 }
                ),
                enabled: !model.registrationWrite.isRunning
            )
            HStack(spacing: DistrictSpacing.tight) {
                // ⚠️ THE FREE READ FIRST. Checking what a country asks for costs nothing and
                // admits viewers, so it is offered before the write that opens a filing.
                Button(MarketplaceCopy.requirementsCheckAction) {
                    Task { await model.loadRequirements() }
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.registrationDraft.trimmedCountry.isEmpty)
                Button(MarketplaceCopy.registrationStartAction) {
                    Task { await model.createRegistration() }
                }
                .buttonStyle(.districtPrimary)
                .disabled(
                    model.registrationDraft.trimmedCountry.isEmpty || !model.registrationWrite.isArmed
                )
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - What the country asks for

    @ViewBuilder
    private var requirementsCard: some View {
        switch model.requirements {
        case .idle:
            // ⚠️ NOTHING HAS BEEN CHECKED YET, WHICH IS NOT "no requirements". An empty panel
            // here would answer a question the operator has not asked.
            EmptyView()
        case .loading:
            SkeletonBlock(height: 72)
        case let .ready(regulation, purchasable):
            RequirementsCard(regulation: regulation, purchasable: purchasable)
        case let .noRegulation(country, purchasable):
            // ⛔ NO REGULATION IS AN ANSWER, NOT A FAILURE, AND IT OFFERS NO RETRY. The
            // country publishes nothing for this number type, so there is nothing to file.
            MarketplacePanel {
                DistrictEyebrow(text: MarketplaceCopy.requirementsEyebrow)
                Text("\(country) · \(MarketplaceCopy.requirementsNoneTitle)")
                    .font(DistrictType.title)
                Text(MarketplaceCopy.requirementsNoneBody)
                    .font(DistrictType.bodySmall)
                if !purchasable {
                    // ⛔ AND IT IS STILL NOT PURCHASABLE, INDEPENDENTLY. Being able to
                    // describe a rule is not being able to satisfy it.
                    Text(MarketplaceCopy.requirementsNotPurchasable)
                        .font(DistrictType.bodySmall)
                }
            }
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.requirementsEyebrow,
                failure: failure,
                onRetry: { Task { await model.loadRequirements() } }
            )
        }
    }

    // MARK: - The filings

    @ViewBuilder
    private var list: some View {
        switch model.registrations {
        case .loading:
            SkeletonBlock(height: 72)
        case let .ready(rows, approved, platform):
            RegistrationsList(model: model, rows: rows, approved: approved, platform: platform)
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.registrationsFailed,
                failure: failure,
                onRetry: { Task { await model.loadRegistrations() } }
            )
        }
    }
}

/// What a country's regulator asks for.
///
/// ⛔ THE TWO KINDS OF REQUIREMENT ARE DRAWN SEPARATELY, because they are satisfied by
/// different actions: `end_user` entries are FIELDS a submit sends, `supporting_document`
/// entries are FILES uploaded one at a time. Drawing them as one list invites a customer to
/// look for a file upload for a field, or to type an answer where a document is wanted.
struct RequirementsCard: View {
    let regulation: CountryRequirements
    let purchasable: Bool

    var body: some View {
        MarketplacePanel {
            DistrictEyebrow(text: MarketplaceCopy.requirementsEyebrow)
            Text(regulation.friendlyName)
                .font(DistrictType.title)
            if !purchasable {
                // ⛔ NOT DERIVABLE FROM THE REQUIREMENTS, which is why the route sends it
                // separately and why this line can appear beside a complete rule set.
                Text(MarketplaceCopy.requirementsNotPurchasable)
                    .font(DistrictType.bodySmall)
            }
            ForEach(regulation.requirements, id: \.requirementName) { requirement in
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    Text(requirement.name)
                        .font(DistrictType.titleSmall)
                    // ⛔ LABELLED BY KIND, because the two are satisfied by different
                    // actions: a `Detail` is answered by typing and a `Document` by
                    // uploading. An unlabelled list invites looking for a file upload for
                    // a field, or typing an answer where a document is wanted.
                    DistrictBadge(
                        text: requirement.kind == "end_user"
                            ? MarketplaceCopy.requirementKindField
                            : MarketplaceCopy.requirementKindDocument,
                        tone: requirement.kind == "end_user" ? .info : .district
                    )
                    Text(MarketplaceCopy.requirementFieldList(requirement.fields))
                        .font(DistrictType.caption)
                }
                .padding(.top, DistrictSpacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The workspace's filings, and the two country gates above them.
struct RegistrationsList: View {
    let model: NumberProvisioningModel
    let rows: [NumberRegistration]
    let approved: [String]
    let platform: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            gates
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: MarketplaceCopy.registrationsEmptyTitle,
                    message: MarketplaceCopy.registrationsEmptyBody
                )
            } else {
                Text(MarketplaceCopy.registrationStatusCaption)
                    .font(DistrictType.caption)
                ForEach(rows, id: \.id) { row in
                    RegistrationRow(model: model, registration: row)
                }
            }
        }
    }

    /// ⛔ TWO LISTS, NOT ONE, AND BOTH ARE NEEDED. `approved` is where THIS workspace's own
    /// filings were approved; `platform` is where a number sells against Distronode's own
    /// registration with no filing by the tenant at all. Showing only the first hides every
    /// country the platform already covers; only the second offers one the tenant is not
    /// approved for.
    @ViewBuilder
    private var gates: some View {
        if !approved.isEmpty || !platform.isEmpty {
            MarketplacePanel {
                if !platform.isEmpty {
                    SettingsReadOnlyRow(label: "Ready to buy today", value: platform.joined(separator: ", "))
                }
                if !approved.isEmpty {
                    SettingsReadOnlyRow(label: "Your approvals", value: approved.joined(separator: ", "))
                }
            }
        }
    }
}
