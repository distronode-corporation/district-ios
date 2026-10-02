import Foundation
import XCTest

extension XCTestCase {
    /// ⚠️ A BOUNDED POLL, read on the main actor between short sleeps, for a model whose work
    /// runs in tasks it owns and exposes no completion to await. A timeout fails the test at the
    /// caller's line rather than hanging the run, and says where the attempt stood; a fixed sleep
    /// instead is a bet on how busy the simulator is.
    @MainActor
    func waitUntil(
        timeout seconds: Double = 5,
        state: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(seconds)s \(state())", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
