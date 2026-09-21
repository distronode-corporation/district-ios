import XCTest

extension XCTestCase {
    /// Spin until `condition` holds, yielding between checks.
    ///
    /// ⚠️ Bounded, and fails rather than hanging: an unbounded wait on a broken
    /// single-flight gate would look like a stuck CI job rather than a red test.
    func waitUntil(
        iterations: Int = 10000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0 ..< iterations {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
