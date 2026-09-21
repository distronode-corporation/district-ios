@testable import DistrictAI
import DistrictData
import DistrictNetwork
import Foundation

/// A transport that answers by OPERATION rather than by position in a queue.
///
/// ⛔ A QUEUE CANNOT MODEL THESE SCREENS, AND THE FIRST VERSION OF THESE TESTS PROVED IT.
/// Every scheduling model issues its independent reads inside a `withTaskGroup`, so the
/// order they reach the transport in is genuinely nondeterministic — a positional
/// `SettingsTransport` handed the calendar's refusal to whichever request happened to
/// arrive third, and the assertions passed or failed on scheduler timing. Routing on the
/// `op` name makes each read's answer stable no matter what order they run in, which is
/// the only way to assert "one row failed and the others survived" at all.
///
/// ⚠️ IT STILL RECORDS EVERY REQUEST, so a test can assert WHICH ops a model sent and how
/// many — which is the property that catches a model quietly adding or dropping a read.
///
/// ⛔ AND AN UNCONFIGURED OP ANSWERS 500 RATHER THAN HANGING OR CRASHING. A model that
/// grows a read its test did not anticipate fails on an assertion about behaviour instead
/// of on a fatal error somewhere inside the client.
final class SchedulingTestTransport: HTTPTransport, @unchecked Sendable {
    /// One canned answer.
    struct Reply {
        let status: Int
        let body: String

        /// The admin envelope's success shape.
        static func data(_ json: String) -> Reply {
            Reply(status: 200, body: #"{"ok":true,"data":\#(json)}"#)
        }

        /// ⛔ A **200** CARRYING `{ok:false}` — our route was satisfied and the SCHEDULER
        /// refused. This is the shape a repository double could never produce, and it is
        /// the most common real refusal on this surface.
        static func refused(_ failure: String) -> Reply {
            Reply(status: 200, body: #"{"ok":false,"failure":"\#(failure)"}"#)
        }

        /// A refusal from OUR route, before the scheduler was asked.
        static func http(_ status: Int, error: String) -> Reply {
            Reply(status: status, body: #"{"error":"\#(error)"}"#)
        }
    }

    private let lock = NSLock()
    private var replies: [String: Reply]
    private(set) var ops: [String] = []
    private(set) var paths: [String] = []

    /// - Parameter replies: keyed by the `op` name for the admin route, and by the last
    ///   path component for everything else (`status`, `members`).
    init(_ replies: [String: Reply]) {
        self.replies = replies
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let key = Self.key(for: request)
        return lock.withLock {
            paths.append(request.url.path)
            if request.url.path.hasSuffix("/scheduling/admin") {
                ops.append(key)
            }
            guard let reply = replies[key] else {
                return HTTPResponse(
                    statusCode: 500,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"no stub for \#(key)"}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: reply.status,
                headers: ["Content-Type": "application/json"],
                body: Data(reply.body.utf8)
            )
        }
    }

    /// ⚠️ THE `op` IS READ OUT OF THE BODY, because every admin call posts to ONE path.
    /// That is the whole design of the catalog route — a name rather than a path — so the
    /// body is the only place the request says what it wants.
    private static func key(for request: HTTPRequest) -> String {
        guard request.url.path.hasSuffix("/scheduling/admin") else {
            return request.url.lastPathComponent
        }
        return op(in: request.body) ?? request.url.lastPathComponent
    }

    private static func op(in body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return json["op"] as? String
    }
}

/// ⚠️ THE FIXTURES HANG OFF ``SchedulingTestTransport/Reply`` RATHER THAN OFF THE
/// TRANSPORT, because that is the type the stub dictionary's VALUES have — so
/// `["status": .readyStatus()]` resolves. Declared on the transport they were unreachable
/// from the literal that needs them.
extension SchedulingTestTransport.Reply {
    /// A `ready` tenancy, with every field ``SchedulingTenant`` requires.
    ///
    /// ⛔ `region` AND `hasCredentials` ARE NON-OPTIONAL AND OMITTING THEM MAKES THE WHOLE
    /// `tenant` DECODE FAIL — silently, to nil, which reads on screen as a workspace with
    /// no booking page. The first version of these fixtures left both out and the symptom
    /// was an event type reporting "Not public" with no error anywhere. Build tenants
    /// through this helper rather than by hand.
    static func readyStatus(
        host: String = "acme.example.com",
        canManage: Bool = true
    ) -> Self {
        Self(status: 200, body: """
        {"eligible":true,"canManage":\(canManage),
         "tenant":{"status":"ready","publicHost":"\(host)","region":"us",
         "hasCredentials":true,"bookingUrl":"https://\(host)/book"}}
        """)
    }

    /// A tenancy that is still being created: no booking address yet.
    static func provisioningStatus() -> Self {
        Self(status: 200, body: """
        {"eligible":true,"canManage":true,
         "tenant":{"status":"provisioning","publicHost":"","region":"us","hasCredentials":false}}
        """)
    }

    /// A profile, for the timezone every stamp is rendered in.
    static func me(timezone: String = "UTC") -> Self {
        .data("""
        {"id":"u1","email":"a@b.com","name":"Ada","timezone":"\(timezone)",
         "time_format":"24h","week_start":1,"date_format":"dmy","is_admin":true,
         "is_owner":false,"role":"admin","notify_confirmation":true,
         "notify_cancellation":true,"notify_reschedule":true,"notify_reminder":true,
         "notify_host_booking":true,"notify_host_cancel":true,"notify_host_reschedule":true}
        """)
    }
}
