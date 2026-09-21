import Foundation

/// Minimal, VALID District Desk bodies.
///
/// ⚠️ WRITTEN FROM THE ROUTE SOURCE, NOT FROM A CONTRACT FIXTURE, because there is no
/// desk fixture in the contract corpus — the corpus mirrors the Kotlin client and
/// that client has no desk. Every required key is present and nothing else
/// is, so a test can be about envelope handling rather than about JSON.
///
/// ⛔ THESE ARE NOT CONTRACT FIXTURES AND MUST NOT DRIFT INTO PRETENDING TO BE. What
/// pins a wire shape in this project is the corpus and its strict decode/re-encode
/// walk; what lives here is the smallest body that satisfies the Swift type. The desk
/// has none of the former, which is recorded in `EndpointClassification+Desk.swift`
/// rather than papered over here.
///
/// ⚠️ ITS OWN FILE because two suites share it — the same reason `MessagingTestBodies`
/// and `WorkflowTestBodies` have one.
enum DeskBodies {
    static func settings(enabled: Bool, success: Bool = true) -> String {
        #"""
        {"success":\#(success),"settings":{"enabled":\#(enabled),"notifyCustomersByEmail":true,
         "publicBrandName":"Contoso","publicLogoUrl":"https://cdn.example/logo.png"}}
        """#
    }

    /// ⚠️ BOTH BRANDING COLUMNS EXPLICITLY NULL, which is what the route sends for a
    /// workspace that has set neither: it serialises its Prisma selection whole.
    static func settingsWithoutBranding() -> String {
        #"""
        {"success":true,"settings":{"enabled":true,"notifyCustomersByEmail":true,
         "publicBrandName":null,"publicLogoUrl":null}}
        """#
    }

    static func logoRemoval(objectRemoved: Bool, success: Bool = true) -> String {
        #"""
        {"success":\#(success),"objectRemoved":\#(objectRemoved),
         "settings":{"enabled":true,"notifyCustomersByEmail":true,
         "publicBrandName":null,"publicLogoUrl":null}}
        """#
    }

    static func summary(
        id: String,
        status: String = "open",
        source: String = "manual",
        resolvedAt: String = "null"
    ) -> String {
        #"""
        {"id":"\#(id)","reference":7,"displayReference":"T-7","subject":"Refund not received",
         "status":"\#(status)","source":"\#(source)","contactId":null,"requesterName":"Ada Lovelace",
         "requesterEmail":null,"requesterPhone":"+15555550111","createdAt":"2026-09-06T09:41:00.000Z",
         "updatedAt":"2026-09-06T09:45:00.000Z","resolvedAt":\#(resolvedAt),"messageCount":2}
        """#
    }

    // ⚠️ THERE IS DELIBERATELY NO SWIFT-SIDE `expectedSummary` HERE. A memberwise
    // initialiser for ``DeskTicketSummary`` is internal to `DistrictModel`, and making
    // it public purely so a test could build one would add production API that only a
    // test calls — which under the 100% coverage floor is a public surface nothing in
    // the app exercises. Assert the fields that matter instead.

    static func tickets(ids: [String], status: String = "open", source: String = "manual") -> String {
        let rows = ids.map { summary(id: $0, status: status, source: source) }.joined(separator: ",")
        return #"{"success":true,"tickets":[\#(rows)]}"#
    }

    static func createdTicket(id: String) -> String {
        #"{"success":true,"ticket":\#(summary(id: id))}"#
    }

    static func ticketDetail(id: String, lastAuthor: String = "team") -> String {
        #"""
        {"success":true,"ticket":{"id":"\#(id)","reference":7,"displayReference":"T-7",
         "subject":"Refund not received","status":"waiting","source":"manual","contactId":null,
         "requesterName":"Ada Lovelace","requesterEmail":null,"requesterPhone":"+15555550111",
         "createdAt":"2026-09-06T09:41:00.000Z","updatedAt":"2026-09-06T09:45:00.000Z",
         "resolvedAt":null,"messageCount":2,"messages":[
         {"id":"msg_1","authorType":"customer","body":"Ordered on the 3rd.",
          "createdAt":"2026-09-06T09:41:00.000Z"},
         {"id":"msg_2","authorType":"\#(lastAuthor)","body":"Looking into it.",
          "createdAt":"2026-09-06T09:45:00.000Z"}]}}
        """#
    }

    static func reply(notified: Bool, deduplicated: Bool = false) -> String {
        let flag = deduplicated ? #","deduplicated":true"# : ""
        return #"""
        {"success":true\#(flag),"notified":\#(notified),
         "ticket":\#(summary(id: "tkt_a", status: "waiting")),
         "message":{"id":"msg_9","authorType":"team","body":"Refunded this morning.",
          "createdAt":"2026-09-06T10:00:00.000Z"}}
        """#
    }

    /// ⚠️ A REAL REPLY WITH THE `notified` KEY MISSING — contract drift rather than a
    /// shape the route sends, which is exactly why the fallback needs pinning.
    static func replyWithoutNotified() -> String {
        #"""
        {"success":true,"ticket":\#(summary(id: "tkt_a", status: "waiting")),
         "message":{"id":"msg_9","authorType":"team","body":"Refunded this morning.",
          "createdAt":"2026-09-06T10:00:00.000Z"}}
        """#
    }

    static func replyWithoutMessage() -> String {
        #"""
        {"success":true,"notified":false,"ticket":\#(summary(id: "tkt_a", status: "waiting"))}
        """#
    }

    static func statusEcho(status: String) -> String {
        #"""
        {"success":true,"ticket":\#(summary(
            id: "tkt_a",
            status: status,
            resolvedAt: #""2026-09-06T10:00:00.000Z""#
        ))}
        """#
    }
}
