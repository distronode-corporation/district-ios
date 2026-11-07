@testable import DistrictAI
import DistrictNetwork
import XCTest

/// The offline read cache and the Watch: a snapshot built from the saved copy is never
/// sent to the Watch as live, and another screen's saved answer does not make the Watch
/// drop a live one.
final class OfflineWatchGuardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineWatchGuardTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// ⛔ THE MARK IS SCOPED: a saved answer inside the scope sets it, one outside does not.
    func test_OFF_19_theScopeSeesOnlyItsOwnReads() async throws {
        let cache = OfflineReadCache(directory: directory)
        let request = try HTTPRequest(
            method: .get,
            url: XCTUnwrap(URL(string: "https://example.test/api/district/calls?workspaceId=ws_1")),
            headers: ["Authorization": "Bearer live"],
            body: nil
        )
        cache.store(Data(#"{"success":true}"#.utf8), for: request, generation: cache.generation)
        let transport = OfflineCachingTransport(wrapping: OfflineInner(), cache: cache) { _, _ in }

        // Another screen's saved answer, outside any scope.
        let watch = OfflineReadMark()
        _ = try await transport.send(request, followRedirects: true)
        XCTAssertFalse(watch.isMarked, "a read outside the scope marked it")

        // The Watch's own read, inside its scope, including from a child task.
        try await OfflineReadScope.$served.withValue(watch) {
            async let child = transport.send(request, followRedirects: true)
            _ = try await child
        }
        XCTAssertTrue(watch.isMarked, "a saved answer inside the scope did not mark it")
    }

    /// ⛔ AND THE SNAPSHOT CHECKS THE MARK TWICE: after the workspace list (a saved empty list
    /// must not publish a fresh-looking "no workspace"), and after all four reads.
    func test_OFF_20_theSnapshotChecksTheMarkAfterTheListAndAfterTheReads() throws {
        let file = try SourceScan.sourceRoot().appendingPathComponent("Platform/WatchSnapshotBuilder.swift")
        let source = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
        let guardLine = "guard !mark.isMarked else { return nil }"
        func position(_ text: String, after start: String.Index? = nil) throws -> String.Index {
            let range = start.map { $0 ..< source.endIndex } ?? source.startIndex ..< source.endIndex
            return try XCTUnwrap(source.range(of: text, range: range), text).lowerBound
        }
        let scope = try position("OfflineReadScope.$served.withValue(mark)")
        let load = try position("await workspaces.load()", after: scope)
        let first = try position(guardLine, after: load)
        let empty = try position("return WatchSnapshotComposer.noWorkspace(", after: load)
        let reads = try position("let reads = await (availability, unread, conversations, calls)", after: first)
        let second = try position(guardLine, after: reads)
        let compose = try position("return WatchSnapshotComposer.compose(", after: reads)
        XCTAssertLessThan(first, empty, "the empty-list snapshot is built before the mark is checked")
        XCTAssertLessThan(second, compose, "the snapshot is composed before the mark is checked")
    }
}

/// Every request fails as provably unsent, so the transport answers from the saved copy.
private struct OfflineInner: HTTPTransport {
    func send(_: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
