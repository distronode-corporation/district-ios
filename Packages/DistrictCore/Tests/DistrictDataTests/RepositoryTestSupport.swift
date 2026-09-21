import DistrictModel
import DistrictNetwork
import Foundation

extension ApiError {
    /// True when this is ``ApiErrorNormalizer``'s own "a 2xx did not decode"
    /// outcome.
    ///
    /// ⚠️ MATCHED BY PREFIX RATHER THAN IN FULL, because the sentence carries the
    /// response's BYTE COUNT — deliberately, so "the server sent nothing" can be
    /// told apart from "the server sent a shape we do not know" — and a test that
    /// pinned the whole string would have to hard-code the length of every
    /// fixture body it uses. ⛔ It carries no body preview at all: these bodies
    /// are call transcripts and contact records, and ``ApiError/message`` can
    /// reach a screen.
    var isShapeMismatch: Bool {
        guard case let .decoding(reason) = self else { return false }
        return reason.hasPrefix("The server's response did not match")
    }
}

/// The ``HTTPTransport`` double for the repository tests.
///
/// ⚠️ A SECOND COPY OF THE ONE IN `DistrictNetworkTests`, on purpose: SwiftPM test
/// targets do not share code, and a shared helper target would have to be a
/// product of the package. It is small enough that duplicating it costs less than
/// widening the package's public surface.
final class RepositoryTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    convenience init(json: String, status: Int = 200) {
        self.init([
            HTTPResponse(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            ),
        ])
    }

    /// A queue of JSON bodies, all 200, answered in order.
    ///
    /// ⚠️ ADDED WITH THE COMPOSER TESTS, which drive several calls through one
    /// repository (open a thread, restore its draft, send, mark read) and would
    /// otherwise need a `HTTPResponse` literal per step.
    convenience init(queue: [String]) {
        self.init(queue.map {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data($0.utf8))
        })
    }

    convenience init(redirectTo location: String) {
        self.init([HTTPResponse(statusCode: 302, headers: ["Location": location], body: nil)])
    }

    var requestedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.url.absoluteString)
    }

    /// The request bodies, as UTF-8, in the order they were sent.
    ///
    /// ⛔ ASSERTING THE BYTES IS THE ONLY WAY TO PIN A DROPPED KEY. `contacts/update`
    /// rebuilds every column it is sent from the body, so "did this request carry a
    /// phoneNumber" is a question about the encoded document rather than about the
    /// arguments — and ``JSONValue/object(_:)`` drops a nil pair silently by design.
    /// ``JSONWire/encode(_:)`` sorts keys, so the comparison is deterministic.
    ///
    /// ⚠️ A REQUEST WITH NO BODY IS SKIPPED, NOT RENDERED AS `""`. `contacts/delete`
    /// is DELETE-with-query-and-no-body, and an empty string there would read as a
    /// body that was sent and happened to be empty.
    var bodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.body).compactMap { String(data: $0, encoding: .utf8) }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        // ⚠️ `withLock`, not `lock()`/`unlock()`, which are unavailable from an
        // async context.
        let next: HTTPResponse? = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let next else {
            return HTTPResponse(statusCode: 500, headers: [:], body: nil)
        }
        return next
    }
}

extension ApiClient {
    static func repositoryTest(_ transport: RepositoryTransport) -> ApiClient {
        ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        )
    }
}

/// Minimal, VALID bodies for the DTOs the core surface decodes.
///
/// ⛔ EVERY REQUIRED KEY IS PRESENT AND NOTHING ELSE IS, WHICH IS THE POINT.
/// Before the read surface was typed these tests could assert against
/// `{"success":true,"call":{"id":"call_1"}}`; a DTO makes that body a decode
/// failure, and writing each one out by hand at every call site would bury the
/// one field a test is actually about in twenty that it is not.
///
/// ⚠️ THESE ARE NOT THE CONTRACT FIXTURES AND MUST NOT DRIFT INTO PRETENDING TO
/// BE. The shared contract corpus is what pins the wire shape,
/// through `ContractFixtureTests` and its strict decode/re-encode walk. What
/// lives here is the smallest body that satisfies the Swift type, so a repository
/// test can be about envelope handling, paging or path construction rather than
/// about JSON.
enum Bodies {
    /// One `CallSummary`, with every non-optional field and no optional ones.
    static func call(id: String) -> String {
        #"""
        {"id":"\#(id)","type":"inbound","number":"Ada Lovelace","status":"completed",
         "duration":"1m 5s","time":"9:41 AM","aiSummary":"Booked a survey.","transcript":"",
         "callerName":"Ada Lovelace","summary":"Booked a survey.","createdAt":"2026-08-19T09:41:00.000Z"}
        """#
    }

    static func calls(ids: [String]) -> String {
        "[" + ids.map(call(id:)).joined(separator: ",") + "]"
    }

    static func callDetail(id: String) -> String {
        #"{"success":true,"call":\#(call(id: id))}"#
    }

    /// One `Contact` row, with every non-optional field and no optional ones.
    static func contact(id: String, name: String = "Ada Lovelace") -> String {
        #"""
        {"id":"\#(id)","workspaceId":"ws_1","name":"\#(name)","createdAt":"2026-08-19T09:41:00.000Z"}
        """#
    }

    static func contactPage(ids: [String], total: Int, limit: Int = 25, offset: Int = 0) -> String {
        let rows = ids.map { contact(id: $0) }.joined(separator: ",")
        return #"""
        {"success":true,"contacts":[\#(rows)],"total":\#(total),"limit":\#(limit),"offset":\#(offset)}
        """#
    }

    static func contactDetail(id: String) -> String {
        #"{"success":true,"contact":\#(contact(id: id))}"#
    }

    static func overview(
        workspaceId: String = "ws_1",
        role: String = "agency",
        totalCalls: Int = 128,
        recentCallIds: [String] = ["call_1"]
    ) -> String {
        #"""
        {"success":true,"workspaceId":"\#(workspaceId)","role":"\#(role)",
         "metrics":{"totalCalls":\#(totalCalls),"callsThisWeek":9,"totalContacts":42,"avgDuration":192},
         "avgDurationLabel":"3m 12s","recentCalls":\#(calls(ids: recentCallIds))}
        """#
    }

    static func workspaceEntry(
        id: String,
        name: String = "North Studio",
        region: String = "us",
        role: String = "agency"
    ) -> String {
        #"{"id":"\#(id)","name":"\#(name)","region":"\#(region)","role":"\#(role)"}"#
    }

    static func workspaceList(
        entries: [String] = [],
        degradedRegions: [String] = [],
        inactiveCount: Int = 0,
        defaultWorkspaceId: String? = nil
    ) -> String {
        let rows = entries.joined(separator: ",")
        let degraded = degradedRegions.map { #""\#($0)""# }.joined(separator: ",")
        // ⚠️ The key is OMITTED rather than sent as null when there is no stored
        // preference, which is what the route does and what the DTO's Optional
        // therefore means.
        let stored = defaultWorkspaceId.map { #","defaultWorkspaceId":"\#($0)""# } ?? ""
        return #"""
        {"success":true,"workspaces":[\#(rows)],"degradedRegions":[\#(degraded)],
         "inactiveCount":\#(inactiveCount),"total":\#(entries.count),"limit":25,"offset":0\#(stored)}
        """#
    }

    /// One Inbox thread.
    ///
    /// - Parameter contactId: nil produces an UNRESOLVED thread, whose selector
    ///   falls back to the counterpart address.
    static func conversation(
        threadKey: String,
        counterpart: String = "+14165550134",
        contactId: String? = "c_1",
        canSms: Bool = true,
        canEmail: Bool = false,
        unreadCount: Int = 0
    ) -> String {
        let contact = contactId.map {
            #""contactId":"\#($0)","contactName":"Ada Lovelace","contactPhone":"+14165550134","#
        } ?? ""
        return #"""
        {"key":"\#(counterpart)","threadKey":"\#(threadKey)","counterpart":"\#(counterpart)",
         "matchKeys":["\#(counterpart)"],"kind":"sms","channels":["sms"],\#(contact)
         "canSms":\#(canSms),"canEmail":\#(canEmail),
         "lastMessage":{"body":"On my way.","direction":"inbound","type":"sms","status":"received",
                        "createdAt":"2026-08-19T09:41:00.000Z"},
         "unreadCount":\#(unreadCount),"totalMessages":7}
        """#
    }

    static func conversations(_ rows: [String], scanned: Int = 12, scanLimit: Int = 500) -> String {
        #"""
        {"success":true,"conversations":[\#(rows.joined(separator: ","))],
         "scanned":\#(scanned),"scanLimit":\#(scanLimit)}
        """#
    }

    static func draft(threadKey: String, body: String = "Thanks, booking that now.") -> String {
        #"""
        {"threadKey":"\#(threadKey)","body":"\#(body)","mediaUrls":[],
         "updatedAt":"2026-08-19T09:41:00.000Z"}
        """#
    }

    /// A usable dial credential.
    ///
    /// ⚠️ THE ROOM NAME EMBEDS THE CALL ID AND CARRIES THE `direct_` PREFIX,
    /// because both are properties the server guarantees and a screen reads: the
    /// prefix is what the voice agent refuses BY NAME, so a body without it would
    /// be a room an AI joins.
    static func dial(callId: String = "CA1") -> String {
        #"""
        {"success":true,"callId":"\#(callId)","roomName":"direct_ws_1-\#(callId)",
         "token":"contract-livekit-dial-jwt","url":"wss://livekit-wss.distronode.com"}
        """#
    }

    /// ⛔ THE COMPLIANCE REFUSAL, AND IT PUBLISHES NO `code`. Its only marks are
    /// an explicit `success:false` and the 403 it arrives with; see the ⛔ on
    /// `DialRepository`.
    static let dncRefusal = #"""
    {"success":false,"error":"This number has opted out of calls from this workspace (DNC)."}
    """#

    /// ⚠️ CARRIES `status` AS WELL, which `ApiErrorEnvelope` deliberately does not
    /// model — the repository branches on `code` and never decodes that key, so
    /// the extra field being ignored here is the behaviour under test.
    ///
    /// ⛔ THE SENTENCE IS BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE
    /// JSON, and the same goes for the dormancy body below. A raw multi-line
    /// string may break between JSON tokens (`Bodies.overview` does), but a
    /// newline INSIDE a string value is invalid JSON — and the failure it
    /// produces is a decode error in the repository under test, which reads as a
    /// bug in the code rather than in the fixture.
    static let subscriptionRefusal =
        #"{"success":false,"error":"\#(lapsedMessage)","code":"subscription_inactive","status":"past_due"}"#

    static let lapsedMessage = "This workspace's subscription is not active. "
        + "Please update billing to resume calls and messaging."

    /// ⚠️ THE DNC SHAPE PLUS A `code`, which is exactly why the code is matched
    /// first.
    static let dormantRefusal = #"{"success":false,"error":"\#(dormantMessage)","code":"workspace_dormant"}"#

    static let dormantMessage = "This workspace has not sent anything for 100 days, so outbound "
        + "calling and messaging are paused pending an account review. Request reactivation from "
        + "your dashboard and we will re-enable it."

    /// The SMS branch of `messages/send`, which carries `externalId` and
    /// `accountId` and no `subject`.
    static func sentSms(id: String = "m_1", to: String = "+14165550134") -> String {
        #"""
        {"success":true,"message":{"id":"\#(id)","messageSid":"SM1","workspaceId":"ws_1",
         "from":"+14165550150","to":"\#(to)","body":"On our way.","direction":"outbound",
         "type":"sms","status":"queued","createdAt":"2026-08-19T09:41:00.000Z",
         "externalId":"SM1","provider":"twilio","accountId":"acct-1"}}
        """#
    }
}
