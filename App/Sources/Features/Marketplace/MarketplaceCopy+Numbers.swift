import DistrictL10n
import DistrictModel
import Foundation

// Every sentence the phone-number PROVISIONING surfaces say: the regulatory filings, the
// carrier accounts, and the three things that can be done to a number the workspace holds.
//
// ⛔ NO URL, NO LINK AND NO CALL TO ACTION POINTING AT A PURCHASE, AND THE ABSENCE IS THE
// POINT — the same rule `MarketplaceCopy` already keeps, for a rule that is one guideline
// over. Buying a number charges a setup fee AND opens a recurring monthly charge for a
// service consumed inside the app, which is App Store Review Guideline 3.1.1: an in-app
// purchase or nothing. ⛔ 3.1.1 covers STEERING too, and prose counts: naming the
// destination IS the steering, not only offering a tap. Every sentence here says what
// cannot be done in this app and names nowhere, and `StoreCopyTests` fails the build if
// one names a place. Do not add a `webURL`, a Safari sheet or a "Buy" caption pointing
// outward either; see the ⛔ at the top of `MarketplaceView.swift`.
//
// ⚠️ ITS OWN FILE RATHER THAN MORE OF `MarketplaceCopy.swift`, the same call `DialerCopy`
// and `WorkflowsCopy` make: `swiftlint --strict` promotes `file_length` at 500 lines to an
// error, and that file already carries the marketplace's two tabs' worth of states.
//
// ⛔ THREE SENTENCES HERE ARE LOAD-BEARING RATHER THAN DECORATIVE, and each one exists
// because the alternative misleads:
//   - ``releaseConfirmBody`` says the callers reach NOTHING, because "this cannot be
//     undone" tells nobody what they are weighing.
//   - ``lookupConfirmBody`` says it COSTS MONEY, because a lookup looks free and is not.
//   - ``writeUnrepeatable`` explains why a control is gone, because a dead button with no
//     explanation reads as a broken screen.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

extension MarketplaceCopy {
    // MARK: - Carrier connectivity

    /// ⚠️ FRENCH GOES THROUGH THE CORE'S MONEY TABLE, as ``priceLabel(monthlyPrice:currency:)``
    /// does: « Solde : 12,50 $ US », never « 12.50 USD », and « 12,50 » with no currency.
    /// The carrier sends the balance as a decimal STRING, so one that does not parse as a
    /// number is shown as sent rather than guessed at. English keeps the raw value it has
    /// always shown.
    static func carrierBalance(_ balance: String, currency: String?) -> String {
        let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if L10nRuntime.locale != .en, let cents = balanceCents(balance) {
            return carrierBalanceAmount(L10nFormat.moneyOrBare(minorUnits: cents, currency: code.isEmpty ? nil : code))
        }
        guard let currency, !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return carrierBalanceAmount(balance)
        }
        return carrierBalanceWithCurrency(balance, currency)
    }

    /// The balance in cents, or nil when the string is not a finite number small enough
    /// to count in `Int` (a balance that size is a bad value, shown as sent).
    private static func balanceCents(_ balance: String) -> Int? {
        guard let amount = Double(balance.trimmingCharacters(in: .whitespaces)),
              amount.isFinite, abs(amount) < 1e13 else { return nil }
        return Int((amount * 100).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: - Registrations

    /// ⛔ A DRAFT HAS REACHED NO CARRIER AND THE WORD MUST NOT SUGGEST OTHERWISE. Calling it
    /// "submitted" is the word a customer would then use back at us about something that
    /// has not been filed.
    static func registrationStatus(_ status: String) -> String {
        switch status {
        case "draft": registrationStatusDraft
        case "pending-review": registrationStatusPendingReview
        case "in-review": registrationStatusInReview
        case "twilio-approved": registrationStatusApproved
        case "twilio-rejected": registrationStatusRefused
        default: status
        }
    }

    static func registrationDocumentMeta(stored: Bool, submitted: Bool) -> String {
        if submitted {
            return registrationDocumentFiled
        }
        return stored ? registrationDocumentStored : registrationDocumentRecorded
    }

    static func requirementFieldList(_ fields: [String]) -> String {
        fields.isEmpty ? requirementNoFields : fields.joined(separator: ", ")
    }

    // MARK: - The billable lookup

    static func lookupResult(_ info: NumberLookupSummary) -> String {
        info.lines.joined(separator: "\n")
    }

    // MARK: - SIP trunking

    static func sipTrunkMeta(status: String, addresses: Int) -> String {
        sipTrunkMetaLine(status, sipAddressCount(addresses))
    }
}

/// A held number's carrier and status, as the owned list and its actions sheet print them:
/// as sent in English (`twilio · active`), the vocabulary's labels in French.
enum NumberWireText {
    static func meta(_ number: ListedNumber) -> String {
        MarketplaceCopy.numberMeta(
            provider: AppWire.label(.numberProvider, number.provider),
            status: AppWire.label(.numberStatus, number.status)
        )
    }
}
