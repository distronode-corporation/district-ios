import Foundation

/// One carrier account the workspace sends through, as the read route projects it.
///
/// ⛔ NO CREDENTIAL FIELD EXISTS ON THIS TYPE AND NONE MAY BE ADDED. The route
/// builds a five-key object out of the stored `providerConfig` and nothing else:
/// the account SID, the auth token, the key secret and the application secret
/// never leave the server on this path, and the server's own contract test
/// asserts both that the key set is exactly these five and that neither secret
/// appears anywhere in the body. A field added here would be a request to widen
/// the route rather than a decoding fix.
///
/// ⚠️ ``credentialSource`` IS `byok` OR `managed` AND IT IS THE FIELD AN OPERATOR
/// ACTUALLY NEEDS: a `byok` account bills on their own carrier account and a
/// `managed` one bills through us. The route defaults it to `byok` when a legacy
/// config omitted it, so in practice it is never absent.
///
/// ⚠️ THREE FIELDS ARE OPTIONAL BECAUSE THE ROUTE CAN OMIT THEM, NOT BECAUSE THE
/// SERVER NULLS THEM. `provider`, `label` and `credentialSource` are copied from
/// a `Json` column through expressions that can evaluate to `undefined`, and
/// `JSON.stringify` DROPS an undefined value's key rather than writing null. So
/// nil here means "the stored config did not have one", and a null on any of them
/// would be contract drift the strict gate must still catch.
///
/// ⚠️ ``phoneNumbers`` IS NON-OPTIONAL because the route writes
/// `(a.providerConfig?.phoneNumbers || []).filter(Boolean)`, which is always an
/// array. An empty one is a real answer: an account whose numbers have not been
/// added yet.
public struct MessagingAccount: Codable, Sendable {
    /// ⛔ THE ID SPACE A `from` IS VALIDATED AGAINST. `resolveSendingContext`
    /// looks a sender id up in `messagingConfig.accounts` and rejects anything it
    /// does not find as a spoofing attempt, which is why the platform account
    /// below has no id.
    public let id: String
    public let provider: String?
    /// ⚠️ Already defaulted server-side to a title-cased provider name when the
    /// stored label is blank, so this is display-ready.
    public let label: String?
    /// ⚠️ `byok` or `managed`. See the ⚠️ on the type.
    public let credentialSource: String?
    public let phoneNumbers: [String]
}

/// The PLATFORM's carrier account for this workspace: numbers Distronode bought
/// on the tenant's behalf, on our credentials.
///
/// ⛔ IT IS NOT AN ENTRY IN ``MessagingResponse/accounts`` AND MUST NOT BE
/// RENDERED AS ONE. That array is both the from-picker and the id space
/// `resolveSendingContext` resolves a sender against, so a synthetic managed
/// entry would be a pickable sender whose every send is rejected outright, and
/// `setDefault` / `setChannelDefault` would answer 404 for its invented id. The
/// absence of an ``MessagingAccount/id`` here is the server saying so in the
/// shape of the response, and the route carries a ⛔ asking that it not be folded
/// in.
///
/// ⚠️ ``provider`` IS OPTIONAL EVEN THOUGH THE OBJECT EXISTS. `projectManagedSummary`
/// constructs two fields explicitly and OMITS `provider` when the stored value is
/// missing or blank; it returns null outright when there are no numbers, which is
/// the `managedAccount: null` branch that `district-messaging-unmanaged.json`
/// pins.
public struct ManagedMessagingAccount: Codable, Sendable {
    public let provider: String?
    public let phoneNumbers: [String]
}

/// `GET /api/district/workspace/messaging?workspaceId=`. Which carrier accounts
/// this workspace sends through.
///
/// ⛔ TWO FIXTURES WITH DIFFERENT KEY SETS, WHICH IS THE THING A STRICT DECODER
/// HERE HAS TO SURVIVE. `district-messaging.json` carries `defaultAccountId`;
/// `district-messaging-unmanaged.json` does not carry the key at all, because
/// `effectiveDefaultId` returns undefined for an empty account list and
/// `JSON.stringify` drops it. The same fixture nulls ``managedAccount``. So the
/// two are not a long and a short version of one shape: they differ in whether a
/// key exists and in whether another one is null, and only one of those is a null
/// the allowlist can permit.
///
/// ⛔ THE WHOLE ENVELOPE IS ONE ANSWER, WHICH IS WHY THE REPOSITORY RETURNS IT
/// WHOLE. The accounts, the platform-owned account, which one is the default and
/// the per-channel overrides are four halves of the same question, and a screen
/// that had any three of them would draw a sender list it could not caption.
///
/// ⚠️ ADMITS `viewer`, unlike `workspace/config`. Nothing here is a credential and
/// nothing is a staff transfer number: it is the workspace's own outbound
/// identity. A viewer genuinely reaches this screen, so every control on it has to
/// be gated even though the read is not.
public struct MessagingResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Non-Optional: the route always emits the array. Empty is a real answer.
    public let accounts: [MessagingAccount]
    /// ⛔ Its OWN field, never an entry in ``accounts``. Null when the platform
    /// holds no numbers for this workspace.
    public let managedAccount: ManagedMessagingAccount?
    /// ⚠️ ABSENT, not null, when the workspace has no accounts. See the ⛔ on the
    /// type.
    public let defaultAccountId: String?
    /// Per-channel sender overrides, keyed by channel name.
    ///
    /// ⚠️ AN OPEN MAP RATHER THAN AN ENUM OF CHANNELS. The server stores whatever
    /// key was set (`sms`, `voice`, `whatsapp`), so a channel added on the web has
    /// to render here rather than fail to decode. ⚠️ `{}` is the ordinary state.
    public let channelDefaults: [String: String]
}

/// What an upsert answers.
///
/// ⛔ IT ECHOES IDS AND NOTHING ELSE, SO A SAVE MUST BE FOLLOWED BY A RE-READ.
/// There is no label, no provider and no numbers here, so there is nothing to
/// patch an on-screen list with, and a row rebuilt from the REQUEST would show
/// what the operator typed rather than what was stored: the route trims the label,
/// substitutes a title-cased provider name for a blank one, and filters
/// `phoneNumbers`.
///
/// ⚠️ ``accountId`` IS THE SERVER'S ON A CREATE, minted as `acct-<uuid>` inside
/// the transaction, and is the id that was sent back unchanged on an edit. That is
/// also why a create is not idempotent and nothing may retry it.
///
/// ⚠️ ``defaultAccountId`` CAN CHANGE WITHOUT BEING ASKED TO. The route makes the
/// first account of a workspace the default (`makeDefault || !defaultAccountId`),
/// so a create that did not tick the box still comes back naming itself.
public struct MessagingAccountSaveResponse: Codable, Sendable {
    public let success: Bool
    public let accountId: String?
    public let defaultAccountId: String?
}

/// What `setDefault` and `delete` answer. The SAME shape, deliberately shared.
///
/// ⛔ ONE TYPE FOR TWO ACTIONS BECAUSE THE ROUTE GENUINELY RETURNS ONE SHAPE, and
/// two structs would imply a difference the server does not make. Both answer
/// `{success, defaultAccountId}`, and both fixtures are pinned SEPARATELY against
/// this type, so the day one of them grows a field that one fails on its own.
///
/// ⚠️ THE DELETE'S ECHO IS THE ONLY PLACE A MOVED DEFAULT IS ANNOUNCED. Removing
/// the account that WAS the default re-points at whatever is left, and nothing
/// else in the response says so, which is what `district-messaging-delete.json`
/// records.
///
/// ⚠️ ``defaultAccountId`` IS ABSENT, not null, WHEN THE LAST ACCOUNT WAS DELETED:
/// `mirrorLegacy` assigns undefined for an empty list. So "there is no default
/// now" and "the key did not arrive" are the same value here, which is a second
/// reason a delete cannot be rendered from this response alone.
public struct MessagingDefaultResponse: Codable, Sendable {
    public let success: Bool
    public let defaultAccountId: String?
}

/// What `setChannelDefault` answers.
///
/// ⚠️ THE WHOLE MAP COMES BACK, not just the channel that changed, because the
/// route MERGES one key and echoes the result. `district-messaging-channel-default.json`
/// therefore has to carry two entries or it proves nothing: a fixture built from a
/// workspace with no existing override would look identical whether the route
/// merged or replaced.
///
/// ⚠️ SO THIS ONE WRITE NEEDS NO RE-READ TO REDRAW THE CHANNEL SECTION, though a
/// screen re-reads anyway because a channel default is rendered against the
/// account LIST.
public struct MessagingChannelDefaultResponse: Codable, Sendable {
    public let success: Bool
    public let channelDefaults: [String: String]
}

/// What `messaging/test` answers.
///
/// ⛔ A FAILED CREDENTIAL CHECK IS AN HTTP **200** WITH `success:false`, AND THAT
/// IS THE TRAP ON THIS TYPE. Every other envelope on this surface treats
/// `success: false` on a 200 as contract drift, because for every other route it
/// means the body was structurally empty. Here it is THE ANSWER: the route catches
/// the carrier's rejection and reports it this way on purpose, so the operator is
/// told "these keys do not authenticate" rather than "the server broke". Running
/// ``ResponseEnvelope/affirm(_:_:_:)`` over this would turn the button's only
/// interesting outcome into "this version of the app does not understand the
/// response", with no retry offered, for a working app talking to a working
/// server. ``MessagingRepository/testCredentials(workspaceId:providerConfig:)`` is
/// the one method on that type which must not run the guard.
///
/// ⚠️ ``details`` IS THREE DIFFERENT SHAPES FROM THREE PROVIDERS, which is why
/// every field on it is Optional. Twilio answers `{friendlyName, status}`, Telnyx
/// answers `{message}`, and Sinch answers `{message, smsAuth}`. A type per
/// provider would be three types for one button, and any required field would
/// throw on the other two providers' success.
public struct MessagingTestResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ The carrier's own words, forwarded. Present on the `success: false`
    /// branch and absent on the pass.
    public let error: String?
    /// ⚠️ Absent is a legitimate PASS rather than a decode problem: the provider
    /// simply volunteered nothing about the account.
    public let details: MessagingTestDetails?

    /// The one sentence worth showing after a pass, whichever provider answered.
    ///
    /// ⚠️ `friendlyName` FIRST BECAUSE IT IS THE MORE SPECIFIC OF THE TWO: it is
    /// the carrier's own name for the account, which tells an operator they wired
    /// up the account they meant to. `message` is a bare confirmation. nil is a
    /// pass that said nothing, which is still a pass.
    ///
    /// ⚠️ COMPUTED, SO IT IS NOT ENCODED, and the strict gate's key-set walk
    /// therefore never sees it. Same reason ``DeskTicketSummary/knownStatus`` is computed.
    public var detail: String? {
        details?.friendlyName ?? details?.message
    }
}

/// The union of all three providers' `details` shapes.
///
/// ⛔ `smsAuth` IS MODELLED EVEN THOUGH NO FIXTURE CARRIES IT, and that is
/// deliberate rather than speculative. Sinch's pass answers
/// `{message, smsAuth}`, where `smsAuth` is `service-plan` or `project`, and it
/// exists because a Sinch account can authenticate on the numbers API and still be
/// unable to send: one workspace read "Credentials verified" in settings for months
/// while every send 401ed, and reporting WHICH auth mode was probed is what closed
/// that. The corpus only holds the Twilio shape, so nothing would have failed had
/// this been dropped, and a screen would silently have had nothing to show.
///
/// ⚠️ MODELLING IT COSTS THE GATE NOTHING because a nil Optional re-encodes as an
/// absent key, which is exactly what the Twilio fixture has.
public struct MessagingTestDetails: Codable, Sendable {
    /// ⚠️ Twilio only: the carrier's own name for the account.
    public let friendlyName: String?
    /// ⚠️ Twilio only: the account's carrier-side status, e.g. `active`.
    public let status: String?
    /// ⚠️ Sinch and Telnyx: a bare confirmation sentence.
    public let message: String?
    /// ⚠️ Sinch only. `service-plan` or `project`, i.e. which credential pair the
    /// SMS host was probed with. See the ⛔ on the type.
    public let smsAuth: String?
}

// ⛔ THERE IS NO `MessagingMetaResponse` HERE. The `meta` action answers exactly
// `{"success": true}` with no echo, which is what ``SuccessResponse`` already is,
// so `district-messaging-meta.json` is gated against that type in
// `ImplementedFixtures` alongside the workspace-settings patches, the push pair
// and the bare acknowledgements. See the ⛔ at the foot of
// `WorkspaceConfigResponses.swift`: sharing is safe because the gate pins each
// fixture separately, and a bespoke struct with one `Bool` would prove nothing the
// shared one does not.
//
// ⛔ THE CONSEQUENCE IS WORTH STATING BECAUSE IT IS A PRODUCT DECISION RATHER THAN
// A SHAPE DETAIL: nothing in this client can READ the stored creator cell number.
// It is not on the messaging GET and the write does not echo it, so a form has to
// ask for a new value rather than pre-fill one, and must say so instead of
// presenting an empty field that looks like "not set".
