import DistrictData
import DistrictModel
import Foundation

// The provisioning surfaces' state: what each read is doing, what each write is doing, and
// the one derived type the lookup's answer is rendered from.
//
// ⛔ EVERY WRITE ON THESE SURFACES CARRIES ITS OWN STATE RATHER THAN SHARING ONE. Five of
// them are on screen at once (a filing's submit, a document's removal, a number's release,
// a Verify toggle, a lookup) and they fail for unrelated reasons; one shared `mutation`
// would disarm four controls because the fifth failed, and would show the wrong sentence
// under whichever one the operator was looking at.
//
// ⛔ AND A FAILED IRREVERSIBLE WRITE MUST NOT SILENTLY RE-ARM. A control gated only on "not
// running" hands a destructive button straight back, live, under its own failure sentence.
// The rule is enforced here through ``NumberWriteState/isArmed``, which reads its answer off
// ``NumberWriteResubmit`` rather than off "not currently running".
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

/// What one write is doing, and whether its control may be pressed again.
///
/// ⛔ THE `.failed` CASE CARRIES ITS OWN RESUBMIT VERDICT, WHICH IS THE WHOLE DESIGN. A
/// failure that PROVES the write did not land (a 4xx: the role guard, the ownership check,
/// the rate limiter, a malformed body) re-arms the control; a 5xx, a transport failure and a
/// decode failure do not, because none of them proves anything and the last one actively
/// proves the write DID land (it is only ever produced from a 2xx). See
/// ``NumberWriteResubmit``, which states the rule on the tested tier.
enum NumberWriteState {
    case idle
    case running

    /// A notice to show. ⚠️ Not necessarily a congratulation: a release that could not end
    /// its monthly charge lands here.
    case done(String)

    case failed(FailureText, NumberWriteResubmit)
}

extension NumberWriteState {
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    /// ⛔ WHETHER THE CONTROL MAY BE PRESSED AT ALL. `.running` answers false for the
    /// ordinary reason (one tap is one write); a `.failed` answers what its own
    /// ``NumberWriteResubmit`` says, which is the guard that stops a lost response becoming
    /// a second release, a second regulatory filing or a second billed lookup.
    var isArmed: Bool {
        switch self {
        case .idle, .done:
            true
        case .running:
            false
        case let .failed(_, resubmit):
            resubmit.isAllowed
        }
    }

    /// The one state where the control is gone and is not coming back.
    ///
    /// ⚠️ NOT THE NEGATION OF ``isArmed``: a write in flight is also unarmed and is the
    /// opposite situation. This is what puts ``MarketplaceCopy/writeUnrepeatable`` under the
    /// failure.
    var refusedRepeat: Bool {
        switch self {
        case .idle, .running, .done:
            false
        case let .failed(_, resubmit):
            !resubmit.isAllowed
        }
    }

    var notice: String? {
        switch self {
        case .idle, .running:
            nil
        case let .done(message):
            message
        case let .failed(failure, _):
            failure.message
        }
    }

    /// ⚠️ Drawn in the destructive colour only for a real failure. A release that succeeded
    /// with warnings is a `done` and must not be red.
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

/// What the carrier-connectivity read is doing.
///
/// ⛔ `notConnected` IS AN ACCOUNT STATE RATHER THAN A FAULT AND OFFERS NO RETRY, exactly as
/// ``MarketplaceSearchState/notConfigured(_:)`` does for the search's 400. The route answers
/// this as a perfectly ordinary 200 (`{connected:false, provider:null}`), so a red failure
/// here would tell an operator their app is broken while their account is merely new.
enum CarrierStatusState {
    case loading

    /// - Parameters:
    ///   - connected: which carriers answered.
    ///   - refused: which carriers rejected their own credentials, which is CONTENT on a 200
    ///     rather than a failure, and a different sentence from "not connected".
    case ready(entries: [String: ProviderStatusEntry], connected: [String], refused: [String])

    /// ⛔ NOTHING RESOLVED AT ALL. See the ⛔ on this type.
    case notConnected

    case failed(FailureText)
}

/// What the regulatory-filings read is doing.
enum RegistrationsState {
    case loading

    /// - Parameters:
    ///   - approvedCountries: where THIS workspace's own filings were approved.
    ///   - platformCountries: where a number sells against Distronode's own registration with
    ///     no filing by the tenant at all. ⛔ The two are not the same gate and a screen
    ///     needs both: only the first hides every country the platform already covers, only
    ///     the second offers one the tenant is not approved for.
    case ready(registrations: [NumberRegistration], approvedCountries: [String], platformCountries: [String])

    case failed(FailureText)
}

/// What the SIP-trunk read is doing.
enum SipTrunksState {
    case loading
    case ready([SipTrunk])
    case failed(FailureText)
}

/// What the Verify (OTP) configuration read is doing.
enum VerifyServiceState {
    case loading

    /// - Parameter sid: present only when the service is on. ⚠️ Absent and explicitly null
    ///   both arrive as nil, from the disable reply and the read respectively.
    case ready(enabled: Bool, sid: String?)

    case failed(FailureText)
}

/// What a country's published requirements read is doing.
///
/// ⛔ `noRegulation` IS NOT A FAILED LOOKUP. It means the country publishes nothing for that
/// number type, i.e. no registration is required, which is a real and common answer. A
/// failed lookup is `failed`. Collapsing them tells a customer to file paperwork that does
/// not exist, or that none is needed when nobody could ask.
enum RequirementsState {
    case idle
    case loading

    /// - Parameter purchasable: ⛔ THE HONEST ANSWER TO "can I buy one today", and it is NOT
    ///   derivable from the requirements. A country can publish perfectly readable rules and
    ///   still not be sellable here.
    case ready(CountryRequirements, purchasable: Bool)

    /// ⛔ No registration is required. See the ⛔ on this type.
    case noRegulation(country: String, purchasable: Bool)

    case failed(FailureText)
}

/// The lookup's answer, as lines a screen can draw.
///
/// ⛔ A FREE TYPE RATHER THAN A PROPERTY ON ``NumberLookupInfo``, because the three detail
/// fields are explicit nulls on the wire and "not reported" is product copy —
/// `DistrictModel` owns none. ⚠️ And `valid: false` still cost a carrier call, so the invalid
/// case is a real answer to show rather than an empty state.
struct NumberLookupSummary {
    let lines: [String]

    init(_ info: NumberLookupInfo) {
        guard info.valid else {
            lines = [MarketplaceCopy.lookupInvalid]
            return
        }
        var out = [info.phoneNumber]
        if let country = Self.nonBlank(info.country) {
            out.append(country)
        }
        if let type = Self.nonBlank(info.type) {
            out.append(type)
        }
        if let carrier = Self.nonBlank(info.carrier) {
            out.append(carrier)
        }
        lines = out
    }

    /// ⚠️ A BLANK COUNTS AS ABSENT. The route writes `|| null` for each of these, but a
    /// carrier that answered an empty string would otherwise draw a blank line that reads as
    /// a rendering fault.
    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The confirmations that must be collected before an irreversible or billable write.
///
/// ⛔ FOUR ENTRIES, AND EVERY ONE OF THEM EXISTS FOR A DIFFERENT REASON. `release` takes a
/// live line out of service and cannot be undone; `submitRegistration` files a regulated
/// application in the customer's name; `a2p` and `tfv` each pay a carrier fee and enter a
/// review a repeat cannot undo; `lookup` costs money per tap. ⚠️ `configure` is deliberately
/// NOT here: it is idempotent, it converges, and a confirmation on it would train the
/// operator to dismiss the ones that matter.
enum NumberConfirmation: Equatable {
    /// - Parameter phoneNumber: shown in full, because a partially-masked number is exactly
    ///   what an operator cannot check a decision against.
    case release(phoneNumber: String)

    case submitRegistration(bundleId: String, country: String)

    case a2p

    case tfv(phoneNumber: String)

    /// ⛔ BILLABLE PER TAP, WHICH IS WHY A LOOKUP IS CONFIRMED AT ALL. It is otherwise the
    /// most innocuous-looking control on the screen.
    case lookup(phoneNumber: String)
}
