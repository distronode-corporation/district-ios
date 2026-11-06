@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// A transport for the app parity tests (DistrictCore 8.2.0): it answers by route, the
/// last path segments and the method, and records every request it was sent.
///
/// ⚠️ AN UNSCRIPTED ROUTE ANSWERS 500, so a test that reaches a request it did not
/// expect fails on the result rather than hanging.
final class ParityTransport: HTTPTransport, @unchecked Sendable {
    struct Sent {
        let method: HTTPMethod
        let url: URL
        let body: String

        var path: String {
            url.path
        }

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }

        /// The body as a JSON object, for asserting on keys.
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        }
    }

    private let lock = NSLock()
    private var routes: [String: [(Int, String)]] = [:]
    private var holds: [String: [ParityGate]] = [:]
    private var sent: [Sent] = []

    /// Queue an answer for `method` on the path ending in `suffix`.
    func on(_ method: HTTPMethod, _ suffix: String, _ status: Int = 200, _ body: String) {
        lock.withLock { routes[Self.key(method, suffix), default: []].append((status, body)) }
    }

    /// Hold the next request on `method` and `suffix` until the returned gate opens: the
    /// request is recorded at once, and its answer waits. For a second tap while one is in
    /// flight, and for an older read that answers last.
    func hold(_ method: HTTPMethod, _ suffix: String) -> ParityGate {
        let gate = ParityGate()
        lock.withLock { holds[Self.key(method, suffix), default: []].append(gate) }
        return gate
    }

    var requests: [Sent] {
        lock.withLock { sent }
    }

    func requests(to suffix: String) -> [Sent] {
        requests.filter { $0.path.hasSuffix(suffix) }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        // ⚠️ THE ANSWER IS CHOSEN ON ARRIVAL, BEFORE ANY HOLD: a held request answers with
        // what was next when it was sent, however late it is let go.
        let (answer, held): ((Int, String)?, ParityGate?) = lock.withLock {
            sent.append(Sent(
                method: request.method,
                url: request.url,
                body: request.body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            ))
            var gate: ParityGate?
            for (key, gates) in holds where !gates.isEmpty {
                let (method, suffix) = Self.split(key)
                guard method == request.method.rawValue, request.url.path.hasSuffix(suffix) else { continue }
                gate = holds[key]?.removeFirst()
                break
            }
            for (key, queue) in routes where !queue.isEmpty {
                let (method, suffix) = Self.split(key)
                guard method == request.method.rawValue, request.url.path.hasSuffix(suffix) else { continue }
                return (routes[key]?.count == 1 ? queue[0] : routes[key]?.removeFirst(), gate)
            }
            return (nil, gate)
        }
        await held?.wait()
        guard let (status, body) = answer else {
            return HTTPResponse(statusCode: 500, headers: [:], body: nil)
        }
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func key(_ method: HTTPMethod, _ suffix: String) -> String {
        "\(method.rawValue) \(suffix)"
    }

    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts[0], parts[1])
    }
}

/// One held answer (``ParityTransport/hold(_:_:)``): the request waits until ``open()``.
final class ParityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isOpen {
                    return true
                }
                waiting = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let continuation = lock.withLock {
            isOpen = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// The client every parity test reads through.
enum ParityFixtures {
    static func client(_ transport: ParityTransport) -> ApiClient {
        ApiClient(baseURL: ApiClient.productionBaseURL, transport: transport, accessToken: { "session-token" })
    }

    static func inbox(_ transport: ParityTransport) -> InboxRepository {
        InboxRepository(client: client(transport), options: InboxParity.readOptions)
    }

    /// One `conversations` row in the 8.2.0 shape, `replyOptions` and the assignment
    /// keys included. `replyOptions` is raw JSON so a test can put anything in it.
    static func row(
        threadKey: String,
        counterpart: String,
        channels: [String],
        canSms: Bool = false,
        canEmail: Bool = false,
        replyOptions: String,
        assigneeEmail: String? = nil,
        assignedToMe: Bool = false
    ) -> String {
        let channelList = channels.map { "\"\($0)\"" }.joined(separator: ",")
        let assignee = assigneeEmail.map { "\"\($0)\"" } ?? "null"
        return """
        {"key":"\(counterpart)","threadKey":"\(threadKey)","counterpart":"\(counterpart)",
         "matchKeys":["\(counterpart)"],"kind":"phone","channels":[\(channelList)],
         "contactId":null,"contactName":null,"contactEmail":null,"contactPhone":null,
         "canSms":\(canSms),"canEmail":\(canEmail),
         "lastMessage":{"body":"Hi","direction":"inbound","type":"\(channels.first ?? "sms")",
          "status":"received","createdAt":"2026-08-15T14:40:00.000Z"},
         "unreadCount":1,"totalMessages":1,"replyOptions":\(replyOptions),
         "assigneeEmail":\(assignee),"assignedToMe":\(assignedToMe)}
        """
    }

    static func conversations(_ rows: [String]) -> String {
        #"{"success":true,"conversations":["# + rows.joined(separator: ",") + #"],"scanned":3,"scanLimit":500}"#
    }

    /// Read `rows` through the real repository and decoder.
    @MainActor
    static func summaries(_ rows: [String]) async -> [ConversationSummary] {
        let transport = ParityTransport()
        transport.on(.get, "/conversations", 200, conversations(rows))
        guard case let .success(list) = await inbox(transport).conversations(workspaceId: "ws_1") else { return [] }
        return list.conversations
    }

    static let timeline = #"""
    {"success":true,"timeline":[{"id":"msg_1","type":"whatsapp","timestamp":"2026-08-15T14:05:00.000Z",
     "direction":"inbound","body":"Hi, do you do flat roofs?","status":"received"}],
     "pageInfo":{"hasMore":false,"oldest":"2026-08-15T14:05:00.000Z","oldestId":"msg_1"}}
    """#

    /// The thread behind the closed-window screenshots (04 and 12): the operator's
    /// WhatsApp reply, then the customer's answer.
    ///
    /// ⛔ THE REPLY IS `delivered` EVEN THOUGH THE CUSTOMER HAS READ IT. The service never
    /// stores or sends `read`: Meta's read receipts, Twilio's `read` and the history
    /// import all record `delivered` (the website's `lib/whatsapp/status.ts` and
    /// `webhooks/twilio/message-status`). The first screenshots' seed said `read`, which the
    /// vocabulary before DistrictCore 8.2.0 did not list, so its badge read "read" and
    /// « Autre »; 8.2.0 names it (Read / « Lu ») only so a stray one never shows a wire word.
    static let answeredTimeline = #"""
    {"success":true,"timeline":[
     {"id":"msg_3","type":"whatsapp","timestamp":"2026-11-03T16:00:00.000Z",
      "direction":"outbound","body":"Your appointment is booked for Tuesday at 9.","status":"delivered"},
     {"id":"msg_4","type":"whatsapp","timestamp":"2026-11-03T16:10:00.000Z",
      "direction":"inbound","body":"Thanks, see you next week.","status":"received"}],
     "pageInfo":{"hasMore":false,"oldest":"2026-11-03T16:00:00.000Z","oldestId":"msg_3"}}
    """#

    static let sent = #"""
    {"success":true,"message":{"id":"msg_2","messageSid":"SM_1","workspaceId":"ws_1",
     "from":"+16475550100","to":"+14165550177","body":"On my way.","direction":"outbound",
     "type":"whatsapp","status":"queued","createdAt":"2026-08-15T14:30:00.000Z","externalId":"SM_1",
     "provider":"meta","accountId":"acct_1"}}
    """#

    static let windowOpen = #"""
    {"success":true,"window":{"open":true,"expiresAt":"2026-08-16T14:05:00.000Z"},
     "senderId":"wa_sender_1","receivedOn":"+16475550100"}
    """#

    static let windowClosed = #"""
    {"success":true,"window":{"open":false,"expiresAt":null},"senderId":"wa_sender_1","receivedOn":null}
    """#

    /// The service's fixture: one approved template with two variables, one pending.
    static let templates = #"""
    {"success":true,"templates":[
     {"id":"wa_tpl_reminder","senderId":null,"name":"appointment_reminder","language":"en_US",
      "category":"UTILITY","status":"approved",
      "body":"Hi {{1}}, this is a reminder of your appointment on {{2}}.","variableCount":2},
     {"id":"wa_tpl_named","senderId":"wa_sender_1","name":"follow_up","language":"fr_CA",
      "category":"MARKETING","status":"pending","body":"Bonjour {{first_name}}, merci de votre visite.",
      "variableCount":null}]}
    """#

    @MainActor
    static func thread(
        _ transport: ParityTransport,
        role: WorkspaceRole = .client,
        threadKey: String = "addr:14165550177",
        targets: [ReplyTarget]
    ) -> ThreadModel {
        ThreadModel(
            inbox: inbox(transport),
            workspaceId: "ws_1",
            role: role,
            threadKey: threadKey,
            replyTargets: targets
        )
    }
}
