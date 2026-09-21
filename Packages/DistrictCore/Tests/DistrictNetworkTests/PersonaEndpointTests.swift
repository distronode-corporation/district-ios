@testable import DistrictNetwork
import Foundation
import XCTest

/// What the persona save and the persona preview actually put on the wire.
///
/// ⛔ BODY-LEVEL RATHER THAN URL-LEVEL, WHICH IS WHY IT IS NOT JUST MORE ROWS IN
/// `EndpointTable`. That table asserts one canonical body per endpoint; the property
/// under test here is the DROPPING — `savePersona` grew from four fields to eleven,
/// and on a route that merges per field (`x !== undefined ? x : existing`) the
/// difference between an absent key and a sent one is the difference between
/// preserving the operator's engine choice and overwriting it with whatever this
/// client happened to hold. A single canonical row cannot pin that.
final class PersonaEndpointTests: XCTestCase {
    private func body(_ descriptor: ApiRequestDescriptor) throws -> String {
        guard case let .json(value) = descriptor.body else {
            XCTFail("expected a JSON body")
            return ""
        }
        return try String(bytes: JSONWire.encode(value), encoding: .utf8) ?? ""
    }

    // MARK: - savePersona

    /// ⛔ THE WHOLE CONTRACT OF THIS FORM IN ONE ASSERTION. Eleven fields are
    /// available and a save that touched one names one; every other key is ABSENT,
    /// so the server preserves the stored value. A body carrying eleven keys would
    /// overwrite the engine, the voice, the tuning and the answer length with this
    /// client's idea of them — answered 200.
    func testASaveThatChangedOneFieldSendsOneFieldAndTheWorkspace() throws {
        let descriptor = DistrictEndpoints.savePersona(workspaceId: "ws_1", greeting: "Hello there")
        XCTAssertEqual(try body(descriptor), #"{"greeting":"Hello there","workspaceId":"ws_1"}"#)
    }

    /// ⛔ AN EMPTY STRING REACHES THE WIRE AND CLEARS THE FIELD; nil DROPS THE KEY AND
    /// PRESERVES IT. Mapping blank to nil anywhere on this path would make a cleared
    /// greeting silently un-clearable, with a success banner over it.
    func testAnEmptyStringIsSentAndNilIsNot() throws {
        let cleared = DistrictEndpoints.savePersona(workspaceId: "ws_1", greeting: "", personality: nil)
        XCTAssertEqual(try body(cleared), #"{"greeting":"","workspaceId":"ws_1"}"#)
    }

    /// ⛔ `responseLength` TRAVELS WITH `modelId` OR IT IS DISCARDED SERVER-SIDE. The
    /// route stores the level under `aiPersona.responseLength[modelId]` and refuses to
    /// guess at the stored engine, so a body with the level and no engine writes
    /// nothing and answers 200. This pins that both keys CAN be carried together;
    /// `PersonaModel` is what guarantees they always are.
    func testTheAnswerLengthAndTheEngineCanRideOneRequest() throws {
        let descriptor = DistrictEndpoints.savePersona(
            workspaceId: "ws_1",
            modelId: "deepgram-pipeline",
            responseLength: "balanced"
        )
        XCTAssertEqual(
            try body(descriptor),
            #"{"modelId":"deepgram-pipeline","responseLength":"balanced","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ A JSON NUMBER, NOT A STRING. The route guards with
    /// `typeof temperature === "number"` and IGNORES anything else — so a quoted value
    /// would leave the stored creativity exactly as it was and still answer 200.
    /// ⚠️ 0.5 rather than 0.7 because this compares bytes; see the same note in
    /// `EndpointTable+Persona.swift`.
    func testTemperatureIsANumberAndNotAString() throws {
        let descriptor = DistrictEndpoints.savePersona(workspaceId: "ws_1", temperature: 0.5)
        XCTAssertEqual(try body(descriptor), #"{"temperature":0.5,"workspaceId":"ws_1"}"#)
    }

    /// ⚠️ SAME IGNORE-DON'T-COERCE CONTRACT ON THE SPEND TOGGLE: the route reads
    /// `typeof preemptiveTts === "boolean"`, so `false` is a real instruction and must
    /// not be confused with an absent key.
    func testTheSpeculationToggleSendsAFalseRatherThanDroppingIt() throws {
        let descriptor = DistrictEndpoints.savePersona(workspaceId: "ws_1", preemptiveTts: false)
        XCTAssertEqual(try body(descriptor), #"{"preemptiveTts":false,"workspaceId":"ws_1"}"#)
    }

    /// ⛔ ALL ELEVEN ARE EXPRESSIBLE, AND THE FOUR AVATAR FIELDS ARE NOT. There is no
    /// `videoEnabled`, `replicaId`, `videoModelId` or `videoVoice` parameter to pass —
    /// the absence is structural rather than a convention, which is what App Store
    /// Review Guideline 3.1.3(b) and the billable Tavus stream both ask for.
    func testTheWholeEditableSurfaceIsElevenKeysAndCarriesNoAvatarField() throws {
        let descriptor = DistrictEndpoints.savePersona(
            workspaceId: "ws_1",
            name: "Ada",
            greeting: "Hi",
            personality: "Warm",
            dgiEnabled: true,
            voice: "aura-2-asteria-en",
            language: "en-US",
            modelId: "deepgram-pipeline",
            responseLength: "concise",
            temperature: 0.5,
            voiceStyle: "en-GB-Studio-B",
            preemptiveTts: true
        )
        let encoded = try body(descriptor)
        for absent in ["videoEnabled", "replicaId", "videoModelId", "videoVoice", "personaId"] {
            XCTAssertFalse(encoded.contains(absent), "\(absent) must not be expressible from this client")
        }
        guard case let .json(value) = descriptor.body, case let .object(fields) = value else {
            return XCTFail("expected a JSON object body")
        }
        XCTAssertEqual(fields.count, 12, "eleven fields plus the workspace")
    }

    // MARK: - The preview

    /// ⛔ THE BODY NESTS UNDER `formData`. The route reads `{ workspaceId, formData }`
    /// and answers 400 "Missing workspaceId or formData" for a flattened body, which
    /// reads as a broken client rather than as a shape mismatch.
    func testThePreviewNestsTheFormAndKeepsTheWorkspaceAtTheTop() throws {
        let descriptor = DistrictEndpoints.previewToken(
            workspaceId: "ws_1",
            form: PersonaPreviewForm(name: "Ada", modelId: "deepgram-pipeline")
        )
        XCTAssertEqual(
            try body(descriptor),
            #"{"formData":{"modelId":"deepgram-pipeline","name":"Ada"},"workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ AN EMPTY FORM IS AN EMPTY OBJECT, NOT A DROPPED KEY. `formData` is required
    /// by the route; only the fields INSIDE it are droppable, and an absent field
    /// there leaves the agent on its own per-field fallback for the session.
    func testAnEmptyPreviewFormStillSendsTheKeyTheRouteRequires() throws {
        let descriptor = DistrictEndpoints.previewToken(workspaceId: "ws_1", form: PersonaPreviewForm())
        XCTAssertEqual(try body(descriptor), #"{"formData":{},"workspaceId":"ws_1"}"#)
    }

    /// ⛔ THE FORM CARRIES EXACTLY THE TEN KEYS THE SERVER'S SANITISER READS. A key it
    /// does not read is inert TODAY, which is how a form field becomes an agent input
    /// later without anyone deciding — and `dgiEnabled` in particular is absent
    /// because a preview does not enrich anybody.
    func testTheFormCarriesTheSanitisersTenKeysAndNoOthers() {
        let descriptor = DistrictEndpoints.previewToken(
            workspaceId: "ws_1",
            form: PersonaPreviewForm(
                name: "Ada",
                greeting: "Hi",
                personality: "Warm",
                voice: "aura-2-asteria-en",
                language: "en-US",
                modelId: "deepgram-pipeline",
                responseLength: "concise",
                temperature: 0.5,
                voiceStyle: "en-GB-Studio-B",
                preemptiveTts: true
            )
        )
        guard case let .json(value) = descriptor.body, case let .object(fields) = value,
              case let .object(form)? = fields["formData"]
        else {
            return XCTFail("expected a nested formData object")
        }
        XCTAssertEqual(
            Set(form.keys),
            [
                "name", "greeting", "personality", "voice", "language",
                "modelId", "responseLength", "temperature", "voiceStyle", "preemptiveTts",
            ]
        )
        XCTAssertFalse(form.keys.contains("dgiEnabled"))
    }
}
