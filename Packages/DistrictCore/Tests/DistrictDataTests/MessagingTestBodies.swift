import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// Minimal, VALID bodies for the messaging shapes, shared by the four messaging
/// repository suites.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-messaging*.json` pins the wire shape
/// through the strict gate; what lives here is the smallest body that satisfies the
/// Swift type, so those tests can be about outcomes, paths and request bytes rather
/// than about JSON.
///
/// ⛔ NO BODY HERE CARRIES A CREDENTIAL, matching the route: the account read is
/// redacted server-side and the DTO has no field for one. A fixture that invented a
/// secret would be testing a response the server cannot send.
///
/// ⚠️ INTERNAL RATHER THAN `private` BECAUSE THE SUITES ARE SPLIT ACROSS FILES, and
/// they are split because SwiftLint's file-length ceiling is 500 lines and
/// `--strict` promotes that warning to an error. One messaging surface, four
/// suites, one set of bodies.
enum MessagingBodies {
    static let accounts = #"""
    {"success":true,
     "accounts":[
       {"id":"acct-a","provider":"twilio","label":"Twilio (main)","credentialSource":"byok",
        "phoneNumbers":["+14165550111"]},
       {"id":"acct-b","provider":"telnyx","label":"Telnyx","credentialSource":"managed",
        "phoneNumbers":["+14165550113"]}],
     "managedAccount":{"provider":"twilio","phoneNumbers":["+14165550190"]},
     "defaultAccountId":"acct-b",
     "channelDefaults":{"sms":"acct-a"}}
    """#

    /// ⛔ THE FRESH-WORKSPACE SHAPE: `managedAccount` NULL and `defaultAccountId`
    /// ABSENT. Both are deliberate, and a body that nulled the second instead would
    /// be testing a shape the server never sends.
    static let unmanaged = #"""
    {"success":true,"accounts":[],"managedAccount":null,"channelDefaults":{}}
    """#

    static let saved = #"{"success":true,"accountId":"acct-a","defaultAccountId":"acct-b"}"#

    static let channelDefaults = #"""
    {"success":true,"channelDefaults":{"sms":"acct-a","voice":"acct-b"}}
    """#

    static let probePassed = #"""
    {"success":true,"details":{"friendlyName":"Distronode Contract","status":"active"}}
    """#

    static let probeRejected = #"{"success":false,"error":"Authenticate (20003)"}"#

    /// ⛔ BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE JSON. A raw
    /// multi-line string may break between JSON tokens, but a newline INSIDE a string
    /// value is invalid JSON, and the failure it produces reads as a bug in the
    /// repository under test rather than in the fixture.
    static let probeRateLimited = #"{"error":"\#(probeRateLimitSentence)"}"#

    static let probeRateLimitSentence = "Too many connection tests for this workspace. "
        + "Please wait a moment before testing again."

    /// ⛔ THE 502's AUTHORED SENTENCE. It names the number and the carrier, which is
    /// what makes it the one 5xx body on this surface worth rendering.
    static let unverifiable = #"{"success":false,"error":"\#(unverifiableSentence)"}"#

    static let unverifiableSentence = "Could not verify ownership of +14165550111 with twilio "
        + "right now. Please try again shortly."

    static let notEntitled = #"{"success":false,"error":"\#(notEntitledSentence)"}"#

    static let notEntitledSentence = "This workspace is not entitled to managed carrier credentials."

    /// The 403 every write answers for a `viewer`, and the two failures every call
    /// has to keep distinct from it.
    static let forbidden = #"{"success":false,"error":"Forbidden"}"#
    static let unauthorized = #"{"error":"Unauthorized"}"#
    static let degraded = #"{"success":false,"error":"Try again"}"#

    /// An account draft with no credential in it, which is the ordinary EDIT: a
    /// blank or absent secret means "keep the stored ciphertext".
    static func draft(accountId: String? = nil, makeDefault: Bool? = nil) -> MessagingAccountDraft {
        MessagingAccountDraft(
            activeProvider: "twilio",
            credentialSource: "byok",
            providerConfig: .object([:]),
            accountId: accountId,
            makeDefault: makeDefault
        )
    }
}

extension MessagingRepository {
    /// The repository over a stub transport.
    ///
    /// ⛔ THE ONLY WAY THIS TYPE IS CONSTRUCTED ANYWHERE IN THE TESTS, and for
    /// ``MessagingRepository/testCredentials(workspaceId:providerConfig:)`` that is
    /// load-bearing rather than tidy: a live call makes one authenticated
    /// third-party request per POST with caller-supplied credentials, from the
    /// platform's own egress.
    static func testing(_ transport: RepositoryTransport) -> MessagingRepository {
        MessagingRepository(client: .repositoryTest(transport))
    }
}
