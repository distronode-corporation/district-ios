@testable import DistrictAI
import Foundation

/// A microphone permission that never shows an alert.
///
/// ⚠️ IT COUNTS HOW MANY TIMES IT WAS ASKED, which is what the call tests are about: asking at the
/// wrong moment, or not asking at the right one, is the bug they exist to catch.
final class FakeMicrophoneAccess: MicrophoneAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MicrophoneStatus
    private let grantsWhenAsked: Bool
    private var asked = 0

    /// - Parameter status: the OS's answer before anything asks.
    /// - Parameter grantsWhenAsked: what an undetermined question resolves to when it is asked.
    init(status: MicrophoneStatus, grantsWhenAsked: Bool = false) {
        current = status
        self.grantsWhenAsked = grantsWhenAsked
    }

    var status: MicrophoneStatus {
        lock.withLock { current }
    }

    var requestCount: Int {
        lock.withLock { asked }
    }

    func request() async -> Bool {
        lock.withLock {
            asked += 1
            if current == .notDetermined {
                current = grantsWhenAsked ? .granted : .denied
            }
            return current == .granted
        }
    }
}
