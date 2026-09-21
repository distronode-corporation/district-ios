import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The persona repository: the catalogue read, the eleven-field save, the billed
/// preview, and the wholesale routing-rule replacement.
///
/// ⚠️ EVERY BODY HERE IS INLINE RATHER THAN A CONTRACT FIXTURE, deliberately. The two
/// real fixtures are gated in `ContractFixtureTests`, which re-encodes and compares
/// key sets — a far stronger assertion about SHAPE than this file could make. What is
/// under test here is the envelope handling and, for the routing save, which rows
/// reach the wire.
final class WorkspacePersonaRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: .repositoryTest(transport))
    }

    private static let optionsBody = """
    {"success":true,"region":"eu","engines":[{"id":"deepgram-pipeline","label":"Deepgram — EU",\
    "inRegion":true,"responseLengths":[{"value":"concise","label":"Concise"}]}],\
    "languages":{"deepgram":[{"value":"en-US","label":"English"}],\
    "general":[{"value":"en-US","label":"English"}]},\
    "voices":[{"engine":"deepgram-pipeline","language":"en-US",\
    "groups":[{"label":"Feminine","options":[{"value":"aura-2-asteria-en","label":"Asteria"}]}]}],\
    "voiceStyles":[{"value":"en-GB-Studio-B","label":"Studio"}],\
    "defaults":{"voiceByEngine":{"deepgram-pipeline":"aura-2-asteria-en"},\
    "voiceByDeepgramLanguage":{"en-US":"aura-2-asteria-en"},\
    "responseLength":"concise","temperature":0.7}}
    """

    // MARK: - The catalogue read

    func testTheOptionsReadDecodesTheCatalogueAndItsRegion() async throws {
        let transport = RepositoryTransport(json: Self.optionsBody)
        let result = await repository(transport).personaOptions(workspaceId: "ws_1")
        let options = try XCTUnwrap(try? result.get())
        XCTAssertEqual(options.region, "eu")
        XCTAssertEqual(options.engines.map(\.id), ["deepgram-pipeline"])
        XCTAssertEqual(options.defaults.temperature, 0.7)
        XCTAssertEqual(
            transport.requestedURLs,
            ["https://www.distronode.com/api/district/workspace/persona/options?workspaceId=ws_1"]
        )
    }

    /// ⛔ A 200 CARRYING `success:false` IS A FAILURE, NOT AN EMPTY CATALOGUE. This
    /// surface answers exactly that whenever a handler falls into its own error branch
    /// after the headers are written, and an empty catalogue reaching a form would
    /// leave every picker blank — which is indistinguishable from a workspace with one
    /// engine and no voices.
    func testAnAffirmedFailureIsAFailureRatherThanAnEmptyCatalogue() async {
        let transport = RepositoryTransport(json: #"{"success":false,"region":"us","engines":[],"# +
            #""languages":{"deepgram":[],"general":[]},"voices":[],"voiceStyles":[],"# +
            #""defaults":{"voiceByEngine":{},"voiceByDeepgramLanguage":{},"# +
            #""responseLength":"concise","temperature":0.7}}"#)
        let result = await repository(transport).personaOptions(workspaceId: "ws_1")
        XCTAssertNil(try? result.get())
    }

    /// ⚠️ A 403 IS THE VIEWER EXCLUSION, which this surface applies to the READ as
    /// well as the writes — unusual here and deliberate.
    func testAForbiddenReadIsReportedRatherThanDegraded() async {
        let transport = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)
        let result = await repository(transport).personaOptions(workspaceId: "ws_1")
        guard case let .failure(error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .http(status: 403, message: "Forbidden"))
    }

    // MARK: - The save

    /// ⛔ ONE DIRTY FIELD, ONE KEY ON THE WIRE. See the ⛔ on
    /// ``WorkspaceRepository/savePersona`` (the twelve-field overload; see its declaration for the
    /// full label list).
    func testTheSaveCarriesOnlyTheFieldsItWasGiven() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        _ = await repository(transport).savePersona(
            workspaceId: "ws_1",
            voice: "aura-2-luna-en",
            modelId: "deepgram-pipeline",
            responseLength: "balanced"
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"modelId":"deepgram-pipeline","responseLength":"balanced","voice":"aura-2-luna-en","# +
                    #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ 403 `dgi_requires_studio` IS AN ENTITLEMENT REFUSAL, not a server fault, and
    /// it reaches the caller as one rather than as a generic failure.
    func testTheEnrichmentEntitlementRefusalIsSurfaced() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"Voice Studio required","code":"dgi_requires_studio"}"#,
            status: 403
        )
        let result = await repository(transport).savePersona(workspaceId: "ws_1", dgiEnabled: true)
        guard case let .failure(error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .http(status: 403, message: "Voice Studio required"))
    }

    // MARK: - The preview

    func testThePreviewTokenDecodesItsCredentialAndItsKey() async throws {
        let transport = RepositoryTransport(json: #"{"success":true,"token":"jwt","# +
            #""url":"wss://eu.example","roomName":"preview_ws_1_abc",""# +
            #"e2ee":{"key":"YfxKDUkaaGp2WrLLGHCHbe2nn5ArCWBd+x+k7EzDr/8="}}"#)
        let result = await repository(transport).previewToken(
            workspaceId: "ws_1",
            form: PersonaPreviewForm(name: "Ada", modelId: "deepgram-pipeline")
        )
        let credential = try XCTUnwrap(try? result.get())
        XCTAssertEqual(credential.token, "jwt")
        XCTAssertEqual(credential.url, "wss://eu.example")
        XCTAssertEqual(credential.roomName, "preview_ws_1_abc")
        // ⛔ THE PASSPHRASE IS CARRIED AS TEXT AND NEVER DECODED. 44 characters of
        // base64, handed to the SDK verbatim; decoding selects a different key
        // derivation and every track becomes undecryptable noise with no error.
        XCTAssertEqual(credential.e2ee?.key, "YfxKDUkaaGp2WrLLGHCHbe2nn5ArCWBd+x+k7EzDr/8=")
        XCTAssertEqual(credential.e2ee?.key.count, 44)
    }

    /// ⛔ THE UNSAVED FORM IS WHAT TRAVELS, NESTED UNDER `formData`. A flattened body
    /// is a 400 the route words as a missing workspace, which reads as a broken client.
    func testThePreviewSendsTheUnsavedFormNestedUnderFormData() async {
        let transport = RepositoryTransport(json: #"{"success":true,"token":"t","url":"u",""# +
            #"roomName":"preview_ws_1_abc","e2ee":{"key":"k"}}"#)
        _ = await repository(transport).previewToken(
            workspaceId: "ws_1",
            form: PersonaPreviewForm(greeting: "Try me", modelId: "deepgram-pipeline")
        )
        XCTAssertEqual(
            transport.bodies,
            [#"{"formData":{"greeting":"Try me","modelId":"deepgram-pipeline"},"workspaceId":"ws_1"}"#]
        )
        XCTAssertEqual(
            transport.requestedURLs,
            ["https://www.distronode.com/api/district/workspace/persona/preview-token"]
        )
    }

    /// ⚠️ 429 IS THE 10/MIN PER-WORKSPACE CEILING AND IS REPORTED, NOT RETRIED. Every
    /// token is a billed session; a repository that retried would spend the ceiling.
    func testAThrottledPreviewIsReportedRatherThanRetried() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"Too many persona previews for this workspace."}"#,
            status: 429
        )
        let result = await repository(transport).previewToken(
            workspaceId: "ws_1",
            form: PersonaPreviewForm()
        )
        XCTAssertNil(try? result.get())
        XCTAssertEqual(transport.bodies.count, 1, "a billed route is attempted exactly once")
    }

    // MARK: - The routing rules

    /// ⛔ THE ROW THIS BUILD CANNOT READ GOES BACK UNTOUCHED, ALONGSIDE THE ONE IT
    /// EDITED. Dropping it would delete a rule the agent is evaluating today, answered
    /// 200; rewriting it would stamp six invented keys onto four it does not
    /// understand.
    func testAWholesaleSaveCarriesUnrecognisedRulesThroughUnchanged() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let legacy = RoutingRuleDraft(id: 0, row: .object([
            "id": .string("rule-legacy"),
            "match": .string("support"),
            "target": .null,
        ]))
        var edited = RoutingRuleDraft(id: 1, row: .object([
            "field": .string("industry"),
            "operator": .string("contains"),
            "value": .string("tech"),
            "voice": .string("Puck"),
            "instruction": .string(""),
            "model": .string(""),
        ]))
        edited.value = "finance"

        _ = await repository(transport).saveRoutingRules(workspaceId: "ws_1", rules: [legacy, edited])

        XCTAssertEqual(
            transport.bodies,
            [
                #"{"routingRules":[{"id":"rule-legacy","match":"support","target":null},"# +
                    #"{"field":"industry","instruction":"","model":"","operator":"contains","# +
                    #""value":"finance","voice":"Puck"}],"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ AN ADDED ROW NOBODY FILLED IN NEVER REACHES THE WIRE, so the Add button
    /// pressed and abandoned does not grow the stored array.
    func testAnAbandonedAddedRowIsDroppedBeforeSending() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        _ = await repository(transport).saveRoutingRules(
            workspaceId: "ws_1",
            rules: [RoutingRuleDraft.added(id: 0)]
        )
        XCTAssertEqual(transport.bodies, [#"{"routingRules":[],"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ AN ADDED ROW THIS BUILD CANNOT CLASSIFY IS STILL SENT IN FULL. It has no
    /// stored form to carry, so it goes out as its six keys rather than being dropped:
    /// the operator typed into it, and a row that vanished on save would be a deletion
    /// nobody asked for.
    func testAnAddedRowWithAnUnrecognisedFieldIsRenderedRatherThanDropped() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        var added = RoutingRuleDraft.added(id: 0)
        added.field = "postcode"
        added.value = "M5V"
        XCTAssertFalse(added.isRecognised)
        XCTAssertNil(added.carriedUnchanged())

        _ = await repository(transport).saveRoutingRules(workspaceId: "ws_1", rules: [added])

        XCTAssertEqual(
            transport.bodies,
            [
                #"{"routingRules":[{"field":"postcode","instruction":"","model":"","operator":"contains","# +
                    #""value":"M5V","voice":"Puck"}],"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ AN EMPTY ARRAY IS SENT WHEN THAT IS WHAT THE CALLER MEANT, AND IT DELETES
    /// EVERY RULE. The route only refuses an OMITTED array. The confirmation belongs
    /// on the screen; this layer does not second-guess a request it was given.
    func testAnEmptyRuleSetIsSentRatherThanRefused() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let result = await repository(transport).saveRoutingRules(workspaceId: "ws_1", rules: [])
        XCTAssertNotNil(try? result.get())
        XCTAssertEqual(transport.bodies, [#"{"routingRules":[],"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ A **400 HERE IS OFTEN A REAL, SPECIFIC REFUSAL** — a workspace that restricts
    /// voices or models rejects a rule naming one, BY NAME — so the sentence is
    /// carried verbatim rather than replaced with a generic one. ⚠️ Its body carries no
    /// `success` key at all, unlike its siblings; that costs nothing because the status
    /// mapping runs first.
    func testAVoiceRefusalKeepsTheServersOwnSentence() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Invalid voice identifier: Puck"}"#,
            status: 400
        )
        let result = await repository(transport).saveRoutingRules(
            workspaceId: "ws_1",
            rules: [
                RoutingRuleDraft(id: 0, row: .object([
                    "field": .string("industry"),
                    "operator": .string("contains"),
                    "value": .string("tech"),
                    "voice": .string("Puck"),
                ])),
            ]
        )
        guard case let .failure(error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error.message, "Invalid voice identifier: Puck")
    }
}
