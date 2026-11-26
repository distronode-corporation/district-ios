@testable import DistrictAIWatch
import Foundation
import WatchConnectivity
import XCTest

/// The watch's language rule: the phone's choice first, then the watch's FIRST preferred tag.
@MainActor
final class WatchL10nTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    func testThePhonesLanguageDecidesWhenItSaidOne() {
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: "fr-CA", preferred: ["en-CA"]), .frCA)
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: "FR", preferred: []), .frCA)
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: "en", preferred: ["fr-CA"]), .en)
        // ⚠️ A TAG THIS BUILD DOES NOT SPEAK IS ENGLISH, NOT THE WATCH'S LOCALE.
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: "de-DE", preferred: ["fr-CA"]), .en)
    }

    /// ⚠️ THE FIRST TAG, NOT THE FIRST FRENCH ONE; any French is Canadian French; nothing is English.
    func testWithoutThePhoneTheFirstPreferredTagDecides() {
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: nil, preferred: ["fr-FR", "en"]), .frCA)
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: nil, preferred: ["en-CA", "fr-CA"]), .en)
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: nil, preferred: []), .en)
        XCTAssertEqual(WatchL10n.resolve(phoneLanguage: nil, preferred: [""]), .en)
    }

    func testTheCopyAndItsLocaleFollowThePhone() {
        WatchL10n.phoneLanguage = "fr-CA"
        XCTAssertEqual(WatchL10n.copyLocale, .frCA)
        XCTAssertEqual(WatchL10n.locale.identifier, "fr_CA")
        XCTAssertEqual(WatchCopy.replySent, "Message envoyé")

        WatchL10n.phoneLanguage = "en"
        XCTAssertEqual(WatchL10n.copyLocale, .en)
        XCTAssertEqual(WatchL10n.locale.identifier, "en_CA")
        XCTAssertEqual(WatchCopy.replySent, "Reply sent")
    }

    /// A relative time in the watch's language, from the system's formatter.
    func testARelativeTimeIsWrittenInThePhonesLanguage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-5 * 60)

        WatchL10n.phoneLanguage = "en"
        let english = WatchL10n.relative(past, to: now)
        WatchL10n.phoneLanguage = "fr-CA"
        let french = WatchL10n.relative(past, to: now)

        XCTAssertTrue(english.contains("5") && english.contains("ago"), english)
        XCTAssertTrue(french.contains("5") && french.contains("il y a"), french)
    }
}

/// The App Group's two writers and the system seams: the kept snapshot, the complication's
/// state, the delegate that starts the refresh chain, and the session delegate's readings.
///
/// ⚠️ THE APP GROUP IS THE TEST HOST'S OWN, so every test puts back what it found.
@MainActor
final class WatchStorageTests: XCTestCase {
    private var keptSnapshot: Data?
    private var keptState: Data?
    private var keptWork: WatchAppDelegate.Work?

    override func setUp() {
        super.setUp()
        keptSnapshot = ComplicationState.defaults?.data(forKey: GroupSnapshotStore.key)
        keptState = ComplicationState.defaults?.data(forKey: ComplicationState.defaultsKey)
        keptWork = WatchAppDelegate.work
    }

    override func tearDown() {
        ComplicationState.defaults?.set(keptSnapshot, forKey: GroupSnapshotStore.key)
        ComplicationState.defaults?.set(keptState, forKey: ComplicationState.defaultsKey)
        WatchAppDelegate.work = keptWork
        super.tearDown()
    }

    func testTheKeptSnapshotRoundTripsThroughTheAppGroup() throws {
        let store = GroupSnapshotStore()
        let data = try WatchStoreTests.snapshot().encoded()

        store.save(data)

        XCTAssertEqual(store.load(), data)
        XCTAssertEqual(store.load().map(WatchSnapshot.read(data:)), .snapshot(WatchStoreTests.snapshot()))
    }

    /// ⛔ THE STATE THE WIDGET READS, STAMPED AGAINST THE ONE IT READ BEFORE: a first known
    /// value is not a switch, a switch between known values is, and signing out drops the stamp.
    func testThePublisherWritesTheStampedStateTheWidgetReads() {
        let defaults = ComplicationState.defaults
        ComplicationState.unknown.save(to: defaults)
        let publisher = WidgetComplicationPublisher()
        let on = ComplicationState(signedIn: true, workspaceName: "Plomberie", available: true, language: "en")

        publisher.publish(on)
        XCTAssertEqual(ComplicationState.load(from: defaults), on)

        var off = on
        off.available = false
        publisher.publish(off)
        let switched = ComplicationState.load(from: defaults)
        XCTAssertEqual(switched.available, false)
        XCTAssertNotNil(switched.availabilityChangedAt)

        publisher.publish(.unknown)
        XCTAssertEqual(ComplicationState.load(from: defaults), .unknown)
    }

    func testNoBackgroundRefreshSeesNoComplication() async {
        let none = NoBackgroundRefresh()
        none.scheduleNext()
        let onAFace = await none.unreadComplicationIsOnAFace()
        XCTAssertFalse(onAFace)
    }

    /// ⛔ THE CHAIN STARTS WHEN LAUNCH FINISHES, and only for an app that built its store.
    func testFinishingLaunchStartsTheRefreshChain() {
        let delegate = WatchAppDelegate()
        WatchAppDelegate.work = nil
        delegate.applicationDidFinishLaunching()

        let refresh = BranchRefresh()
        let store = WatchStore(
            link: BranchLink(reachable: false),
            persistence: BranchPersistence(),
            complication: BranchComplication(),
            backgroundRefresh: refresh
        )
        WatchAppDelegate.work = WatchAppDelegate.Work(store: store, link: LivePhoneLink())
        delegate.applicationDidFinishLaunching()

        XCTAssertEqual(refresh.scheduled, 1)
    }

    /// The session delegate hands on every application context as read, an empty one as
    /// unreadable; an activation that did not complete reads nothing.
    func testTheSessionDelegateHandsOnWhatItReads() throws {
        let readings = BranchLocked<WatchSnapshotReading>()
        let delegate = PhoneSessionDelegate()
        delegate.onReading = { @Sendable reading in readings.append(reading) }

        try delegate.session(WCSession.default, didReceiveApplicationContext: WatchStoreTests.snapshot().context())
        delegate.session(WCSession.default, didReceiveApplicationContext: [:])
        delegate.session(WCSession.default, activationDidCompleteWith: .notActivated, error: nil)
        delegate.session(WCSession.default, activationDidCompleteWith: .inactive, error: nil)

        XCTAssertEqual(readings.all, [.snapshot(WatchStoreTests.snapshot()), .unreadable])
    }
}

/// The intent runner's waits: a phone that comes into reach inside the wait is used, and the
/// switch's own write still on its way is said, not sent twice.
@MainActor
final class WatchIntentWaitTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    func testAPhoneThatComesIntoReachDuringTheWaitIsAsked() async {
        let rig = BranchRig(reachable: false)
        rig.store.apply(.snapshot(WatchStoreTests.snapshot()))
        let runner = WatchIntentRunner(store: rig.store, link: rig.link, reachabilityWait: .seconds(10))
        Task { [link = rig.link] in
            try? await Task.sleep(for: .milliseconds(200))
            link.isReachable = true
        }

        let sentence = await runner.setAvailability(false)

        XCTAssertEqual(sentence, WatchCopy.intentAvailabilityOff("Plomberie Desrosiers"))
        XCTAssertEqual(rig.link.sent, [.setAvailability(workspaceId: "ws_1", available: false)])
    }

    /// ⚠️ THE SWITCH'S OWN WRITE IS STILL ON ITS WAY: the intent says "Sending" and sends nothing.
    func testAnIntentDuringTheSwitchsWriteSaysSending() async {
        let rig = BranchRig()
        rig.store.apply(.snapshot(WatchStoreTests.snapshot()))
        let runner = WatchIntentRunner(store: rig.store, link: rig.link, reachabilityWait: .milliseconds(100))
        let said = BranchProbe<String>()
        rig.link.onSend = { [link = rig.link] _ in
            link.onSend = nil
            await said.values.append(runner.setAvailability(true))
        }

        await rig.store.setAvailable(false)

        XCTAssertEqual(said.values, [WatchCopy.sending])
        XCTAssertEqual(rig.link.sent, [.setAvailability(workspaceId: "ws_1", available: false)])
    }
}

/// ⛔ ONLY STRING KEYS SURVIVE THE FLATTENING, as the phone flattens.
final class NotificationFlattenTests: XCTestCase {
    func testNonStringKeysAreDropped() {
        let flattened = WatchNotificationRoute.flatten([1: "message", "type": "message", "workspaceId": "ws_1"])

        XCTAssertEqual(flattened, ["type": "message", "workspaceId": "ws_1"])
    }
}
