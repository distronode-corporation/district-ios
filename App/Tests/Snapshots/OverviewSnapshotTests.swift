@testable import DistrictAI
import DistrictL10n
import SwiftUI
import XCTest

/// The Overview tab, drawn over a real ``SessionModel`` and a ``WorkspaceSessionModel`` that
/// reads the recorded workspace list, so the header, the switcher and the entry column are
/// the ones the shell draws.
///
/// ⚠️ THE LIST'S FIRST WORKSPACE IS RENAMED TO THE OVERVIEW FIXTURE'S `ws-contract-test`. The
/// two fixtures were recorded for different workspaces, and ``OverviewModel`` refuses an
/// overview about a workspace other than the one asked for (``testOverviewForAnotherWorkspace``
/// draws exactly that refusal).
final class OverviewSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let suite = "com.distronode.district.snapshot.overview"

    /// The recorded list, with its first workspace re-pointed at the overview's and made the default.
    private static func list(_ name: String = "district-workspace-list") -> FixtureTransport.Reply {
        .recorded(name) { json in
            guard var rows = json["workspaces"] as? [[String: Any]], !rows.isEmpty else {
                XCTFail("\(name) has no workspaces")
                return
            }
            rows[0]["id"] = Self.workspace
            json["workspaces"] = rows
            json["defaultWorkspaceId"] = Self.workspace
        }
    }

    /// The overview with its effective role (and anything else) changed.
    private static func overview(_ edit: (inout [String: Any]) -> Void) -> FixtureTransport.Reply {
        .recorded("district-overview", with: edit)
    }

    /// Setup with every step done, so the finish-setup card is not offered.
    private static let setupDone: FixtureTransport.Reply = .recorded("district-setup") { json in
        json.editObject("setupProgress") { progress in
            progress.editObject("steps") { steps in
                for key in steps.keys {
                    steps[key] = "done"
                }
            }
        }
    }

    private func draw(
        _ replies: [String: FixtureTransport.Reply],
        devices: [Device] = Device.allCases,
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function
    ) async throws {
        try await assertScreen(replies, devices: devices, locales: locales, testName: testName) { container in
            // ⚠️ A DEFAULTS SUITE OF ITS OWN, emptied for every drawing, so a selection another
            // test (or the app) stored cannot pick a different workspace here.
            UserDefaults().removePersistentDomain(forName: Self.suite)
            let defaults = UserDefaults(suiteName: Self.suite) ?? .standard
            let session = SessionModel(container: container, push: PushRegistrar(container: container))
            let workspaces = WorkspaceSessionModel(
                container: container,
                selection: WorkspaceSelectionStore(defaults: defaults)
            )
            return OverviewView(
                container: container,
                session: session,
                workspaceSession: workspaces,
                onSignIn: {},
                onSelectTab: { _ in }
            )
            .task { await workspaces.load() }
        }
    }

    /// The recorded overview: header with the switcher (three workspaces), the finish-setup
    /// card (setup has steps to do), the four tiles, the recent call and the entry column.
    func testOverviewLoaded() async throws {
        try await draw(["/api/district/workspace/list": Self.list()])
    }

    /// Setup is complete: no card above the tiles.
    func testOverviewSetupComplete() async throws {
        try await draw(
            ["/api/district/workspace/list": Self.list(), "/api/district/setup": Self.setupDone],
            devices: [.iPhone],
            locales: [.en]
        )
    }

    /// A day-one workspace: no calls yet draws the empty sentence, not a blank.
    func testOverviewNoRecentCalls() async throws {
        try await draw([
            "/api/district/workspace/list": Self.list(),
            "/api/district/setup": Self.setupDone,
            "/api/district/overview": Self.overview { $0["recentCalls"] = [Any]() },
        ])
    }

    /// The overview's EFFECTIVE role is viewer: the header says read-only and the entry column
    /// drops what a viewer cannot open, whatever the list's membership role says.
    func testOverviewForAViewer() async throws {
        try await draw([
            "/api/district/workspace/list": Self.list(),
            "/api/district/setup": Self.setupDone,
            "/api/district/overview": Self.overview { $0["role"] = "viewer" },
        ], devices: [.iPhone])
    }

    /// An unparsed effective role fails closed: read-only, as a viewer.
    func testOverviewWithAnUnknownRole() async throws {
        try await draw([
            "/api/district/workspace/list": Self.list(),
            "/api/district/setup": Self.setupDone,
            "/api/district/overview": Self.overview { $0["role"] = "superuser" },
        ], devices: [.iPhone], locales: [.en])
    }

    /// One region did not answer the list: the caption names it above the numbers.
    func testOverviewWithAPartialWorkspaceList() async throws {
        try await draw([
            "/api/district/workspace/list": Self.list("district-workspace-list-partial"),
            "/api/district/setup": Self.setupDone,
        ], devices: [.iPhone])
    }

    /// The only workspace: no switch control in the header.
    func testOverviewWithOneWorkspace() async throws {
        let single: FixtureTransport.Reply = .recorded("district-workspace-list") { json in
            guard let rows = json["workspaces"] as? [[String: Any]], var first = rows.first else {
                XCTFail("district-workspace-list has no workspaces")
                return
            }
            first["id"] = Self.workspace
            json["workspaces"] = [first]
            json["total"] = 1
            json["defaultWorkspaceId"] = Self.workspace
        }
        try await draw(
            ["/api/district/workspace/list": single, "/api/district/setup": Self.setupDone],
            devices: [.iPhone],
            locales: [.en]
        )
    }

    /// A refused overview draws the failure with its retry, and the entry column stays, gated
    /// on the list's membership role (the renamed workspace is `agency` there).
    func testOverviewFailed() async throws {
        try await draw([
            "/api/district/workspace/list": Self.list(),
            "/api/district/overview": .refused(500),
        ])
    }

    /// The list's default workspace is not the one the overview fixture answers about, so the
    /// model refuses the numbers rather than draw them under another workspace's name.
    func testOverviewForAnotherWorkspace() async throws {
        try await draw([:], devices: [.iPhone])
    }
}
