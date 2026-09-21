import Foundation

public extension TypedEndpoints {
    /// The two routes that make the persona form editable.
    ///
    /// ⛔ BOTH ARE FIXTURE-GATED. `district-persona-options.json` and
    /// `district-persona-preview-token.json` are shared corpus files, gated in
    /// `ImplementedFixtures` against these DTOs rather than skip-listed in
    /// `ContractManifest.unimplemented`.
    ///
    /// ⚠️ NEITHER ANSWER IS ADOPTED WHOLE BY A SCREEN, AND THEY FAIL DIFFERENTLY.
    /// `personaOptions` is a catalogue: a decode failure must leave the form
    /// READ-ONLY rather than fall back to a hardcoded list, because a hardcoded
    /// list is the drifting second catalogue the route exists to retire.
    /// `personaPreviewToken` is a credential: a decode failure is simply a preview
    /// that does not start, and there is nothing to degrade to.
    ///
    /// ⚠️ BOTH AFFIRM `success`. Unlike the scheduling pair next door, both bodies
    /// carry the flag, so ``ResponseEnvelope/affirm(_:_:_:)`` applies — and it
    /// matters on the options read in particular, whose failure body is
    /// `{success:false,error}` with no catalogues at all.
    static let persona: Set<EndpointID> = [
        .personaOptions,
        .personaPreviewToken,
    ]
}
