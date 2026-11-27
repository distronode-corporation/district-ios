@testable import DistrictAIWatch
import Foundation
import XCTest

/// The two App Intents the system builds itself: each finds the app's one runner in
/// ``WatchProcess`` and asks it, so "Set my availability" is the switch's own write and "Read
/// my latest message" is asked of the phone, from Siri as from the app.
@MainActor
final class WatchIntentPerformTests: XCTestCase {
    private var keptIntents: WatchIntentRunner?

    override func setUp() {
        super.setUp()
        keptIntents = WatchProcess.intents
    }

    override func tearDown() {
        WatchProcess.intents = keptIntents
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    private func installedRig(answers: [PhoneAnswer]) -> BranchRig {
        let rig = BranchRig(answers: answers)
        rig.store.apply(.snapshot(WatchStoreTests.snapshot()))
        WatchProcess.intents = WatchIntentRunner(store: rig.store, link: rig.link, reachabilityWait: .milliseconds(100))
        return rig
    }

    func testSetAvailabilityAsksTheProcesssRunnerWithItsValue() async throws {
        let rig = installedRig(answers: [.reply(.success)])
        var intent = SetAvailabilityIntent()
        intent.available = false

        _ = try await intent.perform()

        XCTAssertEqual(rig.link.sent, [.setAvailability(workspaceId: "ws_1", available: false)])
    }

    func testReadLatestMessageAsksThePhoneAndMarksNothingRead() async throws {
        let rig = installedRig(answers: [.reply(.latest(WatchStoreTests.snapshot().conversations?.first))])

        _ = try await ReadLatestMessageIntent().perform()

        XCTAssertEqual(rig.link.sent, [.latestMessage(workspaceId: "ws_1")])
    }
}

/// ⛔ THE WATCH'S COUNTS FOLLOW THE PHONE'S LANGUAGE, PLURAL RULE INCLUDED: French counts
/// zero as singular, English does not, so the same unread count reads differently once a
/// snapshot names `fr-CA`.
@MainActor
final class WatchCopyPluralTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    func testAnEnglishPhoneCountsZeroAsPlural() {
        WatchL10n.phoneLanguage = "en"

        XCTAssertEqual(WatchCopy.unreadMessages(0), "0 unread messages")
        XCTAssertEqual(WatchCopy.unreadMessages(1), "1 unread message")
        XCTAssertEqual(WatchCopy.unreadMessages(2), "2 unread messages")
    }

    func testAFrenchPhoneCountsZeroAsSingular() {
        WatchL10n.phoneLanguage = "fr-CA"

        XCTAssertEqual(WatchCopy.unreadMessages(0), "0 message non lu")
        XCTAssertEqual(WatchCopy.unreadMessages(1), "1 message non lu")
        XCTAssertEqual(WatchCopy.unreadMessages(2), "2 messages non lus")
    }

    /// The stamp under Home follows the phone too, with the time as the phone wrote it.
    func testTheUpdatedStampFollowsThePhone() {
        WatchL10n.phoneLanguage = "fr-CA"
        XCTAssertEqual(WatchCopy.updated("il y a 5 min"), "Mis à jour il y a 5 min")
        WatchL10n.phoneLanguage = "en-CA"
        XCTAssertEqual(WatchCopy.updated("5 min ago"), "Updated 5 min ago")
    }
}
