import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// What this build asks of the Inbox and declares to push, for app parity with the web
/// Inbox (DistrictCore 8.2.0): Messenger and Instagram threads, the server's reply
/// options, and thread assignment.
///
/// ⛔ THE READS AND THE PUSH DECLARATION GO TOGETHER. `metaChannels=1` makes the Inbox
/// list Messenger and Instagram threads, and `capabilities: ["metaChannels"]` on the
/// device register makes the server send their pushes to this install. A build that
/// declared the capability without reading the threads would ring for a thread its
/// own list cannot show; one that read them without declaring would show threads the
/// lock screen never mentions. Both live here so neither moves alone.
enum InboxParity {
    /// Meta threads on (DistrictCore's default) and the two assignment keys on every
    /// row, which the assignee badge and the Assigned to me filter read.
    static let readOptions = InboxReadOptions(metaChannels: true, assignments: true)

    /// The push capabilities this build declares on its alert token.
    static let pushCapabilities: Set<DeviceCapability> = [.metaChannels]

    /// The one push registration repository, declaring ``pushCapabilities``.
    ///
    /// ⚠️ THE MEMORY MUST STORE THE DECLARATION TOO (``UserDefaultsPushTokenMemory``
    /// does). One that does not never skips a register, which costs a request per
    /// launch rather than breaking anything.
    static func pushTokens(
        client: ApiClient,
        memory: any PushTokenMemory = UserDefaultsPushTokenMemory()
    ) -> PushTokenRepository {
        PushTokenRepository(client: client, memory: memory, platform: .ios, capabilities: pushCapabilities)
    }

    /// The target, or nil when `messages/send` has no channel by that name.
    ///
    /// ⛔ FOR THE PATHS THAT TAKE ONE TARGET FROM `messages/{id}` (a push, a notification
    /// reply, a new conversation). Its channel is the message's own, and a channel this
    /// build cannot send on (a voicemail, one the server adds later) must draw no reply
    /// box rather than a box whose every send fails.
    static func replyable(_ target: ReplyTarget) -> ReplyTarget? {
        MessageChannel.replyable.contains(target.channel) ? target : nil
    }

    /// ``replyable(_:)`` over a list, keeping the server's order.
    static func replyable(_ targets: [ReplyTarget]) -> [ReplyTarget] {
        targets.compactMap(replyable)
    }
}
