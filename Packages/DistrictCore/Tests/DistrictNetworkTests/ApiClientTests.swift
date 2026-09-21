import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

final class ApiClientTests: XCTestCase {
    func testTheBearerIsAttachedFromTheAsyncProvider() async {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient.test(transport)

        _ = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"))

        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer session-token")
        XCTAssertEqual(transport.lastRequest?.headers["Accept"], "application/json")
        XCTAssertEqual(transport.lastRequest?.method, .get)
        XCTAssertNil(transport.lastRequest?.body)
    }

    func testAMissingSessionTokenIsA401AndSendsNothing() async {
        let transport = TestTransport(json: "{}")
        let client = ApiClient.test(transport, accessToken: nil)

        let result = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"))

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: nil))
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    /// ⛔ AN EMPTY PATH SEGMENT WOULD COLLAPSE TO `//` AND ADDRESS A DIFFERENT
    /// ROUTE, so nothing is sent at all.
    func testAnEmptyIdFailsBeforeAnythingIsSent() async {
        let transport = TestTransport(json: "{}")
        let client = ApiClient.test(transport)

        let result = await client.send(DistrictEndpoints.callDetail(workspaceId: "ws_1", callId: ""))

        XCTAssertEqual(
            result.failureOnly,
            .transport("The request path could not be built (an id was empty).")
        )
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    func testAJsonBodyIsEncodedWithItsContentType() async throws {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient.test(transport)

        _ = await client.send(DistrictEndpoints.dial(workspaceId: "ws_1", to: "+15555550123"))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(
            try String(data: XCTUnwrap(request.body), encoding: .utf8),
            #"{"to":"+15555550123","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ THE FILE PART IS NAMED `file`. The route reads `form.get("file")` and
    /// nothing else; any other name answers 400 "Missing file field", which reads
    /// like a client that sent no body at all. ⚠️ And `workspaceId` is a FORM
    /// FIELD, not a query parameter.
    func testTheMultipartUploadNamesItsPartsTheWayTheRouteReadsThem() async throws {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient.test(transport)

        _ = await client.send(DistrictEndpoints.uploadMedia(
            workspaceId: "ws_1",
            fileName: "photo.jpg",
            mimeType: "image/jpeg",
            bytes: Data([0x01, 0x02])
        ))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.headers["Content-Type"], "multipart/form-data; boundary=test-boundary")
        XCTAssertFalse(request.url.absoluteString.contains("workspaceId="), "it is a form field, not a query")

        let body = try XCTUnwrap(request.body)
        let text = try XCTUnwrap(String(bytes: body, encoding: .utf8))
        XCTAssertTrue(text.contains(#"name="workspaceId""#))
        XCTAssertTrue(text.contains("ws_1"))
        XCTAssertTrue(text.contains(#"name="file"; filename="photo.jpg""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("\r\n--test-boundary--\r\n"))
    }

    /// ⚠️ FIELDS ARE EMITTED IN SORTED ORDER. Swift's dictionary order is seeded
    /// per process, so without the sort the same upload produces different bytes
    /// on every run — which makes a byte assertion flaky rather than wrong, i.e.
    /// the worst kind of test. Today the route sends one field; this pins the
    /// ordering before a second one ever arrives.
    func testMultipartFieldsAreEmittedInSortedOrder() throws {
        let part = MultipartBody(
            fields: ["zeta": "2", "alpha": "1"],
            fileName: "photo.jpg",
            contentType: "image/jpeg",
            bytes: Data([0x01])
        )

        let encoded = MultipartEncoder.encode(part, boundary: "b")
        let text = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))

        let alpha = try XCTUnwrap(text.range(of: #"name="alpha""#))
        let zeta = try XCTUnwrap(text.range(of: #"name="zeta""#))
        XCTAssertTrue(alpha.lowerBound < zeta.lowerBound)
    }

    func testATypedResponseDecodes() async {
        let transport = TestTransport(json: #"{"success":true,"count":7,"workspaceId":"ws_1"}"#)
        let client = ApiClient.test(transport)

        let result = await client.send(
            DistrictEndpoints.unreadCount(workspaceId: "ws_1"),
            as: UnreadCountResponse.self
        )

        XCTAssertEqual(result.successOnly?.count, 7)
        XCTAssertEqual(result.successOnly?.workspaceId, "ws_1")
    }

    /// ⚠️ A 2xx THAT DOES NOT MATCH THE DECLARED SHAPE IS A DECODE FAILURE, not an
    /// HTTP one, and it carries no body preview — the bodies that fail here are
    /// transcripts and contact records.
    func testATypedResponseThatDoesNotMatchIsADecodeFailure() {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient.test(transport)

        let expectation = expectation(description: "decode")
        Task {
            let result = await client.send(
                DistrictEndpoints.unreadCount(workspaceId: "ws_1"),
                as: UnreadCountResponse.self
            )
            guard case let .failure(error) = result, case let .decoding(reason) = error else {
                return XCTFail("expected a decode failure")
            }
            XCTAssertTrue(reason.contains("HTTP 200"))
            XCTAssertFalse(reason.contains("success"), "no body preview may reach a screen")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    /// ⚠️ The server's own sentence is surfaced verbatim; nothing is invented
    /// here when it sends none.
    func testAnErrorEnvelopeIsNormalised() async {
        let transport = TestTransport(
            json: #"{"success":false,"error":"Messaging provider not configured for workspace"}"#,
            status: 400
        )
        let client = ApiClient.test(transport)

        let result = await client.send(DistrictEndpoints.searchNumbers(
            workspaceId: "ws_1",
            areaCode: nil,
            country: nil,
            type: nil,
            provider: nil
        ))

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 400, message: "Messaging provider not configured for workspace")
        )
    }

    func testABareErrorBodyWithNoSuccessKeyStillNormalises() async {
        let transport = TestTransport(json: #"{"error":"Too many requests"}"#, status: 429)
        let client = ApiClient.test(transport)

        let result = await client.send(DistrictEndpoints.hqPrompt(workspaceId: "ws_1", prompt: "hi"))

        XCTAssertEqual(result.failureOnly, .http(status: 429, message: "Too many requests"))
    }

    func testATransportThrowCarriesItsCause() async {
        let client = ApiClient.test(TestTransport(throwing: TransportStub.offline))

        let result = await client.send(DistrictEndpoints.workspaceList())

        XCTAssertEqual(result.failureOnly?.httpStatus, nil)
        XCTAssertTrue(result.failureOnly?.message?.contains("offline") == true)
    }

    /// ⛔ THE RECORDING 302 IS SURFACED, NEVER FOLLOWED.
    func testTheRecordingRedirectIsSurfacedAndNotFollowed() async throws {
        let transport = TestTransport(
            status: 302,
            headers: ["location": "https://storage.example.com/rec.mp3?sig=abc"]
        )
        let client = ApiClient.test(transport)

        let result = await client.redirectTarget(
            DistrictEndpoints.callRecordingUrl(workspaceId: "ws_1", callId: "call_1")
        )

        XCTAssertEqual(transport.lastFollowedRedirects, false)
        let target = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(target.statusCode, 302)
        // ⚠️ Looked up case-insensitively: libcurl-backed Linux URLSession does
        // not canonicalise header names the way Darwin's does, so a literal
        // "Location" lookup would work on a Mac and return nil on the runner.
        XCTAssertEqual(target.location, "https://storage.example.com/rec.mp3?sig=abc")
    }

    func testARedirectWithoutALocationIsContractDriftNotAnHttpFailure() async {
        let client = ApiClient.test(TestTransport(status: 302, headers: [:]))

        let result = await client.redirectTarget(
            DistrictEndpoints.callRecordingUrl(workspaceId: "ws_1", callId: "call_1")
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("The server redirected without saying where (HTTP 302).")
        )
    }

    /// ⚠️ A call with no recording answers 404 WITH A JSON BODY, not a redirect,
    /// so it must arrive as a 404 rather than as a missing `Location`.
    func testACallWithNoRecordingIsA404NotAMissingLocation() async {
        let client = ApiClient.test(TestTransport(json: #"{"error":"No recording"}"#, status: 404))

        let result = await client.redirectTarget(
            DistrictEndpoints.callRecordingUrl(workspaceId: "ws_1", callId: "call_1")
        )

        XCTAssertEqual(result.failureOnly, .http(status: 404, message: "No recording"))
    }

    /// ⛔ `sendUnmapped` KEEPS THE FAILURE BODY, because `workspace/list`'s 503
    /// carries the degraded regions and ``ApiError`` has nowhere to put an array.
    func testSendUnmappedKeepsTheFailureBody() async throws {
        let body = #"{"error":"Some regions are unavailable","code":"REGIONS_DEGRADED","degradedRegions":["eu"]}"#
        let client = ApiClient.test(TestTransport(json: body, status: 503))

        let result = await client.sendUnmapped(DistrictEndpoints.workspaceList())

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.json?["code"]?.stringValue, "REGIONS_DEGRADED")
    }

    func testSendUnmappedStillFailsWhenNothingWasSent() async {
        let client = ApiClient.test(TestTransport(json: "{}"), accessToken: nil)

        let result = await client.sendUnmapped(DistrictEndpoints.workspaceList())

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: nil))
    }

    func testARawResponseWithANonJsonBodyIsNotAnError() async throws {
        // A captive portal answers 200 with an HTML login page for every request.
        let transport = TestTransport(
            status: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<html>sign in</html>".utf8)
        )
        let client = ApiClient.test(transport)

        let result = await client.send(DistrictEndpoints.workspaceList())

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertNil(response.json)
        XCTAssertFalse(response.body.isEmpty)
    }

    func testTheProductionBaseUrlIsTheOneHostForEveryRegion() {
        XCTAssertEqual(ApiClient.productionBaseURL.absoluteString, "https://www.distronode.com")
    }

    /// ⚠️ The production boundary is a fresh UUID per request; the injected one
    /// exists only so a body can be asserted byte for byte.
    func testTheDefaultBoundaryIsGeneratedPerRequest() async throws {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session" }
        )

        _ = await client.send(DistrictEndpoints.uploadMedia(
            workspaceId: "ws_1",
            fileName: "photo.jpg",
            mimeType: "image/jpeg",
            bytes: Data([0x01])
        ))

        let contentType = try XCTUnwrap(transport.lastRequest?.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=district-"))
        XCTAssertGreaterThan(contentType.count, "multipart/form-data; boundary=district-".count + 30)
    }

    /// ⚠️ nil AND EMPTY ARE THE SAME FACT. A transport that answers `Data()` where
    /// another answers nil must not produce a different result for the same
    /// response.
    func testAResponseWithNoBodyAtAllIsAnEmptyRawBody() async throws {
        let client = ApiClient.test(TestTransport(status: 200, headers: [:], body: nil))

        let result = await client.send(DistrictEndpoints.workspaceList())

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertNil(response.json)
    }

    func testATypedResponseWithNoBodyIsADecodeFailure() async {
        let client = ApiClient.test(TestTransport(status: 200, headers: [:], body: nil))

        let result = await client.send(
            DistrictEndpoints.unreadCount(workspaceId: "ws_1"),
            as: UnreadCountResponse.self
        )

        XCTAssertEqual(result.failureOnly, .decoding(ApiErrorNormalizer.decodingReason(statusCode: 200, byteCount: 0)))
    }

    /// ⛔ AN UNENCODABLE BODY MUST NOT THROW OUT OF A SEND THAT HAS NO CATCH ABOVE
    /// IT. The only way to reach this is a non-finite `Double` inside a
    /// caller-supplied ``JSONValue`` — HQ's confirm args are echoed back verbatim
    /// from a proposal, so the client does not get to inspect them.
    func testAnUnencodableBodyBecomesAnEmptyBodyRatherThanACrash() async throws {
        let transport = TestTransport(json: #"{"success":true}"#)
        let client = ApiClient.test(transport)

        _ = await client.send(DistrictEndpoints.hqConfirm(
            workspaceId: "ws_1",
            tool: "delete_contact",
            args: .object(["weight": .number(.nan)])
        ))

        XCTAssertEqual(try XCTUnwrap(transport.lastRequest?.body), Data())
    }
}

extension Result {
    var successOnly: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failureOnly: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
