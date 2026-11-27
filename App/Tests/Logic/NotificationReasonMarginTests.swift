@testable import DistrictAI
import DistrictAuthCore
import DistrictL10n
import DistrictModel
import XCTest

/// The sentence a failed shade action is reported with (``MessageActionFailure/reason(for:)``),
/// for every failure the handler can produce and both actions: the reply keeps the sentence
/// that says where the text can still be sent from, Mark read says only what failed, a
/// session that is merely unavailable never reads as signed out, and a 5xx never carries the
/// server's raw text onto the lock screen.
@MainActor
final class NotificationReasonMarginTests: XCTestCase {
    private let reply = MessageAction.reply("On my way.")

    override func setUp() {
        super.setUp()
        L10nRuntime.locale = .en
    }

    func testAnUnreadablePushOrAMissingThreadNamesTheConversation() {
        for failure in [MessageActionFailure.unreadablePayload, .threadNotFound] {
            XCTAssertEqual(failure.reason(for: reply), NavigationCopy.conversationCouldNotOpened)
            XCTAssertEqual(failure.reason(for: .markRead), InboxCopy.conversationCouldNotOpened)
        }
        // ⚠️ THE REPLY'S SENTENCE IS THE LONGER ONE: it says the text was not sent.
        XCTAssertNotEqual(NavigationCopy.conversationCouldNotOpened, InboxCopy.conversationCouldNotOpened)
        XCTAssertTrue(NavigationCopy.conversationCouldNotOpened.contains("reply was not sent"))
    }

    func testASessionThatCannotBeUsedNowIsNotASignOut() {
        let unavailable = MessageActionFailure.sessionUnavailable(.refreshNotSent)

        XCTAssertEqual(unavailable.reason(for: reply), SessionCopy.refreshNotSent)
        XCTAssertEqual(unavailable.reason(for: .markRead), SessionCopy.refreshNotSent)
        XCTAssertEqual(
            MessageActionFailure.sessionUnavailable(.storeUnavailable).reason(for: .markRead),
            SessionCopy.storeUnavailable
        )
        XCTAssertNotEqual(unavailable.reason(for: .markRead), SessionCopy.sessionHasEndedPlease)
    }

    /// A sign-out with its own sentence says it; only `.noSession` (pinned in
    /// NotificationActionHandlerTests) falls back.
    func testASignOutWithItsOwnSentenceSaysIt() {
        let rejected = MessageActionFailure.signedOut(.refreshRejected)

        XCTAssertEqual(rejected.reason(for: .markRead), SessionCopy.refreshRejected)
        XCTAssertEqual(rejected.reason(for: reply), SessionCopy.refreshRejected)
    }

    func testAnUnresolvedThreadDependsOnTheAction() {
        let offline = MessageActionFailure.unresolved(.transport("The Internet connection appears to be offline."))

        XCTAssertEqual(offline.reason(for: reply), NavigationCopy.conversationCouldNotOpened)
        XCTAssertEqual(offline.reason(for: .markRead), SessionCopy.appearOfflineCheckConnection)
    }

    func testARefusalIsTheServersSentenceForA4xxOnly() {
        let viewer = MessageActionFailure.refused(.http(status: 403, message: "Viewers cannot mark messages read"))
        let crashed = MessageActionFailure.refused(
            .http(status: 500, message: "duplicate key value violates unique constraint \"Message_pkey\"")
        )

        XCTAssertEqual(viewer.reason(for: .markRead), "Viewers cannot mark messages read")
        let hidden = crashed.reason(for: .markRead)
        XCTAssertFalse(hidden.contains("Message_pkey"), hidden)
        XCTAssertEqual(hidden, FailureText.from(.http(status: 500, message: nil)).message)
    }
}
