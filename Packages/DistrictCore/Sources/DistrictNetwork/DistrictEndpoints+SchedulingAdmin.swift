import Foundation

/// The scheduling admin surface: one RPC, one image upload, one recording
/// download.
///
/// ⛔ THREE DESCRIPTORS FOR NINE SCREENS, AND THE RATIO IS THE POINT. Every read
/// and every write the native admin performs goes through ``schedulingAdmin``
/// under an `op` NAME from ``SchedulingAdminOp``, so the set of scheduler routes
/// this client can address is exactly the server's catalog and cannot be widened
/// from here. The other two exist only because the RPC physically cannot carry
/// their payloads: an image cannot travel through a zod-validated params object
/// without a base64 inflation on both sides of a hop that already has a 5 MiB
/// ceiling, and a recording is a 302 to a presigned object the server refuses to
/// proxy.
///
/// ⛔ THESE ARE WORKSPACE-SCOPED MEMBER ROUTES on the session bearer:
/// `requireWorkspaceRole` with every District role admitted and the op's own
/// `minRole` as the second gate.
public extension DistrictEndpoints {
    /// Run one catalogued operation as the signed-in member.
    ///
    /// ⛔ `params` IS SENT AS GIVEN, PATH KEYS INCLUDED, AND TRIMMING IT HERE
    /// BREAKS THE REQUEST. The catalog's `pathKeys` strip happens SERVER-side
    /// inside `schedulerAdminRequest`, after `op.params` has validated the body —
    /// so a client that helpfully removed `slug` before sending would fail that
    /// schema for a missing required field and get a **400 `invalid_params`**
    /// naming the very key it was being clever about. The web dashboard's admin
    /// fetch helper records the same rule for the browser half; both clients pass the object
    /// through untouched.
    ///
    /// ⛔ A FAILED OP IS A **200**. `failureResponse` answers
    /// `{ok:false, failure, status}` at HTTP 200 on purpose — the request reached
    /// us and the SCHEDULER is what refused — so this descriptor must never be
    /// sent through ``ApiClient/send(_:as:)``, whose decode would either fail or,
    /// worse, succeed against a lenient type and report an outage as data. See
    /// ``ApiClient/sendUnmapped(_:)`` and `SchedulingAdminRepository`.
    ///
    /// ⚠️ WRITES ARE BUDGETED AND READS ARE NOT, at 120 per workspace per hour
    /// with a separate 30-per-MEMBER bucket for the viewer-level `me.*` and
    /// `calendar.*` writes. ``SchedulingAdminOp/isWrite`` is how a caller knows
    /// which side of that it is on before it decides to batch or retry; the
    /// refusal itself is a 429 and says nothing about which bucket ran out.
    static func schedulingAdmin(
        workspaceId: String,
        op: SchedulingAdminOp,
        params: JSONValue
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingAdmin,
            .post,
            DistrictPaths.schedulingAdmin,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("op", .string(op.rawValue)),
                // ⚠️ NOT `.optional(...)`: an op that takes nothing sends `{}`,
                // and `JSONValue.object(_:)` would DROP a nil pair — leaving the
                // route to read `body.params` as undefined. It defaults that to
                // `{}` itself, so the two agree today; sending the empty object
                // makes the agreement a contract rather than a coincidence.
                ("params", params),
            ]))
        )
    }

    /// Publish one of the three images the admin surface can set.
    ///
    /// ⛔ THE WORKSPACE IS A QUERY PARAMETER AND `target` IS A FORM FIELD, WHICH IS
    /// A THIRD SHAPE AGAIN — ``uploadMedia`` puts the workspace in the fields and
    /// ``uploadDeskLogo`` sends no fields at all. The split is deliberate at the
    /// server: the workspace id has to be readable before `req.formData()` so the
    /// session check can run ahead of a multipart parse of a body up to
    /// Cloudflare's 100 MB, while `target` can only be known after it.
    ///
    /// ⛔ THE FILE PART IS NAMED `file` HERE AND IS RENAMED AT THE FAR END. The
    /// fork reads `logo`, `banner` and `avatar` respectively; our route translates,
    /// which is why ``MultipartBody/filePartName`` is still correct and why a part
    /// named after the target would be "Missing file field".
    ///
    /// ⚠️ JPEG, PNG, GIF AND WEBP ONLY — **NOT SVG**, which is the obvious thing to
    /// want for a logo and is a script-bearing document. The refusal is a **415**
    /// and this client cannot pre-compute it, because the fork sniffs the first 512
    /// bytes rather than trusting the declared type. The other refusals are a 413
    /// over 5 MiB and a 403 when a `viewer` aims at `logo` or `banner`; `avatar` is
    /// the caller's OWN picture and is viewer-level.
    static func schedulingAdminUpload(
        workspaceId: String,
        target: SchedulingAdminUploadTarget,
        fileName: String,
        mimeType: String,
        bytes: Data
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingAdminUpload,
            .post,
            DistrictPaths.schedulingAdminUpload,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .multipart(MultipartBody(
                fields: ["target": target.rawValue],
                fileName: fileName,
                contentType: mimeType,
                bytes: bytes
            ))
        )
    }

    /// Resolve a playable URL for a scheduler recording.
    ///
    /// ⛔ THE SERVER ANSWERS **302, NOT JSON**, AND THIS CLIENT MUST NOT FOLLOW IT
    /// — the same rule as ``callRecordingUrl(workspaceId:callId:)`` and for a
    /// sharper version of the same reason: these are video, and the fork has no 2xx
    /// path at all. Send it through ``ApiClient/redirectTarget(_:)``.
    ///
    /// ⚠️ THE URL IS PRESIGNED AND EXPIRES IN 15 MINUTES. Resolve it at the moment
    /// of playback; a cached one fails inside whatever player received it, which
    /// looks like a broken recording rather than a stale link.
    ///
    /// ⛔ `agency` AND `client` ONLY, WHICH IS STRICTER THAN THE OP THAT LISTS
    /// THESE. ``SchedulingAdminOp/recordingsList`` is `viewer`: a viewer may see
    /// that a recording exists and may not take a copy of a customer conversation
    /// away. A UI that draws the row from the list must not assume the download
    /// beside it will answer.
    static func schedulingAdminDownload(workspaceId: String, recordingId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingAdminDownload,
            .get,
            DistrictPaths.schedulingAdminDownload(recordingId),
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}

/// Which image an upload replaces.
///
/// ⛔ A CLOSED SET, BECAUSE AN UNKNOWN `target` IS A **400 `unknown_target`** AND
/// THE THREE DO NOT SHARE A PERMISSION. `logo` and `banner` are the WORKSPACE's
/// public booking-page branding and are `client`; `avatar` is the caller's own
/// picture and is `viewer`, so it spends the per-member budget rather than the
/// workspace's. Spelling the target as a `String` would let a screen offer a
/// control the server refuses and would put an avatar on the branding budget.
public enum SchedulingAdminUploadTarget: String, Sendable, CaseIterable {
    case logo
    case banner
    case avatar
}
