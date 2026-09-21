import Foundation

public extension TypedEndpoints {
    /// The Inbox's message-to-thread resolver.
    ///
    /// ⛔ UNLIKE `searchMessages` IT HAS A FIXTURE: `district-message-thread.json` is
    /// gated in `ImplementedFixtures`. Its allowlist carries one path
    /// (`$.message.readAt`, an unread inbound message), which is a DECISION recorded
    /// in two files by design — see `AllowedExplicitNulls+Inbox.swift`.
    ///
    /// ⛔ NEVER UNTYPED: ``MessageThreadResponse`` and
    /// `InboxRepository.messageThread(workspaceId:messageId:)` belong with the
    /// descriptor, so no screen can reach this route and get bytes back.
    ///
    /// ⚠️ `markAllRead` IS NOT HERE AND MUST NOT BE ADDED. It is a second BODY on
    /// ``EndpointID/markRead``, not a second endpoint, so it is already classified —
    /// and these three lists are asserted to partition ``EndpointID/allCases``
    /// exactly, which a duplicate would break.
    ///
    /// ⚠️ ITS OWN FILE RATHER THAN ONE MORE LINE IN `EndpointClassification.swift`,
    /// for the reason `EndpointClassification+Desk.swift` gives: that file is at
    /// SwiftLint's 500-line ceiling and the commentary on those lists is the point of
    /// them. Siblings here are expected rather than exceptional.
    static let inbox: Set<EndpointID> = [
        .messageThread,
    ]
}
