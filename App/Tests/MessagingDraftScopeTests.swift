@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The carrier account draft: which boxes each carrier asks for, when the secrets are
/// required, how typed numbers are parsed, and the exact document a save sends.
final class MessagingDraftScopeTests: XCTestCase {
    // MARK: - The catalogue

    func testEachCarrierAsksForItsOwnBoxes() {
        XCTAssertEqual(MessagingCatalog.credentialFields(for: "twilio").map(\.key), ["accountSid", "authToken"])
        XCTAssertEqual(
            MessagingCatalog.credentialFields(for: "sinch").map(\.key),
            ["projectId", "keyId", "keySecret", "applicationKey", "applicationSecret"]
        )
        XCTAssertEqual(MessagingCatalog.credentialFields(for: "telnyx").map(\.key), ["apiKey"])
        // ⚠️ Sinch's project id is an identifier, not a secret, so it is not masked.
        XCTAssertEqual(MessagingCatalog.credentialFields(for: "sinch").filter { !$0.isSecret }.map(\.id), ["projectId"])
    }

    /// ⚠️ A CARRIER ADDED SERVER-SIDE DRAWS NO BOXES and cannot be probed, rather than crashing.
    func testAnUnknownCarrierHasNoBoxesAndCannotBeTested() {
        XCTAssertTrue(MessagingCatalog.credentialFields(for: "vonage").isEmpty)
        XCTAssertTrue(MessagingCatalog.credentialFields(for: "").isEmpty)
        var draft = MessagingDraft()
        draft.provider = "vonage"
        XCTAssertFalse(draft.canTest)
        // Nothing is secret, so nothing is missing: the route's own allowlist refuses it.
        XCTAssertTrue(draft.canSave)
    }

    func testTheEnglishCarrierLabelIsCapitalised() {
        XCTAssertEqual(MessagingCatalog.providerLabel("twilio"), "Twilio")
        XCTAssertEqual(MessagingCatalog.providerLabel("telnyx"), "Telnyx")
    }

    // MARK: - Secrets

    /// A new account needs every secret; whitespace is not a value.
    func testANewAccountNeedsEverySecret() {
        var draft = MessagingDraft()
        XCTAssertTrue(draft.isCreate)
        XCTAssertTrue(draft.secretsRequired)
        XCTAssertFalse(draft.canSave)
        draft.secrets = ["accountSid": "AC1", "authToken": "   "]
        XCTAssertFalse(draft.credentialsComplete)
        XCTAssertFalse(draft.canTest)
        draft.secrets["authToken"] = " token "
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.canTest)
        XCTAssertEqual(draft.value(for: "authToken"), "token")
        XCTAssertEqual(draft.value(for: "missing"), "")
    }

    /// An existing account keeps its stored secrets until its carrier changes.
    func testAnEditNeedsSecretsOnlyWhenTheCarrierChanges() {
        var draft = MessagingDraft(accountId: "acct-1", provider: "twilio", originalProvider: "twilio")
        XCTAssertFalse(draft.isCreate)
        XCTAssertFalse(draft.secretsRequired)
        XCTAssertTrue(draft.canSave)
        draft.provider = "telnyx"
        XCTAssertTrue(draft.secretsRequired)
        XCTAssertFalse(draft.canSave)
    }

    /// Sinch's plaintext project id is still needed for a probe, though not for a save.
    func testAProbeNeedsThePlaintextBoxesToo() {
        var draft = MessagingDraft()
        draft.provider = "sinch"
        draft.secrets = ["keyId": "k", "keySecret": "s", "applicationKey": "a", "applicationSecret": "b"]
        XCTAssertTrue(draft.canSave)
        XCTAssertFalse(draft.canTest)
        draft.secrets["projectId"] = "p"
        XCTAssertTrue(draft.canTest)
    }

    // MARK: - Numbers

    func testNumbersSplitOnNewlinesAndCommasAndDropBlanks() {
        var draft = MessagingDraft()
        draft.phoneNumbers = " +14165550111 ,\n\n+14165550112,, \n  +14165550113\n"
        XCTAssertEqual(draft.parsedNumbers, ["+14165550111", "+14165550112", "+14165550113"])
        draft.phoneNumbers = " , \n "
        XCTAssertEqual(draft.parsedNumbers, [])
    }

    // MARK: - The document

    /// ⛔ UNEDITED NUMBERS AND UNTYPED SECRETS ARE ABSENT, so a save never blanks stored ones.
    func testAnUneditedDraftSendsNeitherNumbersNorSecrets() {
        let draft = MessagingDraft(
            accountId: "acct-1",
            provider: "twilio",
            phoneNumbers: "+1416",
            originalProvider: "twilio"
        )
        XCTAssertEqual(draft.providerConfig(includingProvider: false), .object([:]))
    }

    /// The probe names the carrier; typed secrets go trimmed; edited numbers go parsed.
    func testTheProbeDocumentCarriesTheCarrierAndTypedValues() {
        var draft = MessagingDraft()
        draft.secrets = ["accountSid": " AC1 ", "authToken": ""]
        draft.phoneNumbers = "+1, +2"
        draft.numbersEdited = true
        XCTAssertEqual(
            draft.providerConfig(includingProvider: true),
            .object([
                "provider": .string("twilio"),
                "phoneNumbers": .array([.string("+1"), .string("+2")]),
                "accountSid": .string("AC1"),
            ])
        )
    }

    /// Cleared numbers that were edited go as an empty list, which is a real instruction.
    func testEditedNumbersClearedToNothingGoAsAnEmptyList() {
        var draft = MessagingDraft()
        draft.provider = "telnyx"
        draft.numbersEdited = true
        XCTAssertEqual(draft.providerConfig(includingProvider: false), .object(["phoneNumbers": .array([])]))
    }

    // MARK: - Editing a stored account

    func testEditingAStoredAccountCarriesItsFields() throws {
        let response = try JSONDecoder().decode(
            MessagingResponse.self,
            from: FixtureTransport.fixtureData("district-messaging")
        )
        let account = try XCTUnwrap(response.accounts.first)
        let draft = MessagingDraft.editing(account)
        XCTAssertEqual(draft.accountId, "acct-twilio")
        XCTAssertEqual(draft.provider, "twilio")
        XCTAssertEqual(draft.originalProvider, "twilio")
        XCTAssertEqual(draft.label, "Twilio (main)")
        XCTAssertEqual(draft.phoneNumbers, "+14165550111\n+14165550112")
        XCTAssertFalse(draft.numbersEdited)
        XCTAssertTrue(draft.secrets.isEmpty)
    }

    /// ⚠️ A ROW MISSING ITS CARRIER, SOURCE AND LABEL opens on the defaults rather than blanks.
    func testAStoredAccountMissingFieldsOpensOnTheDefaults() throws {
        let body = Data(#"{"success":true,"accounts":[{"id":"acct-bare","phoneNumbers":[]}],"channelDefaults":{}}"#
            .utf8)
        let response = try JSONDecoder().decode(MessagingResponse.self, from: body)
        let draft = try MessagingDraft.editing(XCTUnwrap(response.accounts.first))
        XCTAssertEqual(draft.provider, "twilio")
        XCTAssertEqual(draft.credentialSource, "byok")
        XCTAssertEqual(draft.label, "")
        XCTAssertEqual(draft.phoneNumbers, "")
    }
}
