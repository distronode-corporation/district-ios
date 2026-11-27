@testable import DistrictAI
import XCTest

/// What the workspace list tells the Watch (#152): only a real answer becomes "no workspace";
/// a list that could not be read is unknown, so nothing is published and the Watch keeps the
/// snapshot it has.
@MainActor
final class WatchSnapshotWorkspaceTests: XCTestCase {
    private static let failure = FailureText(message: "Something went wrong on our side.", action: .retry)

    /// ⛔ THE BUG: a failed read was sent to the Watch as an account with no workspace.
    func testAFailedListIsUnknownNotNoWorkspace() {
        guard case .unknown = WatchSnapshotComposer.workspace(in: .failed(Self.failure)) else {
            return XCTFail("a failed list must not become 'no workspace'")
        }
    }

    /// Every region down (the 503) is "we could not look", not "there is nothing".
    func testADegradedListIsUnknown() {
        guard case .unknown = WatchSnapshotComposer.workspace(in: .degraded("EU, APAC")) else {
            return XCTFail("a degraded list must not become 'no workspace'")
        }
    }

    /// A list still loading says nothing either.
    func testALoadingListIsUnknown() {
        guard case .unknown = WatchSnapshotComposer.workspace(in: .loading) else {
            return XCTFail("a loading list must not become 'no workspace'")
        }
    }

    /// The real answers: no workspace at all, or every workspace lapsed.
    func testAnEmptyOrLapsedAccountIsNoWorkspace() {
        for state in [WorkspaceSessionState.empty, .lapsed(inactiveCount: 0), .lapsed(inactiveCount: 3)] {
            guard case .none = WatchSnapshotComposer.workspace(in: state) else {
                return XCTFail("\(state) is a real answer: no workspace")
            }
        }
    }
}
