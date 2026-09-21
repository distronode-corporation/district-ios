import DistrictModel
import DistrictNetwork
import Foundation

// The Developer tab's ops: `apiKeys.*`, `oauth.connections.*` and `webhooks.*`.
//
// ⛔ THE THREE CREATE/DELETE PAIRS DO NOT SHARE A RESPONSE CONVENTION AND THE
// DIFFERENCES ARE THE CONTRACT. `apiKeys.create` and `webhooks.create` answer a
// row carrying a ONCE-ONLY secret; every delete answers nothing; and
// `webhooks.patch` — unlike the team patches elsewhere in the catalog — answers
// **204 with no body**, so a caller must refetch rather than trust an echo. Each
// method below states which it is, because the wrong assumption fails as a decode
// error blaming the contract.
//
// ⚠️ THE LISTS UNWRAP ``SchedulingItems``. A caller wants the rows.

public extension SchedulingAdminRepository {
    // MARK: - API keys

    /// `apiKeys.list`. ⛔ Never carries a secret; see ``SchedulingAPIKey``.
    func apiKeys(workspaceId: String) async throws -> [SchedulingAPIKey] {
        try await perform(
            .apiKeysList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingAPIKey>.self
        ).items
    }

    /// `apiKeys.create` — mint a key and see its plaintext ONCE.
    ///
    /// ⛔ THE RETURNED ``SchedulingAPIKeyCreated/key`` IS A LIVE CREDENTIAL AND
    /// THIS IS ITS ONLY APPEARANCE. It must not be logged, must not be persisted,
    /// and must not be interpolated into a copyable snippet — the web console
    /// holds it in a modal and drops it from state when the modal closes. Re-read
    /// ``apiKeys(workspaceId:)`` for anything that outlives the sheet.
    func createAPIKey(workspaceId: String, name: String) async throws -> SchedulingAPIKeyCreated {
        try await perform(
            .apiKeysCreate,
            workspaceId: workspaceId,
            params: .object([("name", .string(name))]),
            as: SchedulingAPIKeyCreated.self
        )
    }

    /// `apiKeys.delete` — revoke a key. ⚠️ Answers nothing.
    func deleteAPIKey(workspaceId: String, keyId: String) async throws -> SchedulingNoContent {
        try await perform(
            .apiKeysDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(keyId))]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Connected apps

    /// `oauth.connections.list` — third-party apps holding a grant.
    ///
    /// ⚠️ NOT API KEYS, THOUGH THE TABS LOOK ALIKE. A key is minted BY the
    /// customer; a connection is granted TO an app by a person consenting.
    func oauthConnections(workspaceId: String) async throws -> [SchedulingOAuthConnection] {
        try await perform(
            .oauthConnectionsList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingOAuthConnection>.self
        ).items
    }

    /// `oauth.connections.delete` — sign one app out. ⚠️ Answers nothing.
    func deleteOAuthConnection(workspaceId: String, connectionId: String) async throws -> SchedulingNoContent {
        try await perform(
            .oauthConnectionsDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(connectionId))]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Webhooks

    /// `webhooks.list`. ⛔ Carries no `secret`; it is minted once, on create.
    func webhooks(workspaceId: String) async throws -> [SchedulingWebhook] {
        try await perform(
            .webhooksList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingWebhook>.self
        ).items
    }

    /// `webhooks.create`.
    ///
    /// ⛔ `events` IS TYPED AS THE ENUM ON THE WAY OUT AND AS `[String]` ON THE WAY
    /// BACK, DELIBERATELY. A name the fork does not know is a hard **400**
    /// (`unknown event: <name>`) rather than an ignored key, so the request side is
    /// closed; a row created before a rename can still carry an unknown value, so
    /// the response side is open. See ``SchedulingWebhookEvent``.
    ///
    /// - Parameter fields: which payload fields are delivered. ⛔ nil MEANS "THE
    ///   FORK'S DEFAULT SET", NOT "NONE", and that default is not the same list the
    ///   console offers — it omits `event_type_name`, `host_name` and `host_email`,
    ///   so a webhook created with nil arrives missing values the form never offered
    ///   to remove. Send the list explicitly for anything a person configured.
    ///   ⚠️ `attendee_name`, `attendee_email`, `attendee_timezone` and `answers`
    ///   carry the BOOKER's own details out of this platform; they are off by
    ///   default in the console for that reason.
    func createWebhook(
        workspaceId: String,
        url: String,
        events: [SchedulingWebhookEvent],
        fields: [String]? = nil
    ) async throws -> SchedulingWebhookCreated {
        try await perform(
            .webhooksCreate,
            workspaceId: workspaceId,
            params: .object([
                ("url", .string(url)),
                ("events", .array(events.map { JSONValue.string($0.rawValue) })),
                ("fields", fields.map { JSONValue.array($0.map(JSONValue.string)) }),
            ]),
            as: SchedulingWebhookCreated.self
        )
    }

    /// `webhooks.patch` — change the events or the fields of an existing webhook.
    ///
    /// ⛔ IT ANSWERS **204 WITH NO BODY**, UNLIKE THE TEAM PATCHES IN THE SAME
    /// CATALOG, so there is no updated row to render and the caller must refetch
    /// ``webhooks(workspaceId:)``. A screen that optimistically applied its own
    /// edit and skipped the refetch shows the edit even when the fork clamped it.
    ///
    /// ⚠️ `events` IS `[String]` HERE AND THE ENUM ON CREATE, WHICH IS THE
    /// CATALOG'S OWN ASYMMETRY: `webhooks.patch` types the array
    /// `z.string().max(100)` with no enum, so our route does NOT pre-refuse an
    /// unknown name and the fork answers the 400 instead. Passing values from
    /// ``SchedulingWebhookEvent/rawValue`` is the way to stay on the safe side of
    /// that.
    func updateWebhook(
        workspaceId: String,
        webhookId: String,
        events: [String]? = nil,
        fields: [String]? = nil
    ) async throws -> SchedulingNoContent {
        try await perform(
            .webhooksPatch,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(webhookId)),
                ("events", events.map { JSONValue.array($0.map(JSONValue.string)) }),
                ("fields", fields.map { JSONValue.array($0.map(JSONValue.string)) }),
            ]),
            as: SchedulingNoContent.self
        )
    }

    /// `webhooks.delete`. ⚠️ Answers nothing.
    func deleteWebhook(workspaceId: String, webhookId: String) async throws -> SchedulingNoContent {
        try await perform(
            .webhooksDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(webhookId))]),
            as: SchedulingNoContent.self
        )
    }

    /// `webhooks.deliveries` — the attempt log for one webhook.
    ///
    /// ⛔ A `failed` ROW WITH NO ``SchedulingWebhookDelivery/responseStatus`` MEANS
    /// NOBODY ANSWERED, which is a different fact from a rejection and the only
    /// way the row can say so. There is no error text anywhere to show.
    func webhookDeliveries(
        workspaceId: String,
        webhookId: String
    ) async throws -> [SchedulingWebhookDelivery] {
        try await perform(
            .webhooksDeliveries,
            workspaceId: workspaceId,
            params: .object([("id", .string(webhookId))]),
            as: SchedulingItems<SchedulingWebhookDelivery>.self
        ).items
    }
}
