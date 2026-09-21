import DistrictModel
import DistrictNetwork
import Foundation

/// The workspace's outbound carrier accounts: one read, five writes on one path,
/// and a credential probe on a sibling.
///
/// ⛔ ITS OWN REPOSITORY RATHER THAN A METHOD ON ``WorkspaceRepository``, AND THE
/// ROLE CONTRACT IS THE REASON. Everything on the workspace-settings surface
/// excludes `viewer` server-side including the config READ, because that payload
/// carries staff transfer numbers and the operator's own prompt. Here the read
/// ADMITS a viewer and every write excludes one. One repository whose calls
/// disagree about who may make them is how a UI gate ends up derived from the
/// wrong rule, and being wrong in the permissive direction lands a real
/// read-only member on a 403 they were invited to. Same split, same reason, as
/// ``KnowledgeRepository``.
///
/// ⛔ FIVE OF THE SEVEN CALLS ARE ONE URL AND ONE VERB, TOLD APART ONLY BY AN
/// `action` STRING IN THE BODY. There is no `messaging/default` and no
/// `messaging/delete`; both would 404. The descriptors bake their own action in so
/// a call site cannot pass the wrong one, and the route's switch has a `default`
/// arm that falls through to the UPSERT, which is what makes a misspelled action
/// dangerous rather than merely wrong.
///
/// ⛔ NOTHING HERE PATCHES AN ON-SCREEN LIST FROM A WRITE'S RESPONSE. The upsert
/// echoes ids only, the delete echoes a default id whose ABSENCE is
/// indistinguishable from "there is no default now", and the route trims labels
/// and filters numbers before storing them. Every write is followed by a re-read
/// of ``accounts(workspaceId:)``, and that is the caller's job because the list is
/// what is on screen.
///
/// ⛔ AND NO WRITE HERE IS RETRIED, EVER. ``saveAccount(workspaceId:account:)``
/// with a nil `accountId` mints a fresh `acct-<uuid>` inside the transaction, so
/// two deliveries are two accounts;
/// ``testCredentials(workspaceId:providerConfig:)`` makes a live authenticated
/// call to a third party per request. Neither is idempotent in any useful sense.
///
/// ⚠️ NO CACHE, like every sibling. These numbers are what an operator checks
/// when a message went out from the wrong identity, and a process-scoped copy
/// would answer with the state from before whatever they just changed.
public struct MessagingRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The workspace's carrier accounts, its platform-owned numbers, the default
    /// sender and the per-channel overrides.
    ///
    /// ⛔ THE WHOLE ENVELOPE IS RETURNED RATHER THAN A NARROWED VALUE, because
    /// four of its fields are one answer. A caller with the accounts and not the
    /// default would draw a sender list it could not caption, and one with the
    /// accounts and not ``MessagingResponse/managedAccount`` would show a
    /// workspace as having no numbers when the platform holds several.
    ///
    /// ⚠️ ENVELOPE-CHECKED EVEN THOUGH THE DTO'S REQUIRED FIELDS REJECT `{}`. They
    /// do not reject a well-formed `success: false`, which is what this route's
    /// catch branch produces once the headers are written, and "we could not look"
    /// rendering as "this workspace sends through nothing" is the wrong answer on
    /// the screen an operator opens after a message went out wrong.
    ///
    /// ⚠️ REDACTED SERVER-SIDE. No credential is on this response and none may be
    /// added to the DTO; see the ⛔ on ``MessagingAccount``.
    public func accounts(workspaceId: String) async -> Result<MessagingResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.messaging(workspaceId: workspaceId),
            as: MessagingResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("MessagingResponse", $0.success, $0) }
    }

    /// Create or edit one carrier account.
    ///
    /// ⛔ NON-IDEMPOTENT WHEN THE DRAFT CARRIES NO `accountId`, AND NOTHING MAY
    /// RETRY IT. The route mints `acct-<uuid>` inside the transaction, so a request
    /// that timed out may well have created the account and a second attempt
    /// creates another one, with its own copy of the credentials.
    ///
    /// ⛔ A BLANK OR ABSENT SECRET MEANS "KEEP THE STORED CIPHERTEXT", which is
    /// what makes an edit form possible against a redacted read: the ordinary
    /// rename types no credential at all. ⚠️ EXCEPT ON A PROVIDER CHANGE, where the
    /// stored secrets are DISCARDED rather than reused, so a blank field there
    /// means "store nothing".
    ///
    /// ⛔ THE **502** IS NOT A REFUSAL AND MUST NOT BE WORDED AS ONE. The route
    /// separates it from its three 403s on purpose: it means the carrier-ownership
    /// probe could not reach the carrier, so the number stays unclaimed either way
    /// and trying again shortly is both safe and the correct advice. Its body is an
    /// authored sentence naming the number and the carrier.
    ///
    /// ⚠️ THAT DISTINCTION NEEDS NO OUTCOME TYPE ON THIS CLIENT, WHICH IS THE ONE
    /// PLACE THIS LAYER IS DELIBERATELY SIMPLER THAN THE KOTLIN ONE.
    /// `MessagingWriteOutcome.Unverifiable` exists there because that client's
    /// `FailureText` refuses to render ANY 5xx body verbatim, so the sentence would
    /// be lost before a screen saw it. ``ApiError/http(status:message:)`` keeps both
    /// the status and the message, so a caller branches on
    /// ``ApiError/httpStatus`` == 502 and shows ``ApiError/message``. ⛔ If a
    /// `FailureText` equivalent is ever added to the App target, it must special-case
    /// this status or this information is lost in exactly the way that type was
    /// invented to prevent.
    ///
    /// ⚠️ THE THREE 403s PASS THROUGH UNTOUCHED, on purpose: "not entitled to
    /// managed credentials", "that number is not in this workspace" and "managed
    /// numbers can only be added by purchasing them" are each more useful than any
    /// sentence this layer could invent.
    public func saveAccount(
        workspaceId: String,
        account: MessagingAccountDraft
    ) async -> Result<MessagingAccountSaveResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.saveMessagingAccount(workspaceId: workspaceId, account: account),
            as: MessagingAccountSaveResponse.self
        )
        return outcome.flatMap {
            ResponseEnvelope.affirm("MessagingAccountSaveResponse", $0.success, $0)
        }
    }

    /// Point every outbound send at one account.
    ///
    /// ⚠️ IDEMPOTENT AND REVERSIBLE, which makes it the least consequential write
    /// here, and its whole observable effect is the field it echoes.
    public func setDefaultAccount(
        workspaceId: String,
        accountId: String
    ) async -> Result<MessagingDefaultResponse, ApiError> {
        await affirmDefault(
            DistrictEndpoints.setDefaultAccount(workspaceId: workspaceId, accountId: accountId)
        )
    }

    /// Override the sender for one channel.
    ///
    /// ⚠️ MERGES ONE KEY into the stored map and echoes the whole map back; there is
    /// no clear. A channel outside the server's set is a 400 naming the value, which
    /// is worth showing verbatim.
    public func setChannelDefault(
        workspaceId: String,
        channel: String,
        accountId: String
    ) async -> Result<MessagingChannelDefaultResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.setChannelDefault(
                workspaceId: workspaceId,
                channel: channel,
                accountId: accountId
            ),
            as: MessagingChannelDefaultResponse.self
        )
        return outcome.flatMap {
            ResponseEnvelope.affirm("MessagingChannelDefaultResponse", $0.success, $0)
        }
    }

    /// Remove one carrier account.
    ///
    /// ⛔ IT FREES EVERY PHONE NUMBER ONLY THIS ACCOUNT HELD, in the hub index that
    /// routes inbound calls and SMS to this workspace and that four sibling routes
    /// check ownership against. Once released the number is unclaimed and another
    /// tenant can take it, and there is no undo that does not involve re-proving
    /// ownership at the carrier. A confirmation has to name that consequence rather
    /// than ask "are you sure".
    ///
    /// ⚠️ A FAILED HUB RELEASE IS NOT REPORTED AT ALL. The route logs it and still
    /// answers success, because the account is gone either way and a stale index row
    /// points at THIS workspace rather than leaking anywhere. So a success here means
    /// "the account is removed", not "every claim was released", and the response
    /// says nothing about how many numbers were freed.
    ///
    /// ⚠️ ANSWERS **404** for an id this workspace does not hold, which on this
    /// screen means the list is stale rather than that anything is broken.
    public func deleteAccount(
        workspaceId: String,
        accountId: String
    ) async -> Result<MessagingDefaultResponse, ApiError> {
        await affirmDefault(
            DistrictEndpoints.deleteMessagingAccount(workspaceId: workspaceId, accountId: accountId)
        )
    }

    /// Write the workspace's creator cell number.
    ///
    /// ⛔ NOTHING IN THIS CLIENT CAN READ THE STORED VALUE BACK. It is not on the
    /// messaging GET and this write answers a bare `{success:true}`, so a form must
    /// ask for a new value and SAY that rather than presenting an empty field an
    /// operator reads as "not set".
    ///
    /// ⚠️ ITS OWN ACTION because a workspace with no carrier account has no upsert
    /// to carry the field, and that is exactly the workspace most likely to be
    /// setting it.
    public func saveCreatorCell(
        workspaceId: String,
        creatorCellNumber: String
    ) async -> Result<Void, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.saveCreatorCell(
                workspaceId: workspaceId,
                creatorCellNumber: creatorCellNumber
            ),
            as: SuccessResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MessagingMetaResponse", $0.success, $0) }
            .map { _ in }
    }

    /// Ask the carrier whether these credentials authenticate.
    ///
    /// ⛔ THE ONE METHOD ON THIS TYPE THAT MUST NOT RUN THE ENVELOPE GUARD, AND
    /// THE REASON IS THE WHOLE POINT OF THE BUTTON. The route answers a failed
    /// credential check with HTTP **200** and `{success:false, error}` on purpose,
    /// so "these keys are wrong" is a normal answer rather than a server fault.
    /// Running ``ResponseEnvelope/affirm(_:_:_:)`` over it would report "this
    /// version of the app does not understand the response" for the only
    /// interesting outcome the button has, with no retry offered, on a working app
    /// talking to a working server. So the response is handed back whole and the
    /// caller branches on ``MessagingTestResponse/success``.
    ///
    /// ⛔ IT MUST NEVER BE CALLED IN A TEST THAT REACHES A REAL SERVER, AND THIS IS
    /// NOT A STYLE RULE. Every request makes one authenticated third-party call
    /// with the credentials in the body: Twilio `accounts.fetch`, Sinch's numbers
    /// list AND a dry-run batch list, or a Telnyx `/v2/balance` read. Those go out
    /// from the platform's origin IPs, under Distronode's reputation, against an
    /// account this client does not own, and the route is a clean
    /// credential-validation oracle by design. A test that drove it live would be
    /// sorting somebody's carrier keys at our expense, and enough volume gets the
    /// egress throttled or blocked by the carrier for EVERY tenant at once. The
    /// server's own guard is 10/min per workspace and it is Redis-backed and
    /// FAIL-OPEN, so it is not a backstop. ⛔ For the same reason nothing may call
    /// this from a redraw, a retry or a loop. `MessagingRepositoryTests` drives it
    /// only through the stub transport, and that is the only way it is exercised
    /// anywhere in this package.
    ///
    /// ⛔ AND THE CREDENTIALS TRAVEL IN PLAINTEXT AND HAVE NOT BEEN SAVED, which is
    /// what makes the call possible at all (the stored ones are KMS-wrapped and the
    /// route would have nothing to decrypt them with) and what bounds it to a form
    /// that actually holds them.
    ///
    /// ⚠️ A TRANSPORT OR STATUS FAILURE IS NOT EVIDENCE ABOUT THE CREDENTIALS and
    /// must not be worded as if it were. "We could not ask" and "your keys do not
    /// authenticate" are different facts, and merging them tells someone their
    /// perfectly good secret is wrong because their phone lost signal, on the one
    /// screen where believing that leads to re-typing a live carrier secret.
    public func testCredentials(
        workspaceId: String,
        providerConfig: JSONValue
    ) async -> Result<MessagingTestResponse, ApiError> {
        await client.send(
            DistrictEndpoints.testMessagingCredentials(
                workspaceId: workspaceId,
                providerConfig: providerConfig
            ),
            as: MessagingTestResponse.self
        )
    }

    /// ⚠️ `setDefault` AND `delete` SHARE ONE RESPONSE SHAPE, so they share one
    /// envelope check. The two fixtures are still gated separately, so the sharing
    /// cannot hide a divergence.
    private func affirmDefault(
        _ descriptor: ApiRequestDescriptor
    ) async -> Result<MessagingDefaultResponse, ApiError> {
        let outcome = await client.send(descriptor, as: MessagingDefaultResponse.self)
        return outcome.flatMap {
            ResponseEnvelope.affirm("MessagingDefaultResponse", $0.success, $0)
        }
    }
}
