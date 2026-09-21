import Foundation

/// The new-customer setup wizard's state, read-only. The wizard itself runs on the web.
///
/// ⛔ OWNER ONLY, AND THE OWNER IS `Workspace.ownerId`, NOT A ROLE. A member, an agency
/// user and a support-access caller all get **403** `workspace_owner_only`.
/// That refusal is the ordinary answer for most people who open the overview, so a caller
/// must read it as "nothing to offer", never as a failure to report.
///
/// ⚠️ THE PATCH IS NOT PORTED AND MUST NOT BE. The wizard's writes decide what the
/// business's receptionist says and belong to the web wizard; this client reads one bit.
public extension DistrictEndpoints {
    /// `GET /api/district/setup?workspaceId=…`.
    static func districtSetup(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .districtSetup,
            .get,
            DistrictPaths.districtSetup,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}
