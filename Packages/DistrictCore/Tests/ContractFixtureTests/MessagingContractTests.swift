import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the workspace's outbound carrier accounts.
///
/// ⛔ THE STRICT GATE CANNOT SEE THE TWO FACTS THAT MATTER MOST ON THIS SURFACE,
/// and both are about what is NOT in a body. The read's two fixtures have
/// different key sets (a fresh workspace omits `defaultAccountId` and nulls
/// `managedAccount`), and the gate compares each fixture against the DTO rather
/// than against its sibling, so nothing in it would notice a DTO that required the
/// field and threw on every fresh workspace. And the account rows carry no
/// credential, which is a claim about absent keys that only an explicit assertion
/// on the raw bytes can make.
///
/// ⛔ THE OTHER ONE IS A STATUS RATHER THAN A SHAPE: `district-messaging-test-rejected.json`
/// is an HTTP **200**. Nothing in a committed body records that, so it is stated
/// here, because it is the single most misreadable thing about this family.
final class MessagingContractTests: XCTestCase {
    // MARK: - The account read

    /// ⛔ TWO ACCOUNTS THAT COVER BOTH BILLING MODELS AND BOTH NUMBER COUNTS. Row 0
    /// is `byok` with two numbers (the workspace's own carrier account, billed to
    /// them); row 1 is `managed` with one (billed through us). An operator reads
    /// `credentialSource` to know which, so a fixture with two identical rows would
    /// pin the field's presence and nothing about its meaning.
    func testTheAccountListCoversBothCredentialSources() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging.json",
            as: MessagingResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.accounts.map(\.id), ["acct-twilio", "acct-telnyx"])

        let byok = try XCTUnwrap(response.accounts.first)
        XCTAssertEqual(byok.provider, "twilio")
        XCTAssertEqual(byok.label, "Twilio (main)")
        XCTAssertEqual(byok.credentialSource, "byok")
        XCTAssertEqual(byok.phoneNumbers, ["+14165550111", "+14165550112"])

        let managed = try XCTUnwrap(response.accounts.last)
        XCTAssertEqual(managed.credentialSource, "managed")
        XCTAssertEqual(managed.phoneNumbers, ["+14165550113"])
    }

    /// ⛔ THE PLATFORM ACCOUNT IS ITS OWN FIELD AND HAS NO `id`, AND THE MISSING ID
    /// IS THE CONTRACT. `accounts` is the id space `resolveSendingContext` validates
    /// a `from` against, rejecting anything it cannot find as a spoofing attempt, so
    /// a synthetic managed entry would render a pickable sender whose every send
    /// fails and would 404 both default-setting actions. The server withholds the id
    /// to make that unexpressible.
    ///
    /// ⚠️ AND THE STORED DEFAULT NAMES THE SECOND ACCOUNT, not the first. It is
    /// RESOLVED server-side rather than being "whichever is at index 0", which is
    /// the assumption this fixture exists to break.
    func testThePlatformAccountIsSeparateAndTheDefaultIsResolvedNotFirst() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging.json",
            as: MessagingResponse.self
        )

        let managed = try XCTUnwrap(response.managedAccount)
        XCTAssertEqual(managed.provider, "twilio")
        XCTAssertEqual(managed.phoneNumbers, ["+14165550190"])

        XCTAssertEqual(response.defaultAccountId, "acct-telnyx", "resolved, not index 0")
        XCTAssertEqual(response.channelDefaults, ["sms": "acct-twilio"])
    }

    /// ⛔ NO CREDENTIAL IS ON THIS RESPONSE, ASSERTED ON THE RAW BYTES BECAUSE IT IS
    /// A CLAIM ABOUT ABSENT KEYS. The stored config holds an account SID, an auth
    /// token and an API key, and the route projects a five-key object around them.
    /// The server's own contract test asserts the same thing from the other side;
    /// this is the half that fails if a future DTO tempts someone into widening the
    /// route to feed it.
    func testAnAccountRowCarriesExactlyFiveKeysAndNoCredential() throws {
        let rows = try Self.array(in: "district-messaging.json", under: "accounts")

        for row in rows {
            XCTAssertEqual(
                Set(row.keys),
                ["id", "provider", "label", "credentialSource", "phoneNumbers"],
                "an account row grew or lost a key"
            )
        }
        // The platform summary is two keys and deliberately not one of the five.
        let managed = try Self.object(in: "district-messaging.json", under: "managedAccount")
        XCTAssertEqual(Set(managed.keys), ["provider", "phoneNumbers"])
        XCTAssertFalse(managed.keys.contains("id"), "⛔ an id here would make it a pickable sender")
    }

    /// ⛔ TWO DIFFERENT ABSENCES IN ONE BODY, AND ONLY ONE OF THEM IS A NULL. A
    /// workspace with no accounts nulls `managedAccount` (the platform holds no
    /// numbers for it) and DROPS `defaultAccountId` entirely, because
    /// `effectiveDefaultId` returns undefined for an empty list and `JSON.stringify`
    /// omits the key. So this body does not even have the same key set as the
    /// populated read, which is what a strict decoder has to survive: the null needs
    /// an exact allowlist path and the dropped key must NOT have one.
    ///
    /// ⚠️ `accounts: []` AND `managedAccount: null` ARE DIFFERENT FACTS. A workspace
    /// can own no carrier account and still have numbers we bought for it, or the
    /// reverse, so a screen that collapsed the two would tell some workspaces they
    /// cannot send when they can.
    func testAFreshWorkspaceNullsThePlatformAccountAndOmitsTheDefault() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-unmanaged.json",
            as: MessagingResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertTrue(response.accounts.isEmpty)
        XCTAssertNil(response.managedAccount, "the platform holds no numbers for this workspace")
        XCTAssertNil(response.defaultAccountId)
        XCTAssertTrue(response.channelDefaults.isEmpty)

        let raw = try Self.envelope(of: "district-messaging-unmanaged.json")
        XCTAssertTrue(raw.keys.contains("managedAccount"), "sent as null, hence the allowlist entry")
        XCTAssertFalse(
            raw.keys.contains("defaultAccountId"),
            "⛔ DROPPED rather than nulled, which is why it gets no allowlist entry"
        )
    }

    // MARK: - The five writes

    /// ⚠️ THE UPSERT ECHOES IDS AND NOTHING ELSE, so there is nothing here to patch
    /// an on-screen row with: no label, no provider, no numbers. A row rebuilt from
    /// the REQUEST would show what the operator typed rather than what was stored,
    /// and the two genuinely differ (the label is trimmed, a blank one is replaced,
    /// numbers are filtered).
    ///
    /// ⚠️ THE ECHOED DEFAULT IS NOT THIS ACCOUNT. `acct-twilio` was saved and
    /// `acct-telnyx` is still the default, which is the case that proves the second
    /// field is a fact about the workspace rather than about the row just written.
    func testTheUpsertEchoesBothIdsAndNothingElse() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-upsert.json",
            as: MessagingAccountSaveResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.accountId, "acct-twilio")
        XCTAssertEqual(response.defaultAccountId, "acct-telnyx", "not the row that was saved")

        let raw = try Self.envelope(of: "district-messaging-upsert.json")
        XCTAssertEqual(Set(raw.keys), ["success", "accountId", "defaultAccountId"])
    }

    /// ⛔ `setDefault` AND `delete` ARE BYTE-COMPATIBLE AND SHARE ONE TYPE, and the
    /// pairing is asserted here rather than assumed: both answer
    /// `{success, defaultAccountId}` and the fixtures differ in nothing but which
    /// account they name. ⚠️ The delete's value is the more interesting one, because
    /// `acct-telnyx` WAS the default, so removing it re-pointed the workspace at the
    /// only account left, and this response is the only place that is announced.
    func testSetDefaultAndDeleteAnswerTheSameShape() throws {
        let set = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-set-default.json",
            as: MessagingDefaultResponse.self
        )
        let deleted = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-delete.json",
            as: MessagingDefaultResponse.self
        )

        XCTAssertEqual(set.defaultAccountId, "acct-twilio")
        XCTAssertEqual(deleted.defaultAccountId, "acct-twilio", "the default MOVED, unasked")
        for name in ["district-messaging-set-default.json", "district-messaging-delete.json"] {
            let raw = try Self.envelope(of: name)
            XCTAssertEqual(Set(raw.keys), ["success", "defaultAccountId"], name)
        }
    }

    /// ⛔ THE WHOLE MAP COMES BACK AND THE FIXTURE HAS TO SHOW TWO KEYS OR IT PROVES
    /// NOTHING. The stored map already held `sms`; setting `voice` must not drop it.
    /// A fixture built from a workspace with no existing override would look
    /// identical whether the route merged or replaced, so `sms` surviving beside the
    /// newly set `voice` IS the assertion.
    func testTheChannelDefaultMergesRatherThanReplaces() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-channel-default.json",
            as: MessagingChannelDefaultResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(
            response.channelDefaults,
            ["sms": "acct-twilio", "voice": "acct-telnyx"],
            "⛔ the pre-existing sms override survived the voice write"
        )
    }

    /// ⛔ THE `meta` ACTION IS A BARE ACKNOWLEDGEMENT, AND THE CONSEQUENCE IS A
    /// PRODUCT DECISION RATHER THAN A SHAPE DETAIL: the creator cell number is not on
    /// the messaging GET either, so nothing in this client can read the stored value
    /// at all. A form has to ask for a new one and say so, instead of showing an
    /// empty field an operator reads as "not set".
    func testTheMetaWriteEchoesNothingAtAll() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-meta.json",
            as: SuccessResponse.self
        )
        XCTAssertTrue(response.success)

        let raw = try Self.envelope(of: "district-messaging-meta.json")
        XCTAssertEqual(Set(raw.keys), ["success"], "no echo, hence no pre-fill anywhere")
    }

    // MARK: - The credential probe

    /// ⚠️ THE PASS CARRIES WHATEVER THE PROVIDER VOLUNTEERED, and for Twilio that is
    /// the account's own name, which is the useful part: it tells an operator they
    /// wired up the account they meant to rather than merely a valid one.
    /// ``MessagingTestResponse/detail`` is what a screen shows, and it prefers
    /// `friendlyName` over `message` for that reason.
    func testAPassedProbeCarriesTheCarriersOwnAccountName() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-test.json",
            as: MessagingTestResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.details?.friendlyName, "Distronode Contract")
        XCTAssertEqual(response.details?.status, "active")
        XCTAssertNil(response.details?.message, "⚠️ the Sinch and Telnyx field, absent here")
        XCTAssertNil(response.details?.smsAuth, "⚠️ Sinch only, and no fixture carries it")
        XCTAssertEqual(response.detail, "Distronode Contract")
    }

    /// ⛔ THE ONE FIXTURE IN THE CORPUS WHERE `success: false` IS THE ANSWER RATHER
    /// THAN CONTRACT DRIFT, AND IT ARRIVES AS AN HTTP **200**. The route catches the
    /// carrier's rejection and reports it this way on purpose, so the operator is
    /// told "these keys do not authenticate" instead of "the server broke". It is
    /// gated against the SAME type as the pass, not against `ApiErrorEnvelope`,
    /// because modelling it as an error envelope would be modelling it as a failure.
    ///
    /// ⛔ ANY REPOSITORY THAT RAN THE ENVELOPE GUARD OVER THIS WOULD TURN THE
    /// BUTTON'S ONLY INTERESTING OUTCOME INTO "this version of the app does not
    /// understand the response", with no retry offered, on a working app talking to a
    /// working server. `MessagingRepositoryTests` asserts that it does not.
    ///
    /// ⚠️ THE SENTENCE QUOTES THE CARRIER, error code and all. That is what makes it
    /// worth forwarding verbatim: "Authenticate (20003)" is searchable in Twilio's
    /// own documentation and nothing this client could invent would be.
    func testARejectedProbeIsTheSameTypeAndKeepsTheCarriersWords() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messaging-test-rejected.json",
            as: MessagingTestResponse.self
        )

        XCTAssertFalse(response.success, "⛔ an ANSWER, on a 200, not a failure")
        XCTAssertEqual(response.error, "Authenticate (20003)")
        XCTAssertNil(response.details)
        XCTAssertNil(response.detail, "nothing to show on a rejection but the error")
    }

    /// ⚠️ THE OTHER TWO PROVIDERS' `details` SHAPES, DECODED FROM LITERAL BYTES
    /// BECAUSE NO FIXTURE CARRIES EITHER. Telnyx answers `{message}` and Sinch
    /// answers `{message, smsAuth}`; both are passes, and a DTO with any required
    /// field on `details` would throw on them while the Twilio fixture stayed green.
    ///
    /// ⛔ `smsAuth` IS THE FIELD THE ANDROID MODEL DOES NOT HAVE, and it is not
    /// cosmetic: a Sinch account can authenticate on the numbers API and still be
    /// unable to send, which is how one workspace read "Credentials verified" for
    /// months while every send 401ed. Reporting which credential pair was probed is
    /// what closed that, so dropping the field would silently discard the answer.
    func testTheOtherProvidersPassWithAMessageAndSinchAlsoReportsItsAuthMode() throws {
        let telnyx = try Self.decode(
            MessagingTestResponse.self,
            from: #"{"success":true,"details":{"message":"Credentials verified"}}"#
        )
        XCTAssertTrue(telnyx.success)
        XCTAssertEqual(telnyx.detail, "Credentials verified", "falls back to `message`")
        XCTAssertNil(telnyx.details?.friendlyName)

        let sinch = try Self.decode(
            MessagingTestResponse.self,
            from: #"{"success":true,"details":{"message":"Credentials verified","smsAuth":"service-plan"}}"#
        )
        XCTAssertEqual(sinch.details?.smsAuth, "service-plan")
        XCTAssertEqual(sinch.detail, "Credentials verified")
    }

    /// ⚠️ A PASS THAT VOLUNTEERED NOTHING IS STILL A PASS. `details` absent is a
    /// legitimate body rather than a decode problem, and `detail` answering nil is
    /// what a screen has to be able to render.
    func testAProbeThatVolunteeredNothingIsStillAPass() throws {
        let response = try Self.decode(MessagingTestResponse.self, from: #"{"success":true}"#)

        XCTAssertTrue(response.success)
        XCTAssertNil(response.details)
        XCTAssertNil(response.detail)
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func envelope(of fixture: String) throws -> [String: Any] {
        let raw = try ContractFixtures.read(fixture)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], fixture)
    }

    private static func object(in fixture: String, under key: String) throws -> [String: Any] {
        let body = try envelope(of: fixture)
        return try XCTUnwrap(body[key] as? [String: Any], "\(fixture) has no object at \(key)")
    }

    private static func array(in fixture: String, under key: String) throws -> [[String: Any]] {
        let body = try envelope(of: fixture)
        return try XCTUnwrap(body[key] as? [[String: Any]], "\(fixture) has no array at \(key)")
    }
}
