import Foundation

/// Workspace settings and the knowledge base.
///
/// ⛔ THE READ IS NOT OPTIONAL BEFORE ANY OF THE THREE REPLACE-WHOLESALE WRITES.
/// `workspace/directory` (PATCH), `workspace/routing-rules` (POST) and
/// `workspace/tools` (PATCH) all REPLACE their stored value rather than merging
/// it. A form that opened empty and saved through one of them would not "save
/// nothing" — it would DELETE the transfer directory the voice agent routes live
/// callers through, or the agent's tool allowlist. The web never had to think
/// about this: its settings page is a server component that hydrates every form
/// from the row during render. A phone has no such prop, so
/// ``DistrictEndpoints/workspaceConfig(workspaceId:)`` IS that prop, fetched.
///
/// ⛔ ALL FIVE CONFIG CALLS EXCLUDE `viewer` SERVER-SIDE, INCLUDING THE READ —
/// unusual on this surface and not an oversight: the payload carries staff phone
/// numbers and the operator's own prompt. The entry point must be HIDDEN for a
/// viewer, not merely captioned.
public extension DistrictEndpoints {
    /// The workspace settings row, redacted.
    ///
    /// ⚠️ A PLAIN READ WITH NO SIDE EFFECTS AND NO VENDOR CALL, by design — it
    /// cannot itself be the reason a client fails open into an empty form.
    ///
    /// ⚠️ `messagingConfig` arrives already narrowed by `redactWorkspaceSecrets`
    /// and `twilioConfig` is not returned at all. Nothing needs re-redacting
    /// client-side.
    static func workspaceConfig(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .workspaceConfig,
            .get,
            DistrictPaths.workspaceConfig,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Save persona fields.
    ///
    /// ⛔ SEND ONLY WHAT THE OPERATOR CHANGED. The server merges per field
    /// (`x !== undefined ? x : existing`), so an omitted key is PRESERVED — and a
    /// client that posted its whole form state would overwrite the engine choice,
    /// the avatar settings and the tuning parameters with whatever it happened to
    /// hold. The nil-dropping in ``JSONValue/object(_:)`` is the mechanism by
    /// which "send only what changed" actually reaches the wire.
    ///
    /// ⛔ ANSWERS `{success:true}` AND NOTHING MORE — the updated config is NOT
    /// echoed, so a caller needing fresh state must re-read.
    ///
    /// ⛔ ELEVEN FIELDS, SEVEN OF THEM FROM SERVER-PUBLISHED VOCABULARIES. This route
    /// COERCES rather than rejects — an unrecognised `modelId` is rewritten to
    /// `deepgram-pipeline`, an unrecognised `voice` is stored verbatim and then
    /// replaced by the agent's own fallback, both with a 200 — so a free-text box on
    /// a phone would leave a workspace speaking in a voice nobody chose.
    /// ``personaOptions(workspaceId:)`` publishes the same catalogues the web form
    /// derives its pickers from, so every value sent here comes from a list the
    /// server itself produced rather than from a guess.
    ///
    /// ⛔ `responseLength` IS WRITTEN ONLY WHEN A VALID `modelId` ARRIVES IN THE
    /// SAME REQUEST, and that is the one coupling a caller cannot discover from a
    /// failure. The route stores it under `aiPersona.responseLength[modelId]`, so
    /// with no accepted engine id there is no key to write under — and rather than
    /// guessing at the stored one it writes nothing, answers 200, and the
    /// operator's choice vanishes. Send the two together or send neither.
    ///
    /// ⛔ THE AVATAR FIELDS ARE ABSENT AND THAT IS A DECISION, NOT AN OMISSION.
    /// `videoEnabled`, `replicaId`, `videoModelId` and `videoVoice` start a
    /// billable Tavus stream; App Store Review Guideline 3.1.3(b) and the ⛔ on
    /// ``AiPersona/videoEnabled`` point the same way. `personaId` is REGION-KEYED
    /// server-side (an EU workspace gets the disclosure PAL under the EU AI Act)
    /// and an explicit value still wins, which is precisely why nothing here sends
    /// one.
    ///
    /// ⚠️ EVERY FIELD DEFAULTS TO nil SO A CALLER NAMES ONLY WHAT IT SENDS, which
    /// is the dirty-field contract expressed in the signature rather than in a
    /// comment. It is also what keeps SwiftLint's `function_parameter_count` happy:
    /// the rule ignores defaulted parameters, so this counts as one.
    static func savePersona(
        workspaceId: String,
        name: String? = nil,
        greeting: String? = nil,
        personality: String? = nil,
        dgiEnabled: Bool? = nil,
        voice: String? = nil,
        language: String? = nil,
        modelId: String? = nil,
        responseLength: String? = nil,
        temperature: Double? = nil,
        voiceStyle: String? = nil,
        preemptiveTts: Bool? = nil
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .savePersona,
            .patch,
            DistrictPaths.workspacePersona,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("name", .optional(name)),
                ("greeting", .optional(greeting)),
                ("personality", .optional(personality)),
                ("dgiEnabled", dgiEnabled.map { JSONValue.bool($0) }),
                ("voice", .optional(voice)),
                ("language", .optional(language)),
                ("modelId", .optional(modelId)),
                ("responseLength", .optional(responseLength)),
                // ⚠️ A `Double`, AND THE ROUTE CLAMPS IT TO 0...1 RATHER THAN
                // REFUSING. It guards with `typeof temperature === "number"`, so an
                // integer-valued `1` encoded as `1` is still a number and still
                // accepted — unlike `appRingSeconds` next door, whose `.int()`
                // refuses a decimal point.
                ("temperature", temperature.map { JSONValue.number($0) }),
                ("voiceStyle", .optional(voiceStyle)),
                // ⚠️ IGNORE-DON'T-COERCE ON THE SERVER: a non-boolean leaves paid
                // speculative synthesis exactly as it was and still answers 200, so
                // a string here would not fail, it would silently do nothing.
                ("preemptiveTts", preemptiveTts.map { JSONValue.bool($0) }),
            ]))
        )
    }

    /// Save the agent's capability allowlist.
    ///
    /// ⛔ `allowedTools` IS WRITTEN WHOLESALE AND IS REQUIRED. Whatever list
    /// arrives becomes the stored one; a missing array is a 400 rather than a
    /// no-op. The caller's obligation is to send the list it LOADED with the
    /// operator's toggles applied — INCLUDING any id this client's catalog does
    /// not recognise, which is not hypothetical: `transfer_to_creator` was retired
    /// in 2026 and workspaces still store it.
    ///
    /// ⚠️ The parameter is non-optional precisely so the nil-drop cannot reach it.
    static func saveTools(workspaceId: String, allowedTools: [String]) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveTools,
            .patch,
            DistrictPaths.workspaceTools,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("allowedTools", .array(allowedTools.map { JSONValue.string($0) })),
            ]))
        )
    }

    /// Replace the call transfer directory.
    ///
    /// ⛔ THE MOST DESTRUCTIVE CALL IN THIS CLIENT, AND ITS FAILURE MODE IS A 200.
    /// The handler writes `callDirectory: (callDirectory || [])` — so an empty
    /// array, or a body that simply omits the key, WIPES every transfer target the
    /// voice agent can put a live caller through to, and answers `{success:true}`.
    /// There is no "save nothing" on this route.
    ///
    /// ⛔ AND THE ROWS MUST BE CARRIED WHOLE. The route's zod schema is
    /// `.passthrough()` and names only `name` and `phoneNumber`; the column is
    /// `Json` and holds whatever anyone ever wrote. That is why this takes
    /// ``JSONValue`` rows straight out of a loaded config rather than a typed
    /// model — a request rebuilt from one would strip the rest.
    static func saveDirectory(workspaceId: String, callDirectory: [JSONValue]) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveDirectory,
            .patch,
            DistrictPaths.workspaceDirectory,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("callDirectory", .array(callDirectory)),
            ]))
        )
    }

    /// Replace the dynamic-persona routing rules.
    ///
    /// ⛔ **POST, NOT PATCH**, and also wholesale. One difference from
    /// ``saveDirectory(workspaceId:callDirectory:)`` is worth knowing: this route
    /// requires `Array.isArray(routingRules)` and answers **400 "Invalid
    /// payload"** without it, so an omitted array is refused — but an EMPTY array
    /// is accepted and deletes every rule.
    ///
    /// ⚠️ CAN ANSWER **400 "Invalid voice identifier: X"** (or model) when the
    /// workspace restricts either vocabulary. That is a real refusal to surface
    /// verbatim: this client cannot see the allow-lists and deliberately does not
    /// pre-validate against a guess.
    static func saveRoutingRules(workspaceId: String, routingRules: [JSONValue]) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveRoutingRules,
            .post,
            DistrictPaths.workspaceRoutingRules,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("routingRules", .array(routingRules)),
            ]))
        )
    }

    /// The knowledge documents the agent answers from, newest first.
    ///
    /// ⚠️ THE KNOWLEDGE READS ADMIT `viewer` AND THE WRITES DO NOT — the OPPOSITE
    /// split from workspace config above, whose read excludes viewers too.
    /// Nothing on this surface is a staff phone number.
    static func knowledgeDocuments(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .knowledgeDocuments,
            .get,
            DistrictPaths.workspaceKnowledge,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Add one knowledge document.
    ///
    /// ⛔ BILLABLE PER CALL — one embedding run over however many chunks the
    /// content produced — rate limited at 20/min per WORKSPACE, and not
    /// idempotent. Nothing in this client may retry it.
    static func createDocument(
        workspaceId: String,
        title: String,
        content: String,
        sourceType: String?,
        sourceUrl: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createDocument,
            .post,
            DistrictPaths.workspaceKnowledge,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("title", .string(title)),
                ("content", .string(content)),
                ("sourceType", .optional(sourceType)),
                ("sourceUrl", .optional(sourceUrl)),
            ]))
        )
    }

    /// Delete one document; its chunks cascade.
    ///
    /// ⛔ **DELETE WITH QUERY PARAMETERS AND NO BODY**, and the id parameter is
    /// spelled **`documentId`** — not `id`, not `docId`. The route reads
    /// `searchParams.get("documentId")` and answers **400 "Missing documentId"**
    /// for anything else, which reads as a broken client rather than as a typo.
    ///
    /// ⚠️ ANSWERS `{success:true}` EVEN WHEN NOTHING MATCHED. The delete is a
    /// `deleteMany` scoped to `{id, workspaceId}` whose count is never read, so a
    /// cross-tenant id is indistinguishable from a real delete. Re-read the list.
    static func deleteDocument(workspaceId: String, documentId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteDocument,
            .delete,
            DistrictPaths.workspaceKnowledge,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("documentId", documentId),
            ]
        )
    }

    /// Where the agent answers questions FROM.
    ///
    /// ⚠️ `mode` IS A TOP-LEVEL KEY OF THE ENVELOPE, not a nested object.
    static func knowledgeMode(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .knowledgeMode,
            .get,
            DistrictPaths.workspaceKnowledgeMode,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Choose the knowledge source.
    ///
    /// ⛔ SWITCHING TO `linked` SENDS THIS WORKSPACE'S QUESTIONS TO ATLASSIAN. It
    /// is a data-residency change rather than a display preference, which is why
    /// the write excludes `viewer` while the read admits it, and why the UI must
    /// confirm it.
    ///
    /// ⚠️ AN UNKNOWN MODE IS A **400**, not a coerced value: the route validates
    /// with `z.enum(KB_MODES)`.
    ///
    /// ⚠️ THE WRITE ECHOES THE STORED CONFIG (`{success:true, ...config}`), unlike
    /// every workspace-settings save above, which answers a bare `{success:true}`.
    /// That echo is why this one write needs no re-read.
    static func saveKnowledgeMode(workspaceId: String, mode: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveKnowledgeMode,
            .patch,
            DistrictPaths.workspaceKnowledgeMode,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("mode", .string(mode)),
            ]))
        )
    }
}
