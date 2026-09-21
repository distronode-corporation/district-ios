import Foundation

/// One carrier account, as the upsert takes it.
///
/// ⛔ A TYPE RATHER THAN SEVEN LOOSE PARAMETERS, and not only for the argument
/// count: five of the seven are strings, so a transposition at a call site would
/// compile and would post a label where a provider belongs. The Kotlin client
/// keeps `MessagingAccountRequest` for the same reason.
///
/// ⛔ IT CARRIES NO `action` FIELD, DELIBERATELY. The upsert is the route's
/// DEFAULT branch; adding one would change which branch runs.
public struct MessagingAccountDraft: Sendable, Equatable {
    public let activeProvider: String
    public let credentialSource: String
    /// ⚠️ CARRIED WHOLE as the server's own object. A blank or absent secret means
    /// "keep the stored ciphertext" — except on a provider change, which discards
    /// them.
    public let providerConfig: JSONValue
    /// ⛔ NIL MEANS CREATE, AND CREATE IS NOT IDEMPOTENT: two deliveries are two
    /// accounts under two freshly minted ids.
    public let accountId: String?
    public let label: String?
    public let makeDefault: Bool?
    public let creatorCellNumber: String?

    public init(
        activeProvider: String,
        credentialSource: String,
        providerConfig: JSONValue,
        accountId: String? = nil,
        label: String? = nil,
        makeDefault: Bool? = nil,
        creatorCellNumber: String? = nil
    ) {
        self.activeProvider = activeProvider
        self.credentialSource = credentialSource
        self.providerConfig = providerConfig
        self.accountId = accountId
        self.label = label
        self.makeDefault = makeDefault
        self.creatorCellNumber = creatorCellNumber
    }
}

/// The workspace's outbound carrier accounts: one read, five writes on one path,
/// and a probe on a sibling.
///
/// ⛔ FIVE FUNCTIONS, ONE URL, AND THE `action` IS IN THE BODY RATHER THAN THE
/// PATH. There is no `messaging/default` or `messaging/delete` — both would 404 —
/// so the only thing separating a default change from a deletion is a string
/// inside the JSON. Each function bakes its own action in rather than taking one,
/// so a call site cannot pass the wrong action without changing the function it
/// calls.
///
/// ⛔ THE READ ADMITS `viewer` AND EVERY WRITE EXCLUDES ONE. The settings hub is
/// open to viewers, so a viewer REACHES this screen and must be
/// offered no control on it.
public extension DistrictEndpoints {
    /// The workspace's carrier accounts. ⚠️ Redacted server-side: no credential
    /// is on this response.
    static func messaging(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .messaging,
            .get,
            DistrictPaths.workspaceMessaging,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Create or edit one carrier account.
    ///
    /// ⛔ NON-IDEMPOTENT WHEN `accountId` IS NIL — the route mints a fresh
    /// `acct-<uuid>`, so two deliveries are two accounts. Nothing may retry it.
    ///
    /// ⛔ THE UPSERT IS THE ONE ACTION WITH NO `action` KEY, DELIBERATELY: it is
    /// the route's default branch, and adding one would change which branch runs.
    ///
    /// ⛔ A BLANK OR ABSENT SECRET MEANS "KEEP THE STORED CIPHERTEXT", WHICH IS
    /// WHY THE ORDINARY EDIT TYPES NO CREDENTIAL AT ALL — and why the nil-drop in
    /// ``JSONValue/object(_:)`` is load-bearing here rather than tidy. ⚠️ Except
    /// on a PROVIDER CHANGE: switching provider on an edit DISCARDS the stored
    /// secrets (`existingEnc` is only reused when the provider is unchanged), so
    /// there a blank field means "store nothing", not "keep".
    ///
    /// ⛔ FOUR DISTINCT REFUSALS REACH THE FORM VERBATIM AND MUST NOT BE
    /// FLATTENED: a managed request without the entitlement is 403; a number
    /// another workspace holds is 403 with a deliberately non-disclosing
    /// sentence; a number this account's own carrier does not own is 403 with the
    /// same sentence; and a carrier that could not be reached is **502**, which is
    /// NOT a refusal — the route separates it precisely so an outage does not read
    /// as theft.
    ///
    /// - Parameter providerConfig: carried WHOLE as the server's own object.
    static func saveMessagingAccount(
        workspaceId: String,
        account: MessagingAccountDraft
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveMessagingAccount,
            .patch,
            DistrictPaths.workspaceMessaging,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("activeProvider", .string(account.activeProvider)),
                ("credentialSource", .string(account.credentialSource)),
                ("providerConfig", account.providerConfig),
                ("accountId", .optional(account.accountId)),
                ("label", .optional(account.label)),
                ("makeDefault", account.makeDefault.map { JSONValue.bool($0) }),
                ("creatorCellNumber", .optional(account.creatorCellNumber)),
            ]))
        )
    }

    /// Point every outbound send at one account. ⚠️ Idempotent and reversible.
    static func setDefaultAccount(workspaceId: String, accountId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setDefaultAccount,
            .patch,
            DistrictPaths.workspaceMessaging,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("accountId", .string(accountId)),
                ("action", .string("setDefault")),
            ]))
        )
    }

    /// Override the sender for one channel.
    ///
    /// ⚠️ MERGES ONE KEY into the stored map; there is no clear. A `channel`
    /// outside `[sms, voice, whatsapp]` is a 400 naming the value.
    static func setChannelDefault(
        workspaceId: String,
        channel: String,
        accountId: String
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setChannelDefault,
            .patch,
            DistrictPaths.workspaceMessaging,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("channel", .string(channel)),
                ("accountId", .string(accountId)),
                ("action", .string("setChannelDefault")),
            ]))
        )
    }

    /// Remove one carrier account.
    ///
    /// ⛔ **PATCH, NOT DELETE, AND NOT A QUERY PARAMETER.** Unlike contacts and
    /// knowledge, removal here is an action on the shared PATCH body; a DELETE to
    /// this path is a 405.
    ///
    /// ⛔ IT ALSO FREES EVERY PHONE NUMBER ONLY THIS ACCOUNT HELD, in the hub
    /// index that routes inbound calls and SMS — the claims that stop another
    /// tenant sending as this one. Confirm it with wording that says so.
    ///
    /// ⚠️ ANSWERS 404 "Account not found" for an id the workspace does not hold,
    /// which on this screen means the list is stale rather than that anything is
    /// broken.
    static func deleteMessagingAccount(workspaceId: String, accountId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteMessagingAccount,
            .patch,
            DistrictPaths.workspaceMessaging,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("accountId", .string(accountId)),
                ("action", .string("delete")),
            ]))
        )
    }

    /// Write the workspace's creator cell number.
    ///
    /// ⚠️ ITS OWN ACTION because a workspace with NO carrier account has no upsert
    /// to carry it, and that is the workspace most likely to be setting it.
    static func saveCreatorCell(workspaceId: String, creatorCellNumber: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveCreatorCell,
            .patch,
            DistrictPaths.workspaceMessaging,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("creatorCellNumber", .string(creatorCellNumber)),
                ("action", .string("meta")),
            ]))
        )
    }

    /// Ask the carrier whether these credentials authenticate.
    ///
    /// ⛔ A REFUSAL IS A **200 WITH `success:false`**, NOT AN ERROR STATUS.
    /// Anything that applies this client's usual envelope guard to it will report
    /// "we could not understand the response" for the answer the button exists to
    /// give.
    ///
    /// ⛔ IT TAKES PLAINTEXT, UNSAVED CREDENTIALS, so it can only be offered when
    /// the form actually holds them, and it is rate limited to 10/min per
    /// WORKSPACE. Never call it on a loop or a redraw.
    static func testMessagingCredentials(
        workspaceId: String,
        providerConfig: JSONValue
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .testMessagingCredentials,
            .post,
            DistrictPaths.workspaceMessagingTest,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("providerConfig", providerConfig),
            ]))
        )
    }
}
