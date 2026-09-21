import DistrictModel
import DistrictNetwork
import Foundation

/// The workspace's booking pages: read the tenancy's state, and provision one.
///
/// ⛔ NEITHER ROUTE CARRIES A `success` ENVELOPE, SO NEITHER GOES THROUGH
/// ``ResponseEnvelope``, AND THAT IS A DECISION RATHER THAN AN OMISSION. Almost
/// every district route answers `{success, …}` and this layer checks the flag by
/// hand because a required field rejects `{}` and does not reject a well-formed
/// `success: false`. These two answer `{eligible, canManage, tenant}` and
/// `{ok, status, publicHost, error}`: there is no flag, so `affirm` would be
/// checking a key the server never sends. `SchedulingRepositoryTests` asserts
/// that a body with no `success` decodes cleanly, so the absence is pinned rather
/// than assumed.
///
/// ⛔ THREE OUTCOMES THAT ALL LOOK LIKE "IT DID NOT WORK" AND MUST NOT BE
/// COLLAPSED, which is the whole reason this repository is more than two lines:
///
///   - `tenant == nil` on a status read is the LEGACY state — no row, nobody has
///     pressed Enable. Ordinary, and the screen's job is to offer the button (if
///     `eligible` and `canManage`), not to report a fault;
///   - `ok: false` on an enable is a SUCCESSFUL 202 carrying an operator-facing
///     sentence in `error`. The provision ran and refused or failed; the sentence
///     is the product, and mapping this onto ``ApiError`` would discard it;
///   - a **403** or a **429** is a real ``ApiError`` and passes straight through.
///     403 means this workspace is not on the scheduling allowlist (a different
///     check from the role gate, and one an owner can also fail); 429 means five
///     enables in an hour for this workspace. The screen renders both.
///
/// ⛔ NOTHING HERE POLLS, AND NOTHING HERE MAY LEARN TO. `enable` reaches two
/// third parties per call — a tenancy at the scheduler and a DNS record at
/// Cloudflare — and its 5/hour limiter fails open, so a retry loop is somebody
/// else's API quota and a zone full of records. A caller that wants to know how a
/// provision ended re-reads ``status(workspaceId:)`` on a human action, which is
/// what the 202 is telling it to do.
public struct SchedulingRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Read the tenancy's state.
    ///
    /// ⚠️ SUCCEEDS FOR A `viewer` TOO, with `canManage: false`. The card is
    /// readable by every role; only the button is gated.
    public func status(workspaceId: String) async -> Result<SchedulingStatusResponse, ApiError> {
        await client.send(
            DistrictEndpoints.schedulingStatus(workspaceId: workspaceId),
            as: SchedulingStatusResponse.self
        )
    }

    /// Provision the tenancy, once, on an explicit press.
    ///
    /// ⛔ THE 202 IS A SUCCESS AND THE CLIENT MUST TREAT IT AS ONE.
    /// ``ApiClient/send(_:as:)`` accepts every 2xx (`ApiErrorNormalizer.isSuccess`
    /// is `200...299`, not `== 200`), so this needs no special case — which is
    /// worth saying out loud because the natural mistake is a client that only
    /// accepts 200 and therefore reports every successful enable as a failure,
    /// with the tenancy provisioned and the screen claiming otherwise. A test
    /// drives a 202 stub for exactly that reason.
    ///
    /// ⛔ AND `ok: false` COMES BACK AS `.success`. See the type's ⛔: the refusal
    /// sentence lives in ``SchedulingEnableResponse/error`` and the caller decides
    /// what to say. Only 403 and 429 arrive as ``ApiError``.
    public func enable(workspaceId: String) async -> Result<SchedulingEnableResponse, ApiError> {
        await client.send(
            DistrictEndpoints.schedulingEnable(workspaceId: workspaceId),
            as: SchedulingEnableResponse.self
        )
    }
}
