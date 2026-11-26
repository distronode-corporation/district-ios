@testable import DistrictAI
import DistrictData
import DistrictNetwork
import XCTest

/// The four provisioning forms: what each sends, and when each may be sent at all, against
/// blank, padded and malformed input.
final class MarketplaceDraftTests: XCTestCase {
    // MARK: - Registration

    func testARegistrationCountryIsTrimmedAndUppercased() {
        var draft = RegistrationDraft()
        XCTAssertEqual(draft.trimmedCountry, "")
        draft.country = "  ee\n"
        XCTAssertEqual(draft.trimmedCountry, "EE")
        draft.friendlyName = "  \t "
        XCTAssertEqual(draft.trimmedName, "")
        draft.friendlyName = " Contoso OÜ "
        XCTAssertEqual(draft.trimmedName, "Contoso OÜ")
        XCTAssertEqual(draft.numberType, "local", "the default type")
    }

    /// A blank attribute is not sent, so it cannot overwrite the carrier's own value with "".
    func testBlankRegistrationAttributesAreDropped() {
        var draft = RegistrationDraft()
        draft.attributeText = ["business_name": " Contoso ", "website": "   ", "vat": ""]
        XCTAssertEqual(draft.attributes, ["business_name": .string("Contoso")])
        XCTAssertEqual(RegistrationDraft().attributes, [:])
    }

    // MARK: - SIP trunk

    func testSipAddressesSplitOnLinesAndDropBlanks() {
        var draft = SipTrunkDraft()
        XCTAssertEqual(draft.addresses, [])
        draft.ipAddresses = " 203.0.113.10 \n\n\t\n198.51.100.0/24\r\n  "
        XCTAssertEqual(draft.addresses, ["203.0.113.10", "198.51.100.0/24"])
    }

    func testASipTrunkNeedsANameADomainAndAnAddress() {
        var draft = SipTrunkDraft()
        XCTAssertFalse(draft.isSubmittable)
        draft.name = "Desk"
        draft.domain = "desk.sip.twilio.com"
        draft.ipAddresses = " \n "
        XCTAssertFalse(draft.isSubmittable, "no address once blanks are dropped")
        draft.ipAddresses = "203.0.113.10"
        XCTAssertTrue(draft.isSubmittable)
        draft.name = "   "
        XCTAssertFalse(draft.isSubmittable, "a blank name")
        draft.name = "Desk"
        draft.domain = "\n"
        XCTAssertFalse(draft.isSubmittable, "a blank domain")
    }

    // MARK: - A2P

    func testAnA2PFilingNeedsItsFourRequiredFields() {
        var draft = A2PDraft()
        XCTAssertFalse(draft.isSubmittable)
        draft.businessName = "Clinic"
        draft.campaignDescription = "Reminders"
        draft.sampleOne = "One"
        draft.sampleTwo = "  "
        XCTAssertFalse(draft.isSubmittable, "a blank second sample")
        draft.sampleTwo = "Two"
        XCTAssertTrue(draft.isSubmittable)
        XCTAssertEqual(draft.campaignType, "CUSTOMER_CARE", "the default campaign type")
    }

    /// Optional fields left blank are absent from the request, and the business name is trimmed.
    func testAnA2PRequestSendsOnlyWhatWasGiven() {
        var draft = A2PDraft()
        draft.businessName = "  Clinic  "
        draft.ein = "   "
        draft.website = " https://clinic.contract.test "
        draft.campaignDescription = "Reminders"
        draft.sampleOne = "One"
        draft.sampleTwo = "Two"
        let request = draft.request
        XCTAssertEqual(request.businessName, "Clinic")
        XCTAssertNil(request.ein)
        XCTAssertEqual(request.website, "https://clinic.contract.test")
        XCTAssertNil(request.vertical)
        XCTAssertEqual(request.campaignType, "CUSTOMER_CARE")
    }

    // MARK: - Toll-free

    func testATollFreeVerificationNeedsAnOptInImage() {
        var draft = TollFreeDraft()
        XCTAssertFalse(draft.isSubmittable)
        draft.phoneNumber = "+18005550188"
        draft.businessName = "Clinic"
        XCTAssertFalse(draft.isSubmittable, "no opt-in image")
        draft.optInImageUrl = "  \n"
        XCTAssertEqual(draft.optInImageUrls, [])
        XCTAssertFalse(draft.isSubmittable)
        draft.optInImageUrl = " https://clinic.contract.test/opt-in.png "
        XCTAssertEqual(draft.optInImageUrls, ["https://clinic.contract.test/opt-in.png"])
        XCTAssertTrue(draft.isSubmittable)
        draft.businessName = " "
        XCTAssertFalse(draft.isSubmittable, "a blank business name")
    }

    func testATollFreeRequestTrimsAndOmitsBlanks() {
        var draft = TollFreeDraft()
        draft.phoneNumber = " +18005550188 "
        draft.businessName = " Clinic "
        draft.messageContent = "   "
        draft.optInFlow = " Website form "
        draft.optInImageUrl = "https://clinic.contract.test/opt-in.png"
        let request = draft.request
        XCTAssertEqual(request.phoneNumber, "+18005550188")
        XCTAssertEqual(request.businessName, "Clinic")
        XCTAssertNil(request.messageContent)
        XCTAssertNil(request.website)
        XCTAssertEqual(request.optInFlow, "Website form")
        XCTAssertEqual(request.useCase, "Customer Support", "the default use case")
        XCTAssertEqual(request.optInImageUrls, ["https://clinic.contract.test/opt-in.png"])
    }

    func testAnOptionalFormValueIsNilWhenBlank() {
        XCTAssertNil(NumberFormValue.optional(""))
        XCTAssertNil(NumberFormValue.optional(" \n\t "))
        XCTAssertEqual(NumberFormValue.optional(" x "), "x")
    }

    // MARK: - Write state

    func testAWriteStateSaysWhetherItMayBePressedAgain() {
        let failure = FailureText(message: "No", action: .retry)
        XCTAssertTrue(NumberWriteState.idle.isArmed)
        XCTAssertTrue(NumberWriteState.done("Done").isArmed)
        XCTAssertFalse(NumberWriteState.running.isArmed)
        XCTAssertTrue(NumberWriteState.failed(failure, .allowed).isArmed)
        XCTAssertFalse(NumberWriteState.failed(failure, .refused).isArmed)

        XCTAssertFalse(NumberWriteState.running.refusedRepeat, "in flight is not refused")
        XCTAssertTrue(NumberWriteState.failed(failure, .refused).refusedRepeat)
        XCTAssertFalse(NumberWriteState.failed(failure, .allowed).refusedRepeat)

        XCTAssertNil(NumberWriteState.running.notice)
        XCTAssertEqual(NumberWriteState.done("Done").notice, "Done")
        XCTAssertFalse(NumberWriteState.done("Done").isFailure, "a done notice is never red")
        XCTAssertEqual(NumberWriteState.failed(failure, .allowed).notice, "No")
        XCTAssertTrue(NumberWriteState.failed(failure, .allowed).isFailure)
        XCTAssertTrue(NumberWriteState.running.isRunning)
        XCTAssertFalse(NumberWriteState.idle.isRunning)
    }
}
