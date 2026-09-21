import Foundation

public extension TypedEndpoints {
    /// Phone-number provisioning and the carrier accounts behind it.
    ///
    /// ⛔ AND `workspace/numbers/purchase` IS NOT ON THIS LIST OR ANY OTHER, WHICH IS
    /// THE ONE ABSENCE A READER WILL TRY TO CLOSE. It charges a setup fee AND opens a
    /// recurring monthly charge for a service consumed inside the app: App Store Review
    /// Guideline 3.1.1, an in-app purchase or nothing. It has no ``EndpointID`` case, so
    /// it cannot be classified, and since ``ApiRequestDescriptor``'s initialiser is
    /// internal it is UNCONSTRUCTIBLE from outside `DistrictNetwork` rather than merely
    /// unmodelled. ⛔ 3.1.1 covers STEERING too, so there is no link to the web
    /// marketplace either. `EndpointSurfaceTests` pins both halves, the same mechanism
    /// that holds out `calls/outbound` for an entirely different reason.
    ///
    /// ⛔ THE MARKETPLACE COMMENT IN `EndpointClassification.swift` SAYS "read only",
    /// AND IT DESCRIBES `searchNumbers` AND `ownedNumbers` ONLY, not this family. Read
    /// the two together.
    ///
    /// ⛔ TWO OF THEM MUST NOT AFFIRM AN ENVELOPE, AND ONLY ONE OF THE TWO IS OBVIOUS.
    /// ``providerStatus`` sends **no `success` flag at all** — like the scheduling
    /// pair, `stripeBilling` and `meetings` — so
    /// `ResponseEnvelope.affirm` there would look for a key that does not exist and fail
    /// every response. ⚠️ And ``configureNumber`` sends one on SUCCESS but writes its
    /// failures as a bare `{error: …}` with no `success: false`, so the affirm on that
    /// one is real and is doing nothing on the failure path. Typed here means a
    /// repository decodes a DTO, which for these two also means knowing which envelope
    /// they do and do not carry.
    ///
    /// ⚠️ SIXTEEN FOR TWELVE BECAUSE FOUR PATHS CARRY TWO VERBS EACH:
    /// `numbers/registrations` is GET + POST, `numbers/registrations/documents` is POST +
    /// DELETE, `workspace/sip` is GET + POST and `workspace/verify` is GET + POST. The
    /// same "a path is not an endpoint" arithmetic as the desk family's nine for seven.
    ///
    /// ⚠️ AND TWO OF THE SIXTEEN HAVE NO STATUS READ ANYWHERE ON THE SERVER, which is a
    /// fact about the API rather than about this port. ``submitA2PRegistration`` and
    /// ``submitTollFreeVerification`` are POST-only: their responses are the only report
    /// either flow will ever produce, so a screen ADOPTS them and cannot re-read. That is
    /// unusual on a surface where almost every write answers a bare `{success:true}` and
    /// the truth is read back.
    ///
    /// ⚠️ ALL SIXTEEN HAVE **NO CONTRACT FIXTURE**, which is a property of the corpus
    /// rather than a lowered bar: the shared corpus mirrors the Android client and that
    /// client has no provisioning surface.
    /// ⛔ SO `ContractManifest.expectedFixtureCount` MUST NOT MOVE FOR THEM. It is
    /// asserted EXACTLY against the files on disk and nothing is on disk; bumping it
    /// to "account for" these would red the fixture suite. What pins the shapes is the
    /// route source, quoted per DTO, plus `NumberProvisioningRepositoryTests` and
    /// `CarrierAccountRepositoryTests`.
    ///
    /// ⚠️ ITS OWN FILE RATHER THAN SIXTEEN MORE LINES IN `EndpointClassification.swift`,
    /// which is a lint ceiling and not a taxonomy: that file is at SwiftLint's 500-line
    /// limit and the commentary on those lists is the point of them. Same cut
    /// ``TypedEndpoints/desk`` made. ⛔ A family declared here and not unioned into
    /// ``TypedEndpoints/all`` fails `EndpointSurfaceTests`' partition assertion rather
    /// than defaulting to "raw", which is what keeps the split honest.
    static let numbers: Set<EndpointID> = [
        // ── Which carriers are connected ────────────────────────────────────────
        // ⛔ NO `success` FLAG. See the ⛔ on this list.
        .providerStatus,
        // ── The regulatory paperwork ────────────────────────────────────────────
        // ⛔ `numberRequirements` ADMITS `viewer` and the other five do not: it is
        // reference data about a COUNTRY rather than anything about the workspace, so
        // someone evaluating whether we can serve their market does not need write
        // access to find out. Everything else here carries a customer's filing status,
        // their rejection reasons, or their identity documents.
        .numberRequirements,
        .numberRegistrations,
        .createNumberRegistration,
        .uploadRegistrationDocument,
        .deleteRegistrationDocument,
        .submitNumberRegistration,
        // ── The two things that can be done to a number the workspace holds ─────
        // ⛔ `configureNumber` LANDS ON THE SHARED ``SuccessResponse``, like the
        // workspace-settings writes; `releaseNumber` gets its own type for one reason,
        // and it is the sharpest shape in this family: a **200 may carry `warnings`**,
        // which does NOT mean a partial release. The number is gone; a cleanup step
        // after the irreversible part did not finish, and one of those steps is ending
        // the monthly charge. A client that decoded this as `SuccessResponse` would
        // drop the array and leave an operator believing they had stopped a charge
        // they had not.
        .configureNumber,
        .releaseNumber,
        // ── Carrier accounts ───────────────────────────────────────────────────
        // ⛔ THE FIRST TWO HAVE NO STATUS READ ANYWHERE. See the ⚠️ on this list.
        .submitA2PRegistration,
        .submitTollFreeVerification,
        // ⛔ `sipTrunks` READS A LIST THIS CLIENT CANNOT SHORTEN: there is no DELETE on
        // that path, so a trunk created here cannot be taken down and its $25/month
        // billing item keeps standing.
        .sipTrunks,
        .createSipTrunk,
        // ⚠️ BOTH VERBS LAND ON ONE TYPE, ``VerifyServiceResponse``, because the GET and
        // both POST branches answer the same three keys — with `verifyServiceSid` an
        // explicit null on the read and an ABSENT key on the disable reply. Two
        // endpoints, one type, and the shapes agree only because both are Optional.
        .verifyService,
        .setVerifyServiceEnabled,
        // ⛔ BILLABLE PER CALL, ON A GET, ADMITTING `viewer`. Being on this list means a
        // repository decodes it, not that it is cheap — the same distinction
        // `testMessagingCredentials` carries, and here the cost is the carrier's rather
        // than a third party's.
        .lookupNumber,
    ]
}
