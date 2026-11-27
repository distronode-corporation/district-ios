@testable import DistrictAI
import SwiftUI
import XCTest

/// States the recorded answers reach without any tap that no other file draws: the devices
/// list with this install marked and every platform name, and the screens whose layout
/// changes at an accessibility text size (the Phone numbers tabs become a menu, list rows
/// stack their trailing slot, a workflow card stacks its controls).
///
/// ⚠️ THE TEXT SIZE IS SET INSIDE THE DRAWN VIEW, which wins over the harness's `.large`
/// because the nearest environment value is the one a view reads.
final class TextSizeAndDeviceRowSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let devicesPath = "/api/auth/native/devices"

    // MARK: - Devices

    /// ⛔ THIS INSTALL IS MARKED BY ITS ID, NEVER BY ITS NAME: two rows carry the same name and
    /// only the one whose id is this container's says "This device". Alongside them, each
    /// platform as people write it (a known one in any case, an unknown one as sent, a blank
    /// one as the placeholder), a blank name as the unnamed placeholder, and a last-active
    /// line next to the "signed in recently" one.
    func testDevicesThisDeviceMarkedAndEveryPlatformName() async throws {
        let rows: [[String: Any]] = [
            Self.device("device_snapshot", name: "iPhone 15", platform: "ios", lastUsed: "2026-08-15T14:30:00.000Z"),
            Self.device("device-other-iphone", name: "iPhone 15", platform: "IOS", lastUsed: nil),
            Self.device("device-mac", name: "  ", platform: "macos", lastUsed: "2026-08-14T09:00:00.000Z"),
            Self.device("device-windows", name: "Front desk PC", platform: "Windows", lastUsed: nil),
            Self.device("device-other", name: "Kiosk", platform: "beos", lastUsed: nil),
            Self.device("device-blank", name: "Tablet", platform: " ", lastUsed: nil),
        ]
        let reply = FixtureTransport.Reply.recorded("district-devices") { $0["devices"] = rows }
        try await assertScreen([Self.devicesPath: reply]) { container in
            let push = PushRegistrar(container: container)
            return DevicesView(container: container, session: SessionModel(container: container, push: push))
        }
    }

    private static func device(_ id: String, name: String, platform: String, lastUsed: String?) -> [String: Any] {
        var row: [String: Any] = [
            "deviceId": id,
            "deviceName": name,
            "platform": platform,
            "lastUsedAt": NSNull(),
            "createdAt": "2026-08-01T09:00:00.000Z",
        ]
        if let lastUsed {
            row["lastUsedAt"] = lastUsed
        }
        return row
    }

    // MARK: - Accessibility text sizes

    /// ⛔ AT AN ACCESSIBILITY SIZE THE FOUR TABS ARE A MENU naming the current tab in full, not
    /// a segmented control whose labels would be clipped.
    func testMarketplaceAtAnAccessibilityTextSize() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            MarketplaceView(container: container, workspaceId: Self.workspace, role: .client)
                .environment(\.dynamicTypeSize, .accessibility3)
        }
    }

    /// The recorded inbox at an accessibility size: each row's title unlimited and its trailing
    /// slot (time, unread) under it rather than squeezing it.
    func testInboxAtAnAccessibilityTextSize() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            InboxView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                path: .constant([]),
                pushSignal: 0,
                selection: nil
            )
            .environment(\.dynamicTypeSize, .accessibility3)
        }
    }

    /// The recorded workflows at an accessibility size: each card's expand control, latest run
    /// and switch stacked, and the name and trigger on as many lines as they need.
    func testWorkflowsAtAnAccessibilityTextSize() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            WorkflowsView(container: container, workspaceId: Self.workspace, role: .client)
                .environment(\.dynamicTypeSize, .accessibility3)
        }
    }
}
