import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// The negative tests: what this client must NOT be able to ask for.
///
/// ⛔ THESE ASSERT THE ABSENCE OF A CAPABILITY, WHICH IS THE ONLY KIND OF TEST
/// THAT CAN PIN A GUARD LIKE THIS. A comment asking nobody to build
/// `calls/outbound` is not a control; a test that walks the entire expressible
/// surface and finds it absent is.
final class EndpointSurfaceTests: XCTestCase {
    /// ⛔ `calls/outbound` IS THE AI CAMPAIGN DIALER. It creates a `call_` room the
    /// voice agent joins and speaks in, so a human dialling through it would find
    /// an agent on their own line. It has no `EndpointID`, no ``DistrictPaths``
    /// constant, and — because ``ApiRequestDescriptor``'s initialiser is internal
    /// — no way to be assembled from outside this module.
    func testTheOutboundCampaignDialerIsNotReachable() {
        for row in EndpointTable.all() {
            XCTAssertFalse(
                row.descriptor.segments.contains("outbound"),
                "\(row.id.rawValue) addresses calls/outbound"
            )
        }
        XCTAssertNil(
            EndpointID(rawValue: "callsOutbound"),
            "an EndpointID for the campaign dialer would make it expressible"
        )
        // The three routes that DO exist under `calls/` and are ported, so the
        // assertion above is not passing merely because the family is empty.
        XCTAssertEqual(DistrictPaths.callsDial, ["api", "district", "calls", "dial"])
        XCTAssertEqual(DistrictPaths.callsToken, ["api", "district", "calls", "token"])
        XCTAssertEqual(
            DistrictPaths.callAnswer("call_1"),
            ["api", "district", "calls", "call_1", "answer"]
        )
    }

    /// ⛔ NO ENDPOINT MAY CARRY A `video_` ROOM NAME. The only route that takes a
    /// room name at all is `calls/token`, and it takes a ``RoomName``.
    func testNoEndpointCanCarryABillableAvatarRoom() throws {
        for row in EndpointTable.all() {
            guard case let .json(value) = row.descriptor.body else { continue }
            let encoded = try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
            XCTAssertFalse(
                encoded.contains(RoomName.billableAvatarPrefix),
                "\(row.id.rawValue) puts a video_ room on the wire"
            )
        }
    }

    /// ⛔ THE PUSHED MESSAGE ID IS ONE SEGMENT, AND IT IS THE ONLY PATH ARGUMENT ON
    /// THIS SURFACE THAT ARRIVES FROM AN UNAUTHENTICATED SOURCE. A notification
    /// payload is a `[String: String]` the OS hands over; every field of it is a
    /// string the sender chose. An id of `a/../../admin` interpolated into
    /// `messages/{id}` resolves to `/api/district/admin` — the same class of bug the
    /// Kotlin client shipped on `calls/{id}/transcript` before its paths were segment
    /// lists, reached here from a much cheaper direction.
    ///
    /// ⚠️ ASSERTED AGAINST ``ApiPath/build(_:)`` RATHER THAN AGAINST THE ABSOLUTE URL,
    /// which is why `EndpointTable`'s own row uses a plain id. The question is what
    /// the SEGMENT ENCODER does with a `/` inside one segment; routing it through
    /// `URL(string:)` first would be asking Foundation's parser instead.
    func testAPushedMessageIdCannotTraverseIntoAnotherRoute() {
        let descriptor = DistrictEndpoints.messageThread(workspaceId: "ws_1", id: "a/../../admin")
        XCTAssertEqual(
            ApiPath.build(descriptor.segments),
            "/api/district/messages/a%2F..%2F..%2Fadmin"
        )
        // ⚠️ AND THE FAMILY IT SITS IN IS ALL LITERAL WORDS, so the resolver's path is
        // one segment from six sibling routes. Pinned so a refactor that moved the id
        // into the middle, or dropped the `messages` prefix, fails here.
        XCTAssertEqual(
            DistrictPaths.messageThreadTarget("msg_1"),
            ["api", "district", "messages", "msg_1"]
        )
    }

    /// ⛔ `all: true` IS A THIRD SELECTOR ON `messages/mark-read`, NOT A ROUTE, AND
    /// THE ROUTE'S OWN SOURCE IS WHY IT GETS ITS OWN BUILDER. Its comment records
    /// that a selector which resolved to nothing usable must mark ZERO rows, because
    /// "falling through to an empty filter would mark the ENTIRE workspace read" — so
    /// the two bodies are kept apart by two functions rather than by a defaulted
    /// argument, and this asserts that neither can carry the other's keys.
    func testMarkAllReadIsASeparateBodyOnTheSamePathAndCarriesNoSelector() throws {
        let all = DistrictEndpoints.markAllRead(workspaceId: "ws_1")
        XCTAssertEqual(all.id, .markRead, "a second body, not a second endpoint")
        XCTAssertEqual(ApiPath.build(all.segments), "/api/district/messages/mark-read")
        XCTAssertEqual(try encodedBody(all), #"{"all":true,"workspaceId":"ws_1"}"#)

        // ⛔ AND THE PER-THREAD BODY NEVER CARRIES `all`. An `all` key beside a
        // selector would take the route's `if (!all)` branch away and mark the whole
        // workspace read from a control that named one thread.
        let one = DistrictEndpoints.markRead(workspaceId: "ws_1", contactId: "c_1", counterpart: nil)
        XCTAssertEqual(try encodedBody(one), #"{"contactId":"c_1","workspaceId":"ws_1"}"#)
    }

    /// ⛔ AN ISSUE KEY IS ONE SEGMENT, AND THE TWO ROUTES THAT PUT IT IN THE MIDDLE
    /// OF THE PATH ARE THE ONES THAT INVITE INTERPOLATION. A key of
    /// `a/../../admin` interpolated into `support/requests/{key}/close` would
    /// resolve to an entirely different route; the same class of bug the Kotlin
    /// client shipped on `calls/{id}/transcript` before its paths were segment
    /// lists.
    func testASupportKeyCannotTraverseIntoAnotherRoute() {
        let close = DistrictEndpoints.closeSupportRequest(workspaceId: "ws_1", key: "a/../../admin")
        XCTAssertEqual(
            ApiPath.build(close.segments),
            "/api/district/support/requests/a%2F..%2F..%2Fadmin/close"
        )
        let reply = DistrictEndpoints.replyToSupportRequest(
            workspaceId: "ws_1",
            key: "a/../../admin",
            body: "hi"
        )
        XCTAssertEqual(
            ApiPath.build(reply.segments),
            "/api/district/support/requests/a%2F..%2F..%2Fadmin/reply"
        )
    }

    /// ⛔ THE DESK'S REPLY FIELD IS `message` AND THE SUPPORT DESK'S IS `body`.
    /// Transposing them is a silent 400 from a request that reads perfectly well, so
    /// the spelling is asserted on the bytes rather than left to the table's own row.
    ///
    /// ⚠️ IT ALSO PINS THE ABSENCE OF `body`, which is the half a corrected typo
    /// would not restore: a builder that sent BOTH keys would satisfy the route and
    /// still be wrong the day the schema stops being permissive.
    func testTheDeskReplyBodyIsSpelledMessageAndNotBody() throws {
        let descriptor = DistrictEndpoints.replyToDeskTicket(
            workspaceId: "ws_1",
            ticketId: "tkt_1",
            message: "Refunded this morning.",
            idempotencyKey: nil
        )
        guard case let .json(value) = descriptor.body else {
            return XCTFail("the desk reply must carry a JSON body")
        }
        let encoded = try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
        XCTAssertEqual(encoded, #"{"message":"Refunded this morning."}"#)
    }

    /// ⛔ THE DESK LOGO CARRIES ITS WORKSPACE IN THE QUERY AND `messages/media`
    /// CARRIES IT AS A FORM FIELD. Both are multipart, both look identical from the
    /// outside, and copying one part list onto the other leaves a route's
    /// `requireWorkspaceRole` with null while the URL reads correctly.
    ///
    /// ⛔ THERE ARE THREE NOW, AND THE THIRD IS NOT A COPY OF EITHER. The
    /// scheduling admin upload carries the workspace in the QUERY like the desk
    /// logo *and* sends a form field like the media upload, because the two facts
    /// have different deadlines: `workspaceId` has to be readable BEFORE
    /// `req.formData()` so the session check can precede a multipart parse of a
    /// body up to Cloudflare's 100 MB, while `target` cannot be known until after
    /// it. ⚠️ Renaming this to `testTheThreeMultipartRoutes…` was deliberately not
    /// done: the name would have to move again on the fourth, and the assertions
    /// below are what count.
    func testTheTwoMultipartRoutesCarryTheWorkspaceDifferently() {
        let logo = DistrictEndpoints.uploadDeskLogo(
            workspaceId: "ws_1",
            fileName: "logo.png",
            mimeType: "image/png",
            bytes: Data([0x89])
        )
        guard case let .multipart(logoPart) = logo.body else {
            return XCTFail("the desk logo upload must be multipart")
        }
        XCTAssertTrue(logoPart.fields.isEmpty, "the desk logo sends no form fields")
        XCTAssertEqual(logo.query.map(\.name), ["workspaceId"])

        let media = DistrictEndpoints.uploadMedia(
            workspaceId: "ws_1",
            fileName: "photo.jpg",
            mimeType: "image/jpeg",
            bytes: Data([0xFF])
        )
        guard case let .multipart(mediaPart) = media.body else {
            return XCTFail("the media upload must be multipart")
        }
        XCTAssertEqual(mediaPart.fields, ["workspaceId": "ws_1"])
        XCTAssertTrue(media.query.isEmpty, "the media upload sends no query")

        let branding = DistrictEndpoints.schedulingAdminUpload(
            workspaceId: "ws_1",
            target: .banner,
            fileName: "banner.webp",
            mimeType: "image/webp",
            bytes: Data([0x52])
        )
        guard case let .multipart(brandingPart) = branding.body else {
            return XCTFail("the scheduling admin upload must be multipart")
        }
        // ⛔ `target` AND NOT `workspaceId`. A part list copied from the media
        // upload would send the workspace twice and the target never, and the
        // route answers 400 `unknown_target` with a URL that reads correctly.
        XCTAssertEqual(brandingPart.fields, ["target": "banner"])
        XCTAssertEqual(branding.query.map(\.name), ["workspaceId"])
    }

    /// ⚠️ THE QUEUE'S STATUS FILTER IS DROPPED WHEN ABSENT rather than sent empty.
    /// `status=` present-and-empty is not in the route's vocabulary, so it falls
    /// through to "no filter" — the same answer by accident rather than by contract,
    /// and the kind of agreement that stops holding the day the route validates.
    func testTheQueueFilterIsDroppedWhenAbsentAndSentWhenPresent() throws {
        let base = try XCTUnwrap(URL(string: EndpointTable.host))
        let unfiltered = DistrictEndpoints.deskTickets(workspaceId: "ws_1", status: nil)
        XCTAssertEqual(
            ApiURL.build(base: base, segments: unfiltered.segments, query: unfiltered.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/desk/tickets?workspaceId=ws_1"
        )
        let filtered = DistrictEndpoints.deskTickets(workspaceId: "ws_1", status: "waiting")
        XCTAssertEqual(
            ApiURL.build(base: base, segments: filtered.segments, query: filtered.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/desk/tickets?workspaceId=ws_1&status=waiting"
        )
    }

    /// ⛔ CLEARING THE PUBLIC BRAND NAME NEEDS AN EXPLICIT NULL, WHICH IS THE ONE
    /// PLACE THIS CLIENT USES `JSONValue`'S ESCAPE HATCH. `object(_:)` drops a nil
    /// pair by design, so "leave it alone" and "clear it" would be the same bytes if
    /// the parameter were a plain `String?` — and the value being cleared is the
    /// heading a tenant's own customers see.
    func testTheBrandNameDistinguishesLeavingAloneFromClearing() throws {
        let untouched = DistrictEndpoints.saveDeskSettings(
            workspaceId: "ws_1",
            enabled: false,
            notifyCustomersByEmail: nil,
            publicBrandName: nil
        )
        XCTAssertEqual(try encodedBody(untouched), #"{"enabled":false}"#)

        let cleared = DistrictEndpoints.saveDeskSettings(
            workspaceId: "ws_1",
            enabled: nil,
            notifyCustomersByEmail: nil,
            publicBrandName: .clear
        )
        XCTAssertEqual(try encodedBody(cleared), #"{"publicBrandName":null}"#)

        let named = DistrictEndpoints.saveDeskSettings(
            workspaceId: "ws_1",
            enabled: nil,
            notifyCustomersByEmail: true,
            publicBrandName: .set("Contoso")
        )
        XCTAssertEqual(
            try encodedBody(named),
            #"{"notifyCustomersByEmail":true,"publicBrandName":"Contoso"}"#
        )
    }

    private func encodedBody(_ descriptor: ApiRequestDescriptor) throws -> String {
        guard case let .json(value) = descriptor.body else {
            throw XCTSkip("the descriptor carries no JSON body")
        }
        return try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
    }

    /// ⛔ `scheduling/sso` MUST NOT BE EXPRESSIBLE. It answers a **302** whose
    /// `Location` is a ONE-TIME sign-in URL into the tenant's scheduler, so a
    /// descriptor for it would let `ApiClient.send` follow the redirect and spend
    /// the credential on a transport the user never sees — and
    /// `redirectTarget(_:)` would not help, because putting it on
    /// ``RedirectEndpoints`` is what would make it constructible in the first
    /// place. The App target fetches it directly, with redirects disabled.
    ///
    /// ⚠️ `scheduling/webhook/{workspaceId}` is absent for the duller reason that
    /// this client is never its caller; the assertion below covers both, since
    /// neither segment may appear anywhere on the surface.
    func testTheSchedulingSsoAndWebhookRoutesAreNotReachable() {
        for row in EndpointTable.all() {
            XCTAssertFalse(row.descriptor.segments.contains("sso"), "\(row.id.rawValue) addresses scheduling/sso")
            XCTAssertFalse(
                row.descriptor.segments.contains("webhook"),
                "\(row.id.rawValue) addresses the scheduler's inbound webhook"
            )
        }
        XCTAssertNil(EndpointID(rawValue: "schedulingSso"))
        // The two routes in this family that DO exist and are ported, so the
        // assertions above are not passing merely because the family is empty.
        XCTAssertEqual(DistrictPaths.schedulingStatus, ["api", "district", "scheduling", "status"])
        XCTAssertEqual(DistrictPaths.schedulingEnable, ["api", "district", "scheduling", "enable"])
    }

    /// ⛔ THE TWO BARE-ARRAY ROUTES ARE NOT THE ENVELOPE ROUTES. A DTO that
    /// expected `{success, …}` fails to decode every response these send, and a
    /// synthetic wrapper added to "make them consistent" would do exactly that.
    func testTheBareArrayEndpointsAreTheKnownTwo() {
        XCTAssertEqual(BareArrayEndpoints.all, [.calls, .meetings])
        // Their enveloped siblings, which are the reason the distinction is easy
        // to miss.
        XCTAssertFalse(BareArrayEndpoints.all.contains(.callDetail))
        XCTAssertFalse(BareArrayEndpoints.all.contains(.meetingDetail))
    }

    /// ⛔ `messages/drafts` (PERSISTENCE) AND `messages/draft` (A BILLED VERTEX
    /// GENERATION) ARE ONE LETTER APART. An autosave pointed at the singular path
    /// bills a model call on every keystroke debounce and nothing about the name
    /// would suggest it.
    func testDraftPersistenceAndTheBilledGeneratorAreDifferentPaths() {
        let persistence: [ApiRequestDescriptor] = [
            DistrictEndpoints.draft(workspaceId: "ws_1", threadKey: "t_1"),
            DistrictEndpoints.drafts(workspaceId: "ws_1"),
            DistrictEndpoints.saveDraft(workspaceId: "ws_1", threadKey: "t_1", body: "hi"),
            DistrictEndpoints.deleteDraft(workspaceId: "ws_1", threadKey: "t_1"),
        ]
        for descriptor in persistence {
            XCTAssertEqual(
                ApiPath.build(descriptor.segments),
                "/api/district/messages/drafts",
                "\(descriptor.id.rawValue) must use the PLURAL, cheap path"
            )
        }
        // The three verbs the persistence route exports, and no POST — a POST
        // there is a 405.
        XCTAssertEqual(Set(persistence.map(\.method)), [.get, .put, .delete])

        let billed = DistrictEndpoints.generateDraft(workspaceId: "ws_1", contactId: "c_1", phoneNumber: nil)
        XCTAssertEqual(ApiPath.build(billed.segments), "/api/district/messages/draft")
        XCTAssertEqual(billed.method, .post)
    }

    /// ⛔ A CAMPAIGN PAUSE MUST NEVER REACH `workspace/campaign-settings`, WHICH
    /// REBUILDS ALL THREE SDR FIELDS FROM THE BODY — the same JSON sent one path
    /// over answers 200 and wipes the goal text.
    func testTheCampaignPauseUsesTheStatusPathNotTheSettingsPath() {
        let pause = DistrictEndpoints.setCampaignEnabled(workspaceId: "ws_1", infiniteSdrEnabled: false)
        XCTAssertEqual(ApiPath.build(pause.segments), "/api/district/workspace/campaign-status")
        for row in EndpointTable.all() {
            XCTAssertFalse(
                row.descriptor.segments.contains("campaign-settings"),
                "\(row.id.rawValue) addresses the destructive campaign-settings route"
            )
        }
    }

    /// ⚠️ An id is encoded as exactly ONE segment. A call id of `a/../../admin`
    /// turned `calls/{id}/transcript` into `/api/district/admin/transcript` on the
    /// Kotlin client before its paths were built from segment lists.
    func testAnIdCannotTraverseIntoAnotherRoute() {
        let descriptor = DistrictEndpoints.callTranscript(workspaceId: "ws_1", callId: "a/../../admin")
        XCTAssertEqual(
            ApiPath.build(descriptor.segments),
            "/api/district/calls/a%2F..%2F..%2Fadmin/transcript"
        )
    }
}
