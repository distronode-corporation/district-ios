import DistrictModel
import Foundation

// The persona form's vocabularies and the preview credential, in a file of their own.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the
// same reason `ImplementedFixtures+MessageThread.swift` and
// `+SchedulingAdmin.swift` were. SwiftLint's `file_length` warning is an ERROR under
// `--strict`, so one line added inline reds the LINT job rather than the gate — a
// failure a long way from the change that caused it.

extension ImplementedFixtures {
    // MARK: - The persona form's vocabularies and its preview

    /// ⛔ TWO FIXTURES GATED TOGETHER WITH THEIR TYPES, WHICH IS THE ONLY WAY A NAME
    /// IS SUPPOSED TO LEAVE `ContractManifest.unimplemented`. Gating either one
    /// earlier would have meant inventing the type to gate it against — the "a DTO
    /// that nothing decodes is a fixture test, not a client" failure the ⚠️ at the
    /// top of ``UntypedEndpoints`` describes. They are gated alongside
    /// `PersonaOptionsResponse`, `PersonaPreviewTokenResponse`, both descriptors,
    /// both repository methods and the screen that reads them.
    /// ⛔ Gating them does not move `ContractManifest.expectedFixtureCount`, which is
    /// asserted EXACTLY against the files on disk.
    ///
    /// ⛔ THE OPTIONS FIXTURE IS THE LARGEST BODY IN THIS CORPUS AND THE GATE IS WHAT
    /// MAKES ITS SIZE SAFE. Seven engines, two language lists, THIRTY-SIX engine ×
    /// language voice catalogues, eight voice styles and four defaults — nearly three
    /// thousand lines, in which one unmodelled key would be invisible to any
    /// hand-written assertion. `StrictDecodeVerifier` re-encodes and compares key sets
    /// per path, so a field the server adds fails HERE rather than being silently
    /// dropped on a phone.
    ///
    /// ⚠️ THAT IS ALSO WHY THE VOICE LISTS ARE NOT ASSERTED BY CONTENT ANYWHERE. The
    /// catalogue is the server's and changes without a version bump; pinning
    /// `aura-2-asteria-en` in Swift would recreate the second catalogue the whole
    /// route exists to retire. What this client pins is the SHAPE, and
    /// `PersonaOptionsLookupTests` pins the RULES that read it.
    ///
    /// ⛔ THE PREVIEW TOKEN'S `e2ee` IS PRESENT ON THIS FIXTURE AND OPTIONAL IN THE
    /// DTO, AND THE ASYMMETRY IS DELIBERATE RATHER THAN A SECOND BODY SHAPE. A
    /// `preview_*` room is always encrypted — browser-to-agent, no SIP leg, no avatar
    /// — so the Optional is a refusal to crash on drift, not a documented branch. It
    /// shares ``E2EEInfo`` with `district-room-token.json`, which carries the
    /// never-base64-decode rule in full; the two fixtures gate the same type against
    /// two routes, so the day either grows a key exactly one of them fails.
    ///
    /// ⚠️ NEITHER FIXTURE CARRIES AN EXPLICIT NULL, so ``AllowedExplicitNulls`` and
    /// ``ContractManifest/expectedAllowedNullPaths`` do not move. Checked against the
    /// bytes rather than inferred from the types: every Optional here is either
    /// present or, in the preview's case, would be ABSENT rather than null.
    static var persona: [ImplementedFixture] {
        [
            gate("district-persona-options.json", PersonaOptionsResponse.self),
            gate("district-persona-preview-token.json", PersonaPreviewTokenResponse.self),
        ]
    }
}
