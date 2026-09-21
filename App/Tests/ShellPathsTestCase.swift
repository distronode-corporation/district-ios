@testable import DistrictAI
import DistrictModel
import XCTest

/// The fixtures every shell navigation test builds its state and routes from.
///
/// ⛔ A BASE CLASS RATHER THAN A COPY IN EACH FILE, AND THE SPLIT THAT CREATED IT IS A
/// LINT CEILING RATHER THAN A DESIGN STATEMENT, exactly as ``SchedulingModelTestCase``
/// records. What matters is that "what a layout rebuild writes back" is defined once: two
/// copies of it would be two answers to the question the flip tests exist to ask.
class ShellPathsTestCase: XCTestCase {
    let workspaceId = "ws_1"
    let role = WorkspaceRole.agency

    var hubItems: [SidebarItem] {
        SidebarItem.allCases.filter { $0.tab == nil }
    }

    func root(_ item: SidebarItem, role: WorkspaceRole? = .agency) -> Route {
        guard let route = item.rootRoute(workspaceId: workspaceId, role: role) else {
            preconditionFailure("\(item) is not a hub section")
        }
        return route
    }

    var call: Route {
        .callDetail(workspaceId: workspaceId, callId: "call_1")
    }

    var contact: Route {
        .contactDetail(workspaceId: workspaceId, role: role, contactId: "c_1")
    }

    var dialer: Route {
        .dialer(workspaceId: workspaceId, role: role)
    }

    var room: Route {
        .activeRoom(workspaceId: workspaceId, role: role, roomName: "meet_ws_1_a")
    }

    /// A state whose tenant has been seeded, as it is once the workspace list resolves.
    func seeded() -> ShellPaths {
        var paths = ShellPaths()
        paths.adopt(workspaceId)
        return paths
    }

    /// What SwiftUI does when a layout is rebuilt around a stack: reads the binding and,
    /// at worst, writes the same value back.
    func rebuildCompact(_ paths: inout ShellPaths) {
        for tab in Tab.allCases {
            let path = paths.compactPath(for: tab)
            paths.setCompactPath(path, for: tab)
        }
        let tab = paths.compactTab
        paths.compactTab = tab
    }

    func rebuildRegular(_ paths: inout ShellPaths) {
        for item in SidebarItem.allCases {
            let path = paths.regularPath(for: item)
            paths.setRegularPath(path, for: item)
        }
        let selection = paths.regularSelection
        paths.setRegularSelection(selection, workspaceId: workspaceId, role: role)
    }

    func snapshot(_ paths: ShellPaths) -> [String] {
        SidebarItem.allCases.map { "\($0): \(paths.regularPath(for: $0))" }
            + ["selection: \(paths.regularSelection)", "root: \(String(describing: paths.overviewHubRoot))"]
    }
}
