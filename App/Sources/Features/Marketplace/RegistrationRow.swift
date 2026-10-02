import DistrictModel
import SwiftUI

// One regulatory filing: its status, what the carrier objected to, its documents, and the
// one control that files it.
//
// ⛔ THE SUBMIT IS OFFERED ONLY ON A DRAFT, because every other status means the filing is
// already with the carrier and the route answers **409** rather than 403 — the request is
// well-formed and will be valid again if the review comes back rejected. Drawing a live
// button that can only 409 reads as a broken screen.
//
// ⛔ AND DOCUMENTS MAY ONLY BE REMOVED FROM A DRAFT, for the same reason plus a sharper one:
// once a filing has been submitted the carrier and the regulator hold a copy of exactly the
// documents that were sent, so swapping one out on our side would leave our record
// disagreeing with the filing under review and the customer believing they had corrected
// something they had not.
//
// ⚠️ THERE IS NO UPLOAD CONTROL HERE. The repository can upload
// (``NumbersRepository/uploadRegistrationDocument(workspaceId:bundleId:requirementName:fileName:mimeType:bytes:)``,
// covered by the package tests) but choosing a file needs a document picker, and a picker is a
// platform surface with its own permissions, its own cancellation and its own 10 MiB and
// sniffed-mime refusals to render. That is a screen rather than a button, and it is
// deliberately left out of this row; the removal is here because it needs no picker at all.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

struct RegistrationRow: View {
    let model: NumberProvisioningModel
    let registration: NumberRegistration

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ `draft` IS THE ONLY EDITABLE STATUS. See the ⛔ at the top of this file.
    private var isDraft: Bool {
        registration.status == "draft"
    }

    var body: some View {
        DistrictCard(spacing: DistrictSpacing.hairline) {
            Text(
                MarketplaceCopy.registrationTitle(
                    country: registration.isoCountry,
                    numberType: registration.numberType
                )
            )
            .font(DistrictType.title)
            .foregroundStyle(colors.foreground)
            friendlyName
            DistrictBadge(text: MarketplaceCopy.registrationStatus(registration.status), tone: tone)
            reasons
            documents
            submit
        }
    }

    @ViewBuilder
    private var friendlyName: some View {
        // ⚠️ TRIMMED FIRST, INTO A LOCAL, RATHER THAN TESTED IN A TWO-CLAUSE `if`. The
        // natural spelling wraps onto a second line, SwiftFormat then moves the opening
        // brace onto its own line, and SwiftLint's `opening_brace` rejects exactly that,
        // so no formatting of the two-clause form satisfies both tools. The fix is always
        // to make the condition single-clause, never to suppress either rule.
        // ⚠️ And the trimmed value is what gets RENDERED: testing the trimmed string and
        // displaying the untrimmed one would draw a padded name with visible leading space.
        let trimmed = registration.friendlyName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ THE TONE FOLLOWS THE VERDICT AND NOT THE ACTIVITY. A draft is neutral rather than
    /// warning: nothing is wrong with it, it simply has not been filed.
    private var tone: Tone {
        switch registration.status {
        case "twilio-approved": .success
        case "twilio-rejected": .danger
        case "pending-review", "in-review": .info
        default: .neutral
        }
    }

    /// ⛔ THE ONLY PLACE A REFUSAL'S DETAIL SURVIVES. The submit's 422 carries `failures` and
    /// `reasons` that ``ApiError`` drops; the route stores the carrier's structured objections
    /// on the row, so this list is what a customer reads to know what to fix.
    @ViewBuilder
    private var reasons: some View {
        if !registration.rejectionReasons.isEmpty {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: MarketplaceCopy.registrationReasonsEyebrow)
                ForEach(registration.rejectionReasons, id: \.self) { reason in
                    Text(reason)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, DistrictSpacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ⛔ `stored` AND `submitted` ARE NOT THE SAME FACT AND BOTH ARE SHOWN. `stored` means we
    /// hold the bytes; `submitted` means the CARRIER holds a copy, which is only ever true
    /// after a filing. A replacement upload clears the carrier's pointer, so a document can be
    /// stored and unsubmitted again after being both — and a screen that showed one flag would
    /// let a customer believe a filing cites the file they just corrected.
    @ViewBuilder
    private var documents: some View {
        if !registration.documents.isEmpty {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: MarketplaceCopy.registrationDocumentsEyebrow)
                ForEach(registration.documents, id: \.id) { document in
                    documentRow(document)
                }
            }
            .padding(.top, DistrictSpacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func documentRow(_ document: RegistrationDocument) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
            VStack(alignment: .leading, spacing: 0) {
                Text(document.requirementName)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                Text(
                    MarketplaceCopy.registrationDocumentMeta(
                        stored: document.stored,
                        submitted: document.submitted
                    )
                )
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            }
            Spacer(minLength: DistrictSpacing.tight)
            // ⛔ REMOVAL ONLY ON A DRAFT. See the ⛔ at the top of this file.
            if isDraft {
                Button(MarketplaceCopy.documentRemoveAction) {
                    Task {
                        await model.removeDocument(bundleId: registration.id, documentId: document.id)
                    }
                }
                .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
                .disabled(!model.registrationWrite.isArmed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ THE FILING CONTROL, AND IT GOES THROUGH A CONFIRMATION RATHER THAN COMMITTING. It
    /// uploads the customer's identity documents to the carrier and files a regulated
    /// application in their business's name, which is not something a thumb should be able to
    /// do in one tap.
    @ViewBuilder
    private var submit: some View {
        if isDraft {
            Button(MarketplaceCopy.submitConfirmAction) {
                model.requestConfirmation(
                    .submitRegistration(bundleId: registration.id, country: registration.isoCountry)
                )
            }
            .buttonStyle(.districtPrimary)
            .disabled(!model.registrationWrite.isArmed)
            .padding(.top, DistrictSpacing.tight)
        }
    }
}
