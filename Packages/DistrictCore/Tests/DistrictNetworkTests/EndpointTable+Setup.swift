@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    /// The setup wizard's read, and nothing else from that route.
    ///
    /// ⚠️ ONE ROW FOR A ROUTE THAT ALSO TAKES A PATCH. The wizard's writes belong to the web
    /// wizard and are not ported, so a GET is the only request this client can express
    /// against `/api/district/setup`. Read off Android's `HttpSetupApi.kt`.
    static func setup() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .districtSetup,
                DistrictEndpoints.districtSetup(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/setup?workspaceId=ws_1"
            ),
        ]
    }
}
