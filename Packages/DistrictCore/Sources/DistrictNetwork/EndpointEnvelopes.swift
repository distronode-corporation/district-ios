import Foundation

// How a route ANSWERS, as opposed to whether this client has ported a DTO for it.
//
// ⛔ SPLIT OUT OF `EndpointClassification.swift` BECAUSE THAT FILE REACHED
// SWIFTLINT'S 500-LINE CEILING AT 498 AND A NEW ENDPOINT FAMILY COULD NOT LAND —
// the support surface needed five lines and had two. The cut is on a real seam
// rather than at an arbitrary line: `UntypedEndpoints` and `TypedEndpoints` are the
// two halves of one burn-down and have to be read together, while the two enums
// here answer a different question entirely (what SHAPE comes back), are referenced
// by different code, and move for different reasons.
//
// ⚠️ THE TYPES, THEIR DOC COMMENTS AND THEIR MEMBERS ARE UNCHANGED BY THE MOVE.
// `EndpointSurfaceTests` asserts both sets by value, so a move that quietly dropped
// a member would fail there rather than in review.
//
// ⚠️ AND THE SEAM IS NOT PERFECT: `meetings` is on `BareArrayEndpoints` AND on
// `TypedEndpoints.all` in the other file, because the two lists answer different
// questions about the same route. Membership of one says nothing about the other.

/// The endpoints that answer with a redirect rather than a body.
///
/// ⛔ TWO, AND NEITHER MAY BE SENT THROUGH THE ORDINARY PATH.
/// `calls/{id}/recording` and `scheduling/admin/download/{id}` both answer
/// **302** to a presigned object URL; ``ApiClient/send(_:)`` would let the
/// transport follow it and download the whole file just to learn its address. Use
/// ``ApiClient/redirectTarget(_:)``.
///
/// ⚠️ THE SECOND ONE IS VIDEO, NOT AUDIO, which is the same mistake costing two
/// orders of magnitude more memory — the scheduler route exists at all because
/// its own origin refuses to proxy the bytes for exactly that reason.
///
/// ⛔ A REDIRECT IS NOT AUTOMATICALLY A MEMBER OF THIS LIST, AND THE COUNTER-CASE
/// IS ONE SEGMENT AWAY. `scheduling/sso` answers a 302 as well and is deliberately
/// absent: its `Location` is a SINGLE-USE SIGN-IN CREDENTIAL rather than an
/// object, so it has no ``EndpointID`` at all and is fetched in the App target
/// with redirects disabled. The question this list answers is what the target IS,
/// not what the status says.
public enum RedirectEndpoints {
    public static let all: Set<EndpointID> = [.callRecordingUrl, .schedulingAdminDownload]
}

/// The endpoints that answer a **bare JSON array** instead of the
/// `{success, …}` envelope almost every district route uses.
///
/// ⛔ DO NOT ADD A SYNTHETIC WRAPPER FOR THESE. `NextResponse.json(rows)` is what
/// the routes do; there is no `success` flag to check, and an empty array is a
/// legitimate answer that no envelope guard could distinguish from a broken read
/// anyway. A DTO that expected an object fails to decode every response these
/// routes send.
///
/// ⚠️ TWO OF THEM, AND THEY ARE EASY TO MISS BECAUSE THEIR SIBLINGS ARE
/// ENVELOPED: `calls` (while `calls/{id}` is enveloped) and `meetings` (while
/// `meetings/{id}` is a bare OBJECT, itself unlike both).
///
/// ⚠️ THE SUPPORT FAMILY IS NOT HERE AND MUST NOT BE ADDED. All five of its routes
/// carry the ordinary `{success, …}` envelope, including the list — which is what
/// makes `ResponseEnvelope.affirm` reachable on the one read where "we could not
/// look" rendered as "you have no support requests" is the expensive mistake.
public enum BareArrayEndpoints {
    public static let all: Set<EndpointID> = [.calls, .meetings]
}
