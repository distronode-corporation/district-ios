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
    // MARK: - The provisioning tabs

    static let tabRegistrations = "Registrations"

    static let tabCarrier = "Carrier"

    // MARK: - The purchase boundary

    /// ⛔ PROSE, NAMING NO DESTINATION, WITH NOTHING TO TAP. See the ⛔ at the top of this
    /// file: Guideline 3.1.1 covers steering as well as the purchase itself, so the
    /// sentence states the boundary and the second half says what IS here, which is the
    /// part that stops it reading as a half-built screen.
    static let purchaseElsewhere = "New numbers cannot be purchased in this app. "
        + "Everything else about a number, including its paperwork and releasing it, is here."

    // MARK: - Carrier connectivity

    static let carrierEyebrow = "Carrier accounts"

    static let carrierNoneTitle = "No carrier connected"

    static let carrierNoneBody = "This workspace has no carrier credentials, so numbers cannot "
        + "be searched, configured or registered yet."

    /// ⛔ CONNECTIVITY ONLY FOR A MANAGED CARRIER, AND THE CAPTION SAYS SO. The account
    /// name, balance and number count of a managed provider are Distronode's figures plus
    /// every other managed tenant's, so the route sends none of them and this row must not
    /// look like it is missing something.
    static let carrierManaged = "Held by Distronode. Account details are not this workspace's to see."

    static let carrierRefused = "These credentials were refused. The account cannot be reconnected in this app."

    static func carrierBalance(_ balance: String, currency: String?) -> String {
        guard let currency, !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Balance \(balance)"
        }
        return "Balance \(balance) \(currency)"
    }

    static func carrierNumberCount(_ count: Int) -> String {
        count == 1 ? "1 number on this account" : "\(count) numbers on this account"
    }

    // MARK: - Registrations

    static let registrationsEyebrow = "Regulatory registrations"

    /// ⚠️ "Filing" RATHER THAN "REQUEST", because that is the word the regulator and the
    /// carrier both use and the word a customer will hear back from us.
    static let registrationsEmptyTitle = "Nothing filed yet"

    static let registrationsEmptyBody = "Some countries require a registration before a number "
        + "there can be bought. Start one for the country you want."

    static let registrationsFailed = "Could not load this workspace's registrations."

    /// ⛔ A DRAFT HAS REACHED NO CARRIER AND THE WORD MUST NOT SUGGEST OTHERWISE. Calling it
    /// "submitted" is the word a customer would then use back at us about something that
    /// has not been filed.
    static func registrationStatus(_ status: String) -> String {
        switch status {
        case "draft": "Draft, not yet filed"
        case "pending-review": "Filed, waiting for review"
        case "in-review": "Under review"
        case "twilio-approved": "Approved"
        case "twilio-rejected": "Refused"
        default: status
        }
    }

    /// ⚠️ A STATUS MAY BE STALE AND THE RESPONSE CANNOT SAY SO: the list refreshes
    /// in-review filings on read and DEGRADES to the stored value on a carrier hiccup, with
    /// nothing marking it. So the screen says "as of this read" rather than "now".
    static let registrationStatusCaption = "Statuses are refreshed when this list loads. "
        + "A review can take a day or more."

    static func registrationTitle(country: String, numberType: String) -> String {
        "\(country) · \(numberType)"
    }

    static let registrationReasonsEyebrow = "What the carrier objected to"

    static let registrationDocumentsEyebrow = "Documents"

    /// ⚠️ "Remove" RATHER THAN "Delete". It takes a document off a DRAFT filing that has
    /// reached no carrier, so nothing is being destroyed at the regulator — and the stronger
    /// word beside the release button one tab over would flatten a real difference.
    static let documentRemoveAction = "Remove"

    /// ⚠️ THE TWO KINDS OF REQUIREMENT ARE SATISFIED BY DIFFERENT ACTIONS, so they are
    /// labelled rather than left to the reader: one is answered by typing, the other by
    /// uploading.
    static let requirementKindField = "Detail"

    static let requirementKindDocument = "Document"

    /// ⚠️ "Connected" RATHER THAN REUSING ``verifyOn``. A carrier's credentials resolving and
    /// an OTP service existing are unrelated facts, and one string across both would drift the
    /// day either is reworded.
    static let carrierConnected = "Connected"

    /// ⚠️ SHORT, BECAUSE IT IS A BADGE. The remedy sentence is ``carrierRefused``, which the
    /// row shows separately.
    static let carrierRefusedBadge = "Credentials refused"

    static func registrationDocumentMeta(stored: Bool, submitted: Bool) -> String {
        if submitted {
            return "Filed with the carrier"
        }
        return stored ? "Stored, not yet filed" : "Recorded, no file yet"
    }

    static let registrationStartTitle = "Start a registration"

    static let registrationCountryLabel = "Country (two letters)"

    static let registrationNameLabel = "Name for your carrier console (optional)"

    static let registrationStartAction = "Start registration"

    /// ⛔ THE REGULATOR DECIDES THE FIELDS, NOT US. A form drawn from anything else asks a
    /// customer for papers they do not have and omits the ones they do.
    static let requirementsEyebrow = "What this country asks for"

    static let requirementsNoneTitle = "No registration required"

    static let requirementsNoneBody = "This country publishes no regulation for this number type, "
        + "so there is nothing to file."

    static let requirementsNotPurchasable = "Numbers in this country are not purchasable through "
        + "Distronode today, even with a registration."

    static let requirementsCheckAction = "Check requirements"

    static func requirementFieldList(_ fields: [String]) -> String {
        fields.isEmpty ? "No fields" : fields.joined(separator: ", ")
    }

    // MARK: - Submitting a registration

    /// ⛔ NAMES WHAT HAPPENS IN THE UNITS THE OPERATOR THINKS IN, not "are you sure". This
    /// files a regulated application in their own company's name and uploads their identity
    /// documents to the carrier.
    static let submitConfirmTitle = "File this registration?"

    static func submitConfirmBody(country: String) -> String {
        "This uploads your documents to the carrier and files a regulatory application for "
            + "\(country) in your business's name. Review can take a day or more, and the filing "
            + "cannot be edited while it is under review."
    }

    static let submitConfirmAction = "File it"

    static let submitFiled = "Filed. The carrier is reviewing it."

    /// ⛔ THE 422's DETAIL DOES NOT REACH THIS SCREEN THROUGH THE ERROR, so the sentence
    /// tells the operator where it did go: the route stores the carrier's objections on the
    /// filing, and re-reading the list is what shows them.
    static let submitRefusedReread = "The carrier refused it. Reload the list to see what it "
        + "objected to."

    // MARK: - A number's own actions

    static let numberActionsTitle = "This number"

    static let configureAction = "Reapply call routing"

    /// ⚠️ NOT "nothing will change". Restating the webhooks is what keeps an EU number
    /// answered in Europe, and skipping it is how one silently starts being answered in the
    /// United States.
    static let configureCaption = "Points this number's calls and messages back at this "
        + "workspace, and re-pins an EU number to its European bridge."

    static let configureDone = "Routing reapplied."

    static let releaseAction = "Release this number"

    static let releaseConfirmTitle = "Release this number?"

    /// ⛔ SAYS WHAT HAPPENS, NOT THAT IT IS IRREVERSIBLE. "This cannot be undone" tells
    /// nobody what they are weighing; "your callers reach nothing" does.
    static func releaseConfirmBody(_ phoneNumber: String) -> String {
        "\(phoneNumber) goes back to the carrier's pool and generally cannot be reclaimed. "
            + "Calls and messages to it stop immediately, so anyone dialling it reaches nothing. "
            + "Its monthly charge ends."
    }

    static let releaseConfirmAction = "Release it"

    static let releaseDone = "Released. Reload your numbers."

    /// ⛔ A 200 CARRYING WARNINGS IS STILL A RELEASE, AND ONE OF THE WARNINGS IS ABOUT
    /// MONEY. Swallowing the array would leave an operator believing they had stopped a
    /// charge they had not.
    static let releaseWarningEyebrow = "Released, but"

    /// ⛔ MANAGED NUMBERS ARE NOT THE TENANT'S TO RELEASE, and the caption says why rather
    /// than leaving a missing button to be read as a bug.
    static let managedNoRelease = "This line is held on Distronode's carrier account, so it is "
        + "yours to use and not to release or reconfigure."

    // MARK: - The billable lookup

    static let lookupEyebrow = "Number lookup"

    static let lookupNumberLabel = "Phone number, in full"

    static let lookupAction = "Look this number up"

    static let lookupConfirmTitle = "Run a paid lookup?"

    /// ⛔ SAYS OUT LOUD THAT IT COSTS MONEY, because a lookup looks free and is not: the
    /// carrier bills per request and line-type intelligence costs more than a basic one.
    static let lookupConfirmBody = "Your carrier charges for each lookup, including one that "
        + "comes back invalid. One tap runs exactly one lookup."

    static let lookupConfirmAction = "Run it"

    static func lookupResult(_ info: NumberLookupSummary) -> String {
        info.lines.joined(separator: "\n")
    }

    static let lookupInvalid = "The carrier could not recognise that number."

    // MARK: - SIP trunking

    static let sipEyebrow = "SIP trunks"

    static let sipEmptyTitle = "No SIP trunks"

    static let sipEmptyBody = "A SIP trunk lets your own PBX send and receive calls on this "
        + "workspace's numbers."

    /// ⛔ THERE IS NO ROUTE TO TAKE A TRUNK DOWN, so the create is a one-way door and the
    /// screen has to say so BEFORE it is used rather than after. ⛔ THE $25 STAYS AND THE
    /// DESTINATION GOES: the price is the disclosure that makes the door one the operator
    /// can weigh, and naming where to undo it is the 3.1.1 steering.
    static let sipOneWay = "Creating a trunk adds a $25 per month charge, and it cannot be "
        + "removed in this app."

    static let sipNameLabel = "Trunk name"

    static let sipDomainLabel = "Domain label"

    static let sipDomainCaption = "The carrier adds .sip.twilio.com, so enter the label only."

    static let sipIpLabel = "Allowed IPs or ranges, one per line"

    static let sipCreateAction = "Create trunk"

    static func sipTrunkMeta(status: String, addresses: Int) -> String {
        let ips = addresses == 1 ? "1 address" : "\(addresses) addresses"
        return "\(status) · \(ips)"
    }

    /// ⚠️ A ROW WITH NO CARRIER SIDS IS A BILLING ITEM WITH NOTHING BEHIND IT, which is
    /// worth surfacing rather than hiding.
    static let sipUnprovisioned = "No carrier resources are recorded for this trunk."

    // MARK: - The Verify (OTP) service

    static let verifyEyebrow = "One-time passcodes"

    static let verifyOn = "Enabled"

    static let verifyOff = "Not enabled"

    static let verifyEnableAction = "Enable one-time passcodes"

    static let verifyDisableAction = "Stop using one-time passcodes"

    /// ⛔ DISABLING REMOVES NOTHING AT THE CARRIER, and saying otherwise would be false.
    /// The route deliberately keeps the Verify service and clears only our pointer.
    static let verifyDisableCaption = "Turning this off stops Distronode using the service. "
        + "The carrier keeps it, and its history, on your account."

    static let verifyEnableCaption = "Creates a one-time passcode sender on your carrier account. "
        + "The carrier charges for the messages it sends."

    // MARK: - A2P and toll-free verification

    static let complianceEyebrow = "Messaging compliance"

    /// ⛔ NEITHER OF THESE HAS A STATUS READ, so the screen keeps what the submission
    /// answered and cannot refresh it. Saying so is the difference between a stale panel and
    /// a screen that looks broken.
    static let complianceNoStatus = "Neither registration can be checked from the app. "
        + "What you see here is what the carrier answered when it was submitted."

    static let a2pTitle = "A2P 10DLC registration"

    static let a2pCaption = "Required before this workspace can send text messages to US numbers "
        + "from a local number."

    static let a2pBusinessLabel = "Legal business name"

    static let a2pEinLabel = "EIN or company number (optional)"

    static let a2pWebsiteLabel = "Website (optional)"

    static let a2pVerticalLabel = "Industry (optional)"

    static let a2pDescriptionLabel = "What you will send"

    static let a2pSampleOneLabel = "Example message 1"

    static let a2pSampleTwoLabel = "Example message 2"

    static let a2pSubmitAction = "Submit registration"

    static let a2pConfirmTitle = "Submit this registration?"

    /// ⛔ NAMES THE FEES, because both are real and neither is refunded by a retry.
    static let a2pConfirmBody = "This registers a brand and a campaign on your carrier account. "
        + "The carrier charges a one-off brand fee and a monthly campaign fee, and a repeated "
        + "submission leaves duplicates somebody has to clear by hand."

    static let a2pConfirmAction = "Submit it"

    static func a2pSubmitted(status: String) -> String {
        "Submitted. The carrier reports \(status)."
    }

    static let tfvTitle = "Toll-free verification"

    static let tfvCaption = "Required before a toll-free number can send text messages."

    static let tfvUseCaseLabel = "Use case"

    static let tfvOptInLabel = "Link to your opt-in form or screenshot"

    /// ⛔ THE EVIDENCE HAS TO BE THE TENANT'S OWN, and a link the reviewer cannot open is a
    /// rejection days later rather than an error now.
    static let tfvOptInCaption = "A reviewer opens this by hand. It must be publicly reachable "
        + "and show your own consent wording."

    static let tfvMessageLabel = "Example message (optional)"

    static let tfvSubmitAction = "Submit verification"

    static let tfvConfirmTitle = "Submit this verification?"

    static let tfvConfirmBody = "This files a verification with the carrier for a number that is "
        + "already answering calls, and puts it into a manual review that takes days. Repeated "
        + "submissions for one number can put your carrier account's standing in question."

    static let tfvConfirmAction = "Submit it"

    static func tfvSubmitted(status: String) -> String {
        "Submitted. The carrier reports \(status)."
    }

    // MARK: - Shared write chrome

    static let cancel = "Cancel"

    static let close = "Close"

    static let working = "Working…"

    /// ⛔ WHY A CONTROL IS GONE, AND IT IS NOT OPTIONAL COPY. A dead button under a failure
    /// sentence reads as a broken screen; this says the write may already have happened,
    /// which is the honest reason it cannot be offered again.
    static let writeUnrepeatable = "We could not confirm whether that went through, so it is not "
        + "offered again. Reload to see where things stand."

    /// ⚠️ A VIEWER SEES THE TWO VIEWER-LEGAL READS AND IS TOLD WHO CAN DO THE REST, rather
    /// than being shown a control that will refuse them.
    static let viewerCannotProvision = "Registrations, carrier setup and number changes need an "
        + "agency or client role. Ask someone on this workspace who has one."
}
