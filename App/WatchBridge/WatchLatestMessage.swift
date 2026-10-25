import Foundation

/// One line of the newest conversation, as "Read my latest message" says it (3.2).
///
/// ⚠️ COMPILED INTO BOTH APPS, and it holds no words: the phone says it with `IntentCopy`, the
/// watch with `WatchCopy`, each in its own catalog.
struct LatestMessageLine: Equatable, Sendable {
    /// The contact's name or a masked number (``WatchMasking``).
    let name: String
    /// The message, without the direction glyph the list rows draw.
    let text: String
    /// True when the business sent it: the newest message in the thread is a reply.
    let outbound: Bool

    /// ⛔ THE GLYPH IS READ OFF, NOT SPOKEN. A row's preview starts with "↑ " (sent) or "↓ "
    /// (received), which is right on a list and wrong in Siri's mouth.
    init(_ conversation: WatchSnapshot.Conversation) {
        name = conversation.title
        let preview = conversation.preview
        if preview.hasPrefix(Self.sent) {
            outbound = true
            text = String(preview.dropFirst(Self.sent.count))
        } else if preview.hasPrefix(Self.received) {
            outbound = false
            text = String(preview.dropFirst(Self.received.count))
        } else {
            outbound = false
            text = preview
        }
    }

    static let sent = "↑ "
    static let received = "↓ "
}
