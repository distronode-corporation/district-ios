@testable import DistrictAI
import DistrictModel
import XCTest

/// The hardware-keyboard commands: when each one can run, which digit selects which tab,
/// and which screen ⌘R refreshes.
///
/// ⚠️ THE KEY PRESSES THEMSELVES ARE NOT DRIVEN HERE. A command reaches a screen only in a
/// signed-in shell; these pin the decisions the menu and the screens read.
final class ShellCommandsTests: XCTestCase {
    // MARK: - Availability

    /// ⛔ SIGNED OUT, OR NO WORKSPACE YET: EVERY COMMAND IS DISABLED.
    func test_IOS_COMMANDS_01_nothingRunsWithoutAWorkspace() {
        for availability in [
            ShellCommandAvailability.unavailable,
            ShellCommandAvailability(workspaceId: nil, role: .agency, refreshAvailable: true),
        ] {
            XCTAssertFalse(availability.canSelectSection)
            XCTAssertFalse(availability.canCompose)
            XCTAssertFalse(availability.canSearch)
            XCTAssertFalse(availability.canRefresh)
        }
    }

    /// ⛔ ⌘N FOLLOWS THE SEND GATE: a viewer, and a role that could not be established, may
    /// not compose; everyone may still select, search and refresh.
    func test_IOS_COMMANDS_02_composeFollowsTheSendGate() {
        let roles: [WorkspaceRole?] = WorkspaceRole.allCases.map(\.self) + [nil]
        for role in roles {
            let availability = ShellCommandAvailability(workspaceId: "ws_1", role: role, refreshAvailable: true)
            XCTAssertEqual(availability.canCompose, WorkspaceRole.allowsMutation(role), String(describing: role))
            XCTAssertTrue(availability.canSelectSection)
            XCTAssertTrue(availability.canSearch)
            XCTAssertTrue(availability.canRefresh)
        }
        XCTAssertFalse(ShellCommandAvailability(workspaceId: "ws_1", role: .viewer, refreshAvailable: true).canCompose)
        XCTAssertFalse(ShellCommandAvailability(workspaceId: "ws_1", role: nil, refreshAvailable: true).canCompose)
    }

    /// ⚠️ ⌘R NEEDS A PULL-TO-REFRESH ON SCREEN.
    func test_IOS_COMMANDS_03_refreshNeedsAScreenThatRefreshes() {
        let availability = ShellCommandAvailability(workspaceId: "ws_1", role: .agency, refreshAvailable: false)
        XCTAssertFalse(availability.canRefresh)
    }

    /// ⌘1 to ⌘5 are the tab bar's order.
    func test_IOS_COMMANDS_04_theDigitsFollowTheTabOrder() {
        XCTAssertEqual(Tab.allCases.map(ShellCommandAvailability.digit(for:)), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(ShellCommandAvailability.digit(for: .overview), "1")
        XCTAssertEqual(ShellCommandAvailability.digit(for: .account), "5")
    }

    // MARK: - Which screen ⌘R refreshes

    /// ⛔ THE SCREEN THAT APPEARED LAST, and the one under it once that one has gone.
    @MainActor
    func test_IOS_COMMANDS_05_theLastScreenToAppearIsRefreshed() async {
        let center = ShellCommandCenter()
        let log = RefreshLog()
        XCTAssertFalse(center.canRefresh)

        let list = UUID()
        let pushed = UUID()
        center.register(list) { await log.append("list") }
        center.register(pushed) { await log.append("pushed") }
        XCTAssertTrue(center.canRefresh)

        await center.refresh()
        center.unregister(pushed)
        await center.refresh()
        center.unregister(list)
        XCTAssertFalse(center.canRefresh)
        await center.refresh()

        let entries = await log.entries
        XCTAssertEqual(entries, ["pushed", "list"])
    }

    /// ⚠️ A SCREEN THAT APPEARS AGAIN MOVES TO THE TOP rather than being listed twice.
    @MainActor
    func test_IOS_COMMANDS_06_reappearingMovesAScreenToTheTop() async {
        let center = ShellCommandCenter()
        let log = RefreshLog()
        let first = UUID()
        let second = UUID()
        center.register(first) { await log.append("first") }
        center.register(second) { await log.append("second") }
        center.register(first) { await log.append("first again") }

        await center.refresh()
        center.unregister(first)
        await center.refresh()

        let entries = await log.entries
        XCTAssertEqual(entries, ["first again", "second"])
    }

    /// ⛔ ONE REFRESH AT A TIME: ⌘R is disabled, and does nothing, while one runs.
    @MainActor
    func test_IOS_COMMANDS_07_aRefreshInFlightBlocksASecond() async {
        let center = ShellCommandCenter()
        let gate = RefreshGate()
        let log = RefreshLog()
        center.register(UUID()) {
            await log.append("run")
            await gate.wait()
        }

        let running = Task { await center.refresh() }
        while await log.entries.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(center.isRefreshing)
        XCTAssertFalse(center.canRefresh)
        await center.refresh()

        await gate.open()
        await running.value
        XCTAssertFalse(center.isRefreshing)
        XCTAssertTrue(center.canRefresh)
        let entries = await log.entries
        XCTAssertEqual(entries, ["run"])
    }
}

private actor RefreshLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

private actor RefreshGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
