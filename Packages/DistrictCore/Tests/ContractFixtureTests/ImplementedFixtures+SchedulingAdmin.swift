import DistrictModel
import Foundation

// The scheduling admin RPC's ENVELOPE, in a file of its own.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the
// same reason `ImplementedFixtures+MessageThread.swift` was.
// SwiftLint's `file_length` warning is an ERROR under `--strict`, so one line added
// inline reds the LINT job rather than the gate — a failure a long way from the
// change that caused it.

extension ImplementedFixtures {
    // MARK: - The scheduling admin envelope

    /// ⛔ THIS GROUP GATES THE TRANSPORT ONLY — the wrapper every op's answer
    /// arrives in and the three refusal shapes. The row DTOs those wrappers carry
    /// are gated in the `+SchedulingA`, `+SchedulingB` and `+SchedulingC` groups.
    /// Gating a payload fixture against a type that does not exist is how a DTO
    /// that nothing decodes gets written (the failure the ⚠️ at the top of
    /// ``UntypedEndpoints`` describes).
    ///
    /// ⛔ THE FAILURE FIXTURE IS A **200** AND THAT IS THE WHOLE REASON IT EXISTS.
    /// `{ok:false, failure:"rejected", status:403}` is what the route answers when
    /// the SCHEDULER refuses — HTTP 200, because the request reached Distronode,
    /// was authorised, cleared the op's role bar and validated. A client that read
    /// `res.ok` alone reports every scheduler outage as a success, which is the one
    /// mistake this corpus can pin and no route-level test would.
    /// ⚠️ Its `failure` is `rejected`, which maps to the client's `unknown` rather
    /// than to `unavailable`. That is the platform client's generic kind and the
    /// fixture's job is the SHAPE; the two `unavailable` spellings and `slot_taken`
    /// are exercised in `SchedulingAdminRepositoryTests` against inline bytes.
    ///
    /// ⚠️ TWO FIXTURES SHARE ``SchedulingAdminErrorBody`` AND ARE STILL PINNED
    /// SEPARATELY, which is the same call `district-device-register.json` and
    /// `-unregister.json` make on ``SuccessResponse``: one carries `fields` and one
    /// does not, so the pair proves the optional in both directions and the day
    /// either refusal grows a key, that one fails on its own.
    ///
    /// ⛔ `district-scheduling-no-content.json` IS `{"ok":true,"data":{"ok":true}}`
    /// — AN OUTER FLAG AND AN INNER ONE — AND MODELLING THE SIXTEEN NO-BODY OPS AS
    /// AN EMPTY BODY FAILS AGAINST IT. The catalog's `NO_CONTENT` rewrites a 204
    /// into an object before it leaves the route. This is also the only fixture
    /// here that exercises ``SchedulingAdminSuccess``'s `ok` field: the gate
    /// compares KEY SETS after a re-encode, so a success envelope that modelled
    /// only `data` would be reported rather than quietly dropping the flag.
    ///
    /// ⚠️ NONE OF THE FOUR CARRIES AN EXPLICIT NULL, so ``AllowedExplicitNulls``
    /// and ``ContractManifest/expectedAllowedNullPaths`` do not move. Checked
    /// against the fixture bytes, not inferred from the types — every optional
    /// here is ABSENT on the bodies that do not have it.
    static var schedulingAdmin: [ImplementedFixture] {
        [
            gate("district-scheduling-admin-failure.json", SchedulingAdminEnvelopeHead.self),
            gate("district-scheduling-admin-invalid-params.json", SchedulingAdminErrorBody.self),
            gate("district-scheduling-admin-not-ready.json", SchedulingAdminErrorBody.self),
            gate("district-scheduling-no-content.json", SchedulingAdminSuccess<SchedulingNoContent>.self),
        ]
    }
}
