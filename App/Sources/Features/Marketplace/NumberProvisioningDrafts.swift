import DistrictNetwork
import Foundation

// The four forms the provisioning surfaces collect, and nothing else.
//
// ⛔ EVERY ONE OF THESE IS A DRAFT FOR A WRITE THAT SPENDS SOMETHING, so each carries the
// smallest set of fields its route actually reads. A field the route ignores would be a
// control that changes nothing, which is worse than its absence because the operator would
// believe they had set something — the reason ``NumberSearchForm`` has no page size.
//
// ⚠️ THEY LIVE ON THE MODEL RATHER THAN IN A VIEW so they survive a tab switch, which is the
// one thing on this screen that replaces a form's content wholesale.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

/// Starting a regulatory filing, and the end-user attributes a submit sends.
///
/// ⛔ THE ATTRIBUTE KEYS COME FROM THE REGULATION, NEVER FROM A FORM DRAWN HERE. The field
/// list is per country AND per number type AND per end-user type and changes without notice,
/// so the requirements read is what populates ``attributes`` and this type only holds the
/// answers. A form built from anything else asks a customer for papers they do not have and
/// omits the ones they do.
///
/// ⚠️ `numberType` USES TWILIO'S VOCABULARY, which spells the toll-free case with a SPACE
/// (`toll free`) — a different vocabulary from the marketplace search's `tollFree`. Two
/// routes, one parameter name, two spellings.
struct RegistrationDraft {
    var country = ""

    /// ⚠️ Twilio's own vocabulary. See the ⚠️ on this type.
    var numberType = "local"

    var friendlyName = ""

    /// The end-user answers, keyed by the regulation's own field names.
    ///
    /// ⛔ FLAT TEXT ONLY. The route refuses a nested object, an explicit null or a mixed
    /// array with a **400** rather than coercing it, because a silently dropped attribute is
    /// a bundle that evaluates as noncompliant for a reason the customer cannot see in their
    /// own form. Text is the only shape a form can produce anyway.
    var attributeText: [String: String] = [:]

    var trimmedCountry: String {
        country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var trimmedName: String {
        friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The attributes as the submit wants them.
    ///
    /// ⚠️ A BLANK ANSWER IS DROPPED RATHER THAN SENT EMPTY. The route counts an attribute as
    /// supplied only if it carries something, and a blank string would satisfy neither the
    /// route's check nor the regulator's — so sending it would produce a 422 naming a field
    /// the operator believes they filled in.
    var attributes: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in attributeText {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out[key] = .string(trimmed)
        }
        return out
    }
}

/// Provisioning a SIP trunk.
///
/// ⛔ THE CREATE IS A ONE-WAY DOOR: it opens a $25/month charge and there is no DELETE on
/// that route, so nothing in this app can take the trunk down. The form's caption has to say
/// so before the button is used rather than after.
struct SipTrunkDraft {
    var name = ""

    /// ⚠️ THE LABEL ONLY. The route appends `.sip.twilio.com`, so a fully-qualified value
    /// here produces a doubled suffix.
    var domain = ""

    /// ⚠️ ONE PER LINE AS TYPED. Parsed by ``addresses``; at least one is required and an
    /// empty list is a **400** rather than an open trunk — which is the correct direction,
    /// since a SIP domain with no access list is an endpoint anybody can register against.
    var ipAddresses = ""

    var addresses: [String] {
        ipAddresses
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isSubmittable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !addresses.isEmpty
    }
}

/// An A2P 10DLC submission.
///
/// ⛔ THE ROUTE HAS NO STATUS READ, so whatever this produces is the only report the flow
/// will ever give. ⛔ And it creates a billable brand and a billable campaign that no retry
/// undoes, so a duplicate leaves orphans a human clears by hand.
struct A2PDraft {
    var businessName = ""

    /// ⚠️ Persisted for the manual TrustHub step and NOT forwarded to the brand registration,
    /// which does not accept it.
    var ein = ""

    var website = ""

    var vertical = ""

    /// ⛔ IT DECIDES THE BRAND TYPE AND THE PRICE. `LOW_VOLUME` registers a sole-proprietor
    /// brand at $1.50/month; anything else registers a standard brand at $10.00. ⚠️ An
    /// unrecognised value falls through to `MIXED` server-side rather than being refused, so
    /// the vocabulary is a closed list of chips here rather than free text.
    var campaignType = "CUSTOMER_CARE"

    var campaignDescription = ""

    var sampleOne = ""

    var sampleTwo = ""

    /// ⚠️ THE ROUTE'S OWN REQUIRED SET, mirrored so the button is not offered for a body that
    /// is guaranteed a 400. The server still decides; this only saves a round trip.
    var isSubmittable: Bool {
        [businessName, campaignDescription, sampleOne, sampleTwo]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// This form as the request type.
    ///
    /// ⛔ THE CROSSING HAPPENS HERE AND NOWHERE ELSE, which is the point of having a form
    /// type at all. A view edits eight boxes; ``A2PRegistrationDraft`` is what the descriptor
    /// takes, and building it at each call site is how a blank optional reaches the route as an
    /// empty string it then STORES into the TrustHub profile.
    var request: A2PRegistrationDraft {
        A2PRegistrationDraft(
            businessName: businessName.trimmingCharacters(in: .whitespacesAndNewlines),
            campaignType: campaignType,
            campaignDescription: campaignDescription,
            sampleMessage1: sampleOne,
            sampleMessage2: sampleTwo,
            ein: NumberFormValue.optional(ein),
            website: NumberFormValue.optional(website),
            vertical: NumberFormValue.optional(vertical)
        )
    }
}

/// A toll-free verification submission.
///
/// ⛔ THE ROUTE HAS NO STATUS READ, and the submission flips a LIVE number's routing state to
/// `pending_verification`. So this is not an inert filing: a loop churns the state of a
/// number that is answering calls.
struct TollFreeDraft {
    /// ⚠️ Must be a number this workspace owns AND that lives on the connected carrier
    /// account. Those are two different refusals (404 and 400) that read alike.
    var phoneNumber = ""

    var businessName = ""

    var website = ""

    /// ⚠️ MAPPED, NOT VALIDATED. The four recognised values map to the carrier's categories
    /// and anything else falls through to `OTHER`, so this is a closed list of chips rather
    /// than free text.
    var useCase = "Customer Support"

    var messageContent = ""

    var optInFlow = ""

    /// ⛔ REQUIRED, AND IT MUST BE THE TENANT'S OWN EVIDENCE. A reviewer opens it by hand and
    /// rejects the filing days later with error 30509 if it does not load, so an empty one is
    /// refused up front — and a Distronode-owned asset could never demonstrate somebody
    /// else's declared opt-in.
    var optInImageUrl = ""

    var optInImageUrls: [String] {
        let trimmed = optInImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    var isSubmittable: Bool {
        [phoneNumber, businessName].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && !optInImageUrls.isEmpty
    }

    /// This form as the request type. See the ⛔ on ``A2PDraft/request``.
    ///
    /// ⚠️ THE OPT-IN LIST IS PASSED THROUGH EVEN WHEN EMPTY, deliberately, so the refusal an
    /// operator reads is the route's own actionable sentence about opt-in evidence rather than a
    /// generic missing-field message this layer invented. ``isSubmittable`` keeps the button off
    /// in that state; the pass-through is what matters for anything that bypasses it.
    var request: TollFreeVerificationDraft {
        TollFreeVerificationDraft(
            phoneNumber: phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            businessName: businessName.trimmingCharacters(in: .whitespacesAndNewlines),
            useCase: useCase,
            optInImageUrls: optInImageUrls,
            website: NumberFormValue.optional(website),
            messageContent: NumberFormValue.optional(messageContent),
            optInFlow: NumberFormValue.optional(optInFlow)
        )
    }
}

/// One rule about optional form fields, in one place.
///
/// ⛔ A BLANK BOX IS AN ABSENT FIELD, NOT AN EMPTY ONE, AND THE DIFFERENCE IS LOAD-BEARING ON
/// THESE ROUTES. `workspace/a2p` STORES whatever it is given into the TrustHub profile, so a
/// blank string there is a recorded empty value somebody later has to notice and clear; and
/// ``JSONValue/object(_:)`` only drops a pair whose value is nil, so the trim has to happen
/// before the descriptor is built.
///
/// ⚠️ ITS OWN TYPE RATHER THAN A STATIC ON ONE DRAFT, because three of the four forms need it
/// and reaching into `A2PDraft.optional` from the toll-free path read as a mistake even
/// though it worked.
enum NumberFormValue {
    static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
