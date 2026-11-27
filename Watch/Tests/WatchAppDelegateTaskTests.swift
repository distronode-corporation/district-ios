@testable import DistrictAIWatch
import Foundation
import WatchKit
import XCTest

/// ⛔ EVERY BACKGROUND TASK IS COMPLETED, ON EVERY PATH (``WatchAppDelegate/handle(_:)``): at
/// once when the app built no store (the debug preview screens) and for a kind this app does
/// not use, and after the phone was asked for a refresh. An uncompleted task costs the app its
/// background budget.
///
/// ⚠️ The system's task classes are plain `NSObject` subclasses, so a test subclass records the
/// completion instead of handing it to watchOS.
@MainActor
final class WatchAppDelegateTaskTests: XCTestCase {
    private var keptWork: WatchAppDelegate.Work?

    override func setUp() {
        super.setUp()
        keptWork = WatchAppDelegate.work
    }

    override func tearDown() {
        WatchAppDelegate.work = keptWork
        super.tearDown()
    }

    func testWithoutAStoreEveryTaskIsCompletedAtOnce() {
        WatchAppDelegate.work = nil
        let refresh = RecordingRefreshTask()
        let wake = RecordingConnectivityTask()

        WatchAppDelegate().handle([refresh, wake])

        XCTAssertEqual(refresh.completions.all, [false])
        XCTAssertEqual(wake.completions.all, [false])
    }

    func testARefreshAsksThePhoneThenCompletes() async {
        let rig = BranchRig()
        let refresh = BranchRefresh()
        let store = WatchStore(
            link: rig.link,
            persistence: BranchPersistence(),
            complication: BranchComplication(),
            backgroundRefresh: refresh
        )
        WatchAppDelegate.work = WatchAppDelegate.Work(store: store, link: LivePhoneLink())
        let task = RecordingRefreshTask()

        WatchAppDelegate().handle([task])
        await branchWait { !task.completions.all.isEmpty }

        XCTAssertEqual(rig.link.sent, [.refresh])
        XCTAssertEqual(refresh.scheduled, 1)
        XCTAssertEqual(task.completions.all, [false])
    }

    func testAConnectivityWakeCompletesOnceTheContentIsIn() async {
        let rig = BranchRig()
        WatchAppDelegate.work = WatchAppDelegate.Work(store: rig.store, link: LivePhoneLink())
        let wake = RecordingConnectivityTask()

        WatchAppDelegate().handle([wake])
        await branchWait { !wake.completions.all.isEmpty }

        XCTAssertEqual(wake.completions.all, [false])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    /// A kind this app never schedules is completed at once, and asks the phone nothing.
    func testAnyOtherKindIsCompletedAtOnce() {
        let rig = BranchRig()
        WatchAppDelegate.work = WatchAppDelegate.Work(store: rig.store, link: LivePhoneLink())
        let snapshot = RecordingSnapshotTask()

        WatchAppDelegate().handle([snapshot])

        XCTAssertEqual(snapshot.completions.all, [false])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }
}

// MARK: - Tasks that record their completion

private final class RecordingRefreshTask: WKApplicationRefreshBackgroundTask {
    let completions = BranchLocked<Bool>()

    override func setTaskCompletedWithSnapshot(_ refreshSnapshot: Bool) {
        completions.append(refreshSnapshot)
    }
}

private final class RecordingConnectivityTask: WKWatchConnectivityRefreshBackgroundTask {
    let completions = BranchLocked<Bool>()

    override func setTaskCompletedWithSnapshot(_ refreshSnapshot: Bool) {
        completions.append(refreshSnapshot)
    }
}

private final class RecordingSnapshotTask: WKSnapshotRefreshBackgroundTask {
    let completions = BranchLocked<Bool>()

    override func setTaskCompletedWithSnapshot(_ refreshSnapshot: Bool) {
        completions.append(refreshSnapshot)
    }
}
