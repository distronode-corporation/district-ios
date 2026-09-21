import Foundation

public extension TypedEndpoints {
    /// The scheduling admin surface's two BODY routes.
    ///
    /// ⛔ TWO, NOT THREE. `schedulingAdminDownload` answers a **302** and is on
    /// ``RedirectEndpoints/all`` instead; the three lists are exhaustive and
    /// disjoint by test, so listing it in both would fail `EndpointSurfaceTests`'
    /// partition assertion rather than merely being redundant.
    ///
    /// ⛔ "TYPED" HERE MEANS SOMETHING SLIGHTLY DIFFERENT AND IT IS WORTH SAYING
    /// ONCE. Every other entry on these lists decodes ONE declared DTO.
    /// `schedulingAdmin` is a generic RPC: `SchedulingAdminRepository.perform` is
    /// parameterised on the response type and decodes whatever the CALLER names,
    /// so what is fixed at this layer is the ENVELOPE (`{ok:true,data}` /
    /// `{ok:false,failure,status}`) rather than the payload. That still satisfies
    /// the rule this list states — a repository decodes it, rather than handing
    /// back bytes.
    ///
    /// ⛔ AND NEITHER GOES THROUGH ``ApiClient/send(_:as:)``. A failed op is a
    /// **200** carrying `{ok:false}`, so the ordinary typed send would report a
    /// scheduler outage as a decode failure at best — and as success at worst, if
    /// the named type happened to tolerate the shape. Both use
    /// ``ApiClient/sendUnmapped(_:)``, like `workspace/list`'s degraded 503, and for
    /// the same reason: the error body IS the answer.
    ///
    /// ⚠️ THE ENVELOPE AND THE ROW DTOs ARE FIXTURE-GATED in the
    /// `ImplementedFixtures+Scheduling*` groups. ⛔ `ContractManifest.expectedFixtureCount`
    /// is asserted EXACTLY against the files on disk, so it moves only when files do.
    static let schedulingAdmin: Set<EndpointID> = [
        .schedulingAdmin,
        .schedulingAdminUpload,
    ]
}
