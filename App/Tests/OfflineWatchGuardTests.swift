@testable import DistrictAI
import XCTest

/// The offline read cache and the Watch: a snapshot built from the saved copy is never
/// sent to the Watch as live.
final class OfflineWatchGuardTests: XCTestCase {
    /// ⛔ THE WATCH IS NEVER SENT THE OFFLINE COPY AS LIVE: each answer from the saved copy
    /// is counted, and the Watch snapshot source publishes nothing when the count moved
    /// during its reads.
    @MainActor
    func test_OFF_19_theWatchSnapshotSkipsTheSavedCopy() throws {
        let status = OfflineStatus()
        XCTAssertEqual(status.savedServes, 0)
        status.servedSaved(path: "/api/district/calls", savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        status.servedLive(path: "/api/district/calls")
        XCTAssertEqual(status.savedServes, 1, "a live answer must not hide that a saved one was served")
        let file = try SourceScan.sourceRoot().appendingPathComponent("Platform/WatchSnapshotBuilder.swift")
        let source = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
        let before = try XCTUnwrap(source.range(of: "let savedServes = OfflineRead.status.savedServes"))
        let reads = try XCTUnwrap(source.range(of: "await workspaces.load()"))
        let guarded = try XCTUnwrap(source
            .range(of: "guard OfflineRead.status.savedServes == savedServes else { return nil }"))
        let compose = try XCTUnwrap(source.range(of: "return WatchSnapshotComposer.compose("))
        XCTAssertLessThan(before.lowerBound, reads.lowerBound)
        XCTAssertLessThan(guarded.lowerBound, compose.lowerBound)
    }
}
