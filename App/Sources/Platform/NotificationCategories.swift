import Foundation
import UserNotifications

/// The notification categories this app registers, and the actions on them.
///
/// ⛔ THE IDENTIFIER IS ALREADY ON THE WIRE AND MUST NOT BE INVENTED HERE. The server
/// sends `category: "district.message"` for every inbound-message push and puts it in
/// `aps.category`, which is the ONLY slot APNs matches against a
/// `UNNotificationCategory` — the server's category list is closed
/// (`"district.message" | "district.incoming_call"`). A category the app registers
/// under a different name matches nothing: the notification still arrives, silently
/// without buttons, and nothing anywhere reports a fault.
///
/// ⛔ THERE IS NO CATEGORY FOR `district.incoming_call`, DELIBERATELY. A call is drawn
/// by CallKit from a VoIP push (``VoIPPushHandler``), not by
/// `UNUserNotificationCenter`, and an Answer button on a notification would be a second
/// way to take a call — one that has to spend `calls/{id}/answer` from a shade, on a
/// ~25 second server-side rendezvous, with no room to join afterwards. ⛔ The server
/// requires the answer route to sit behind a UI press; a lock-screen action is not one.
enum DistrictNotificationCategory {
    /// ⚠️ The server's own string, verbatim. See the ⛔ on this type.
    static let message = "district.message"
}

/// The two things a message notification can do without opening the app.
///
/// ⛔ BOTH ARE NON-FOREGROUND, WHICH IS THE POINT OF HAVING THEM. A foreground action is
/// just a slower tap: it launches the app, and the operator could have tapped the
/// notification. What these buy is a reply sent from the lock screen without leaving
/// whatever the phone was doing.
///
/// ⚠️ AND BOTH RUN IN THE APP PROCESS, WHICH IS WHY NO APP GROUP AND NO NOTIFICATION
/// SERVICE EXTENSION IS INVOLVED. `didReceive(_:withCompletionHandler:)` is delivered to
/// this process, so the Keychain is readable, the one ``AppContainer`` is reachable, and
/// the request carries the operator's own bearer. An extension would need the token in a
/// shared container, which is a credential in a second place for no gain.
enum MessageNotificationAction {
    /// ⚠️ Namespaced under the category so a second category's Reply cannot collide.
    static let reply = "district.message.reply"
    static let markRead = "district.message.mark-read"

    /// The key the tapped action's identifier travels under.
    ///
    /// ⛔ IT RIDES IN THE FLATTENED PAYLOAD RATHER THAN IN A SECOND SLOT ON
    /// ``PushTapRelay``, AND THAT IS ABOUT ATOMICITY RATHER THAN TIDINESS. The relay
    /// hands over one `[String: String]`; two slots would be two values that can arrive
    /// out of order or be half-replaced by the next notification, and the shell reacts
    /// through `onChange`, which compares one value. Putting the action inside the same
    /// dictionary makes "which notification" and "which button" one indivisible fact.
    ///
    /// ⛔ AND THE NAME CANNOT COLLIDE WITH THE SERVER'S. The payload's keys are `type`,
    /// `category`, `workspaceId`, `messageId` and `callId` (`PushPayload`'s constants,
    /// which are the server's verbatim); this prefix is not among them and
    /// ``PushPayload/parse(_:)`` ignores keys it does not know, so stamping it is
    /// invisible to the parser.
    static let identifierKey = "districtNotificationAction"

    /// The key the typed reply travels under. ⚠️ Absent unless the action was
    /// ``reply`` and the operator typed something.
    static let replyTextKey = "districtNotificationText"

    /// Whether an identifier names one of the two buttons this app puts on the shade.
    ///
    /// ⚠️ A HELPER RATHER THAN THE COMPARISON WRITTEN INLINE, AND THE REASON IS A
    /// TOOL DISAGREEMENT WORTH RECORDING. Spelled out at the call site the condition
    /// wraps onto a second line, SwiftFormat then puts the opening brace on its own
    /// line, and SwiftLint's `opening_brace` rejects exactly that — so the two
    /// linters cannot both be satisfied by any formatting of the two-clause form.
    /// Naming the test fixes it by making the condition short, which is the better
    /// shape anyway: the set of shade actions belongs to the type that defines them.
    ///
    /// ⛔ IT MUST STAY IN STEP WITH ``NotificationCategories``. Any action added to
    /// the registered category needs its identifier here too, or the shell will route
    /// its tap to the deep-link path and open the inbox instead of acting.
    static func isShadeAction(_ identifier: String) -> Bool {
        identifier == reply || identifier == markRead
    }
}

/// Registering the categories, and the one notification this app posts itself.
enum NotificationCategories {
    /// Install the category set.
    ///
    /// ⛔ AT LAUNCH, BESIDE THE DELEGATE ASSIGNMENT, AND NOT AFTER AUTHORIZATION.
    /// `setNotificationCategories` is a local registration and needs no permission: it
    /// tells the system what `aps.category` values mean. Deferring it until the prompt
    /// is answered means a notification that arrives BEFORE the first grant — or on a
    /// launch where the prompt is skipped because it was answered months ago — is
    /// matched against an empty set and drawn without its buttons.
    ///
    /// ⚠️ IT REPLACES THE WHOLE SET RATHER THAN ADDING TO IT, which is the API's own
    /// shape. There is one call site for that reason; a second one would silently drop
    /// the first's categories.
    ///
    /// ⛔ `options: []` ON BOTH ACTIONS, WHICH IS WHAT MAKES THEM NON-FOREGROUND.
    /// `.foreground` would launch the app and make the action a slower tap;
    /// `.destructive` is wrong on both counts (nothing is deleted); `.authenticationRequired`
    /// is deliberately NOT set, because these run on the operator's own unlocked-or-not
    /// handset and the alternative is a reply that silently needs a passcode nobody was
    /// asked for.
    static func register(on center: UNUserNotificationCenter = .current()) {
        let reply = UNTextInputNotificationAction(
            identifier: MessageNotificationAction.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to this message"
        )
        let markRead = UNNotificationAction(
            identifier: MessageNotificationAction.markRead,
            title: "Mark read",
            options: []
        )
        let message = UNNotificationCategory(
            identifier: DistrictNotificationCategory.message,
            actions: [reply, markRead],
            // ⚠️ NO `intentIdentifiers` AND NO `.customDismissAction`. The first is for
            // SiriKit intents this app does not declare; the second would deliver a
            // response for a SWIPED-AWAY notification, which is nothing to act on and
            // one more payload the relay would have to discard.
            intentIdentifiers: []
        )
        center.setNotificationCategories([message])
    }

    /// Tell the operator their reply did not send.
    ///
    /// ⛔ A SILENTLY DROPPED REPLY IS THE WORST OUTCOME ON THIS SURFACE, AND IT IS WHY
    /// THIS EXISTS. Everywhere else in this app a failed write leaves a sentence on a
    /// screen somebody is looking at; a reply typed into a lock-screen action has no
    /// screen — the notification is gone the moment the action fires, the app may never
    /// come to the foreground, and the operator's only evidence would be the customer
    /// not answering. So the failure is posted back as a notification of its own.
    ///
    /// ⛔ IT CARRIES THE TEXT BACK. Retyping a reply somebody has already written,
    /// because the app lost it, is the second half of the same failure — and the text is
    /// the operator's own words on their own device, so this discloses nothing the
    /// handset did not already have. ⚠️ It is NOT put in a `userInfo` key: this
    /// notification is a message to a person, not a payload to route, and the body is
    /// where a person reads it.
    ///
    /// ⛔ AND IT CARRIES NO CATEGORY, SO IT HAS NO REPLY BUTTON. Offering Reply on a
    /// failure would post a second attempt through a path that has just failed, and the
    /// thing that failed may well be the network the retry needs. The operator opens the
    /// thread instead, where the composer holds the text and the server's own refusal is
    /// on screen.
    ///
    /// ⚠️ FIRE AND FORGET. `center.add` can itself fail (authorization withdrawn between
    /// the action and now), and there is no third place to report that; the reply
    /// failure is already recorded where it can be — see ``ShellView``'s action handler,
    /// which does not depend on this landing.
    static func postReplyFailure(
        text: String,
        reason: String,
        on center: UNUserNotificationCenter = .current()
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.body = "\(reason)\n\nYour message: \(text)"
        // ⚠️ A FRESH IDENTIFIER PER FAILURE, so two failed replies are two notifications
        // rather than the second replacing the first. They are about different messages.
        let request = UNNotificationRequest(
            identifier: "district.reply-failed.\(UUID().uuidString)",
            content: content,
            // ⚠️ nil MEANS "as soon as possible", which is what a failure report wants.
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
