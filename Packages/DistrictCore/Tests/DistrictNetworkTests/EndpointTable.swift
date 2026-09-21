@testable import DistrictNetwork
import Foundation

/// One expected request, spelled out independently of the code that builds it.
struct EndpointExpectation {
    let id: EndpointID
    let descriptor: ApiRequestDescriptor
    let method: HTTPMethod
    /// The absolute URL, path and query together, so the encoding is asserted as
    /// one string rather than field by field.
    let url: String
    let body: ExpectedBody

    init(
        _ id: EndpointID,
        _ descriptor: ApiRequestDescriptor,
        _ method: HTTPMethod,
        _ url: String,
        _ body: ExpectedBody = .none
    ) {
        self.id = id
        self.descriptor = descriptor
        self.method = method
        self.url = url
        self.body = body
    }
}

enum ExpectedBody: Equatable {
    case none
    /// The exact bytes, with keys sorted — see ``JSONWire/encode(_:)``.
    case json(String)
    /// ⛔ THE FIELDS AND FILENAME ARE CARRIED PER ROW, AND THEY DID NOT USED TO BE.
    /// While `messages/media` was the only multipart route, the suite asserted one
    /// hard-coded `["workspaceId": "ws_1"]` for every multipart body — which was
    /// true of the only row that existed and would have been a false green for the
    /// second. `desk/logo` sends NO form fields at all, because it reads the
    /// workspace off the query string instead, and that is precisely the difference
    /// worth pinning: a part list copied from the media upload leaves the desk
    /// route's `requireWorkspaceRole` with null while the URL looks correct.
    case multipart(fields: [String: String], fileName: String)
}

/// The whole endpoint surface, written out by hand.
///
/// ⛔ HAND-WRITTEN ON PURPOSE. A table derived from the same constants the
/// endpoints are built from would assert that the code equals itself. These
/// strings were read off `HttpDistrictApi.kt` and its `DistrictPaths` in the
/// Kotlin client, which is the artefact the server contract was verified against.
///
/// ⛔ EVERY `EndpointID` MUST APPEAR EXACTLY ONCE. `EndpointTableTests` asserts
/// that, so adding a route without a row here fails the suite rather than
/// shipping untested.
///
/// ⚠️ SPLIT ACROSS FILES AND INTO SMALL GROUPS because SwiftLint caps a file at
/// 500 lines and a function body at 60 — and the cap is doing something useful
/// here rather than being worked around: the groups match the sections
/// `HttpDistrictApi.kt` is itself split into.
enum EndpointTable {
    static let host = "https://www.distronode.com"

    static func all() -> [EndpointExpectation] {
        core() + setup() + callLog() + telephony()
            + contactReads() + contactWrites() + dgi() + blocking()
            + inboxReads() + inboxWrites()
            + composerReads() + composerWrites() + hq() + usage() + numbers()
            + configReads() + configWrites() + persona() + callHandling() + knowledge()
            + deskSettings() + deskTickets()
            + messagingReads() + messagingActions()
            + membership() + workflows() + devices() + scheduling() + schedulingAdmin() + support()
            + numberRegistrations() + numberDocuments() + numberWrites()
            + carrierCompliance() + sipTrunking() + verifyAndLookup()
    }

    /// ⚠️ Force-unwrapped in TEST code only, and the guard it proves is asserted
    /// separately in `RoomNameTests`: `meet_` is the one prefix ``RoomName``
    /// accepts, so this cannot be nil unless that guard changed — in which case
    /// the crash is the signal.
    static let meetingRoom = RoomName("meet_standup")!

    static let providerConfig = JSONValue.object(["accountSid": .string("AC1")])
}
