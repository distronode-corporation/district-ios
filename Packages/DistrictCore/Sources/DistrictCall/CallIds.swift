/// The workspace a call belongs to.
///
/// ⛔ A TYPE RATHER THAN A `String`, BECAUSE THE TWO IDS TRAVEL TOGETHER AND ARE
/// INDISTINGUISHABLE ONCE THEY ARE BOTH `String`. `POST
/// /api/district/calls/{callId}/answer?workspaceId=` takes one of each, adjacent,
/// in that order, and the Kotlin client records the pair in its tests as the
/// single string `"CA1/ws-1"` precisely because a swap is otherwise invisible —
/// the request is well-formed either way and comes back 404 for a call that
/// exists. Swapping these two is a compile error.
///
/// ⚠️ THIS DIVERGES FROM THE KOTLIN CLIENT, WHICH USES BARE STRINGS. It has no
/// value class for either id (its only `value class`es are the raw-JSON editors
/// in `WorkspaceEditModels.kt`), so this is an addition rather than a port. It
/// costs two types and buys the one class of bug the ids-only push payload makes
/// easy.
public struct WorkspaceID: Hashable, Sendable, CustomStringConvertible {
    /// ⚠️ Server-issued and opaque. Nothing here parses, validates or normalises
    /// it: the id is whatever the push carried, and it is sent back verbatim.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

/// One call, by the id the server knows it as.
///
/// ⚠️ IT IS THE `Call.callSid`, i.e. the row already in the workspace's call log
/// rather than a client-side handle. The outbound row is written before the
/// carrier is told to dial; the inbound row exists before the push is sent. See
/// ``DistrictModel/DialResponse`` for the outbound half.
public struct CallID: Hashable, Sendable, CustomStringConvertible {
    /// ⚠️ Opaque, and used verbatim. See ``WorkspaceID/rawValue``.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}
