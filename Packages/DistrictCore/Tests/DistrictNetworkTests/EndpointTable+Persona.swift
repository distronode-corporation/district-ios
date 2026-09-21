@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    /// The two routes that make the persona form editable.
    ///
    /// ⛔ THE PATHS ARE WRITTEN OUT RATHER THAN BUILT FROM `DistrictPaths`, like
    /// every other row in this table, and this family earns that twice over. Both
    /// sit one segment below `workspace/persona`, which is **PATCH-only**: a GET on
    /// the parent is a 405 rather than a catalogue, and a preview posted to the
    /// parent is a persona SAVE. A table derived from the same constants the
    /// descriptors are built from would assert only that the code equals itself.
    ///
    /// ⛔ THE PREVIEW BODY NESTS UNDER `formData` AND THAT IS WHAT THIS ROW EXISTS
    /// TO PIN. Every other write on this surface is flat; this route reads
    /// `{ workspaceId, formData }` and answers **400 "Missing workspaceId or
    /// formData"** for a flattened body — a refusal that reads as a broken client
    /// rather than as a shape mismatch, and one no type checker catches.
    ///
    /// ⛔ AND THE PREVIEW ROW DROPS ITS nil FIELDS, WHICH IS THE OPPOSITE PIN FROM
    /// THE SCHEDULING RPC'S `params` ONE FUNCTION AWAY. There `{}` must SURVIVE
    /// because the route defaults an absent value; here an absent key leaves the
    /// agent on its own per-field fallback for the session, so the dropped-key shape
    /// is the contract. The body below carries five of the ten fields for exactly
    /// that reason.
    static func persona() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .personaOptions,
                DistrictEndpoints.personaOptions(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/persona/options?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .personaPreviewToken,
                DistrictEndpoints.previewToken(
                    workspaceId: "ws_1",
                    form: PersonaPreviewForm(
                        name: "Ada",
                        greeting: nil,
                        personality: nil,
                        voice: "aura-2-asteria-en",
                        language: "en-US",
                        modelId: "deepgram-pipeline",
                        responseLength: nil,
                        temperature: 0.5,
                        voiceStyle: nil,
                        preemptiveTts: true
                    )
                ),
                .post,
                "\(host)/api/district/workspace/persona/preview-token",
                // ⚠️ `0.5` RATHER THAN THE DEFAULT `0.7`, AND IT IS THE ASSERTION
                // THAT PICKED IT: this row compares BYTES, and 0.7 has no exact
                // binary representation, so its shortest round-tripping decimal is a
                // property of the encoder rather than of this file. 0.5 is exact. The
                // value's meaning is unaffected — the route guards with
                // `typeof temperature === "number"` and clamps to 0...1.
                .json(
                    #"{"formData":{"language":"en-US","modelId":"deepgram-pipeline","name":"Ada","#
                        + #""preemptiveTts":true,"temperature":0.5,"voice":"aura-2-asteria-en"},"#
                        + #""workspaceId":"ws_1"}"#
                )
            ),
        ]
    }
}
