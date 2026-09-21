import DistrictModel
@testable import DistrictNetwork
import XCTest

/// What a status code plus a body becomes. ``ApiErrorEnvelopeTests`` covers the
/// decode; this covers the mapping onto the one ``ApiError`` every call resolves
/// to.
final class ApiErrorNormalizerTests: XCTestCase {
    /// One row of the mapping table. See ``ApiErrorEnvelopeTests`` for why `line`
    /// is carried.
    private struct Row {
        let name: String
        let statusCode: Int
        let body: String?
        let expected: ApiError
        let line: UInt
    }

    // MARK: - The three envelopes, through the mapping

    func testTheThreeEnvelopesAllReachTheSameApiError() {
        let rows: [Row] = [
            Row(
                name: "{success, error} — a route's own 400",
                statusCode: 400,
                body: #"{"success":false,"error":"Missing workspaceId"}"#,
                expected: .http(status: 400, message: "Missing workspaceId"),
                line: #line
            ),
            Row(
                name: "{error} — the shared auth guard's 401",
                statusCode: 401,
                body: #"{"error":"Unauthorized"}"#,
                expected: .http(status: 401, message: "Unauthorized"),
                line: #line
            ),
            Row(
                name: "{error} — the shared auth guard's 404 for a user with no workspace",
                statusCode: 404,
                body: #"{"error":"User has no workspace"}"#,
                expected: .http(status: 404, message: "User has no workspace"),
                line: #line
            ),
            Row(
                name: "{error} — rateLimitedResponse's 429",
                statusCode: 429,
                body: #"{"error":"Too many requests. Please try again shortly."}"#,
                expected: .http(status: 429, message: "Too many requests. Please try again shortly."),
                line: #line
            ),
            Row(
                name: "{error, code} — conversations' 500",
                statusCode: 500,
                body: #"{"error":"Something went wrong.","code":"INTERNAL_ERROR"}"#,
                expected: .http(status: 500, message: "Something went wrong."),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Which field wins

    /// ⛔ `code` IS NEVER PROMOTED TO THE MESSAGE, matching Kotlin's `mapFailure`
    /// (`envelope.error?.takeIf { it.isNotBlank() }`, with `code` carried in a
    /// separate field of `ApiResult.HttpFailure`). The failure this pins is a
    /// screen showing `REGIONS_DEGRADED` to an operator.
    func testCodeIsNeverUsedAsTheMessage() {
        let rows: [Row] = [
            Row(
                name: "error and code together: error wins",
                statusCode: 503,
                body: #"{"error":"One region did not answer.","code":"REGIONS_DEGRADED"}"#,
                expected: .http(status: 503, message: "One region did not answer."),
                line: #line
            ),
            Row(
                name: "blank error beside a code: no message at all",
                statusCode: 503,
                body: #"{"error":"   ","code":"REGIONS_DEGRADED"}"#,
                expected: .http(status: 503, message: nil),
                line: #line
            ),
            Row(
                name: "code alone: no message at all",
                statusCode: 409,
                body: #"{"code":"last_agency_member"}"#,
                expected: .http(status: 409, message: nil),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Nothing usable in the body

    /// ⛔ NO INVENTED COPY. `ApiError.http` carries `String?` precisely so this
    /// layer cannot fabricate a sentence; Kotlin substitutes `FALLBACK_MESSAGE`
    /// here and the UI owns that choice on this side. A fabricated message would
    /// make a contract regression read as an ordinary error on every screen.
    func testUnusableBodiesKeepTheStatusAndCarryNoMessage() {
        let rows: [Row] = [
            Row(name: "nil body", statusCode: 500, body: nil, expected: .http(status: 500, message: nil), line: #line),
            Row(name: "empty body", statusCode: 502, body: "", expected: .http(status: 502, message: nil), line: #line),
            Row(
                name: "whitespace-only body",
                statusCode: 504,
                body: "  \n ",
                expected: .http(status: 504, message: nil),
                line: #line
            ),
            Row(
                // An edge 502 or a captive portal. The status is all there is, and
                // it survives.
                name: "an HTML page",
                statusCode: 502,
                body: CapturedErrorBodies.captivePortalHtml,
                expected: .http(status: 502, message: nil),
                line: #line
            ),
            Row(
                name: "truncated JSON",
                statusCode: 500,
                body: #"{"error":"half a bo"#,
                expected: .http(status: 500, message: nil),
                line: #line
            ),
            Row(
                name: "an empty JSON object",
                statusCode: 403,
                body: "{}",
                expected: .http(status: 403, message: nil),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Real captured bodies

    func testCapturedBodiesReachTheCallerWithTheirSentenceIntact() {
        let rows: [Row] = [
            Row(
                name: "district-workspace-list-degraded.json at 503",
                statusCode: 503,
                body: CapturedErrorBodies.workspaceListDegraded,
                expected: .http(
                    status: 503,
                    message: "Your workspaces could not be listed because one or more regions are "
                        + "unreachable right now. This is not a change to your account."
                ),
                line: #line
            ),
            Row(
                name: "district-enrich-disabled.json at 403",
                statusCode: 403,
                body: CapturedErrorBodies.enrichDisabled,
                expected: .http(
                    status: 403,
                    message: "Lead enrichment is off for this workspace. Turn it on in Settings → "
                        + "AI Agent → Skills & Integrations to enrich contacts with external "
                        + "business data."
                ),
                line: #line
            ),
            Row(
                name: "district-dial-subscription.json at 402",
                statusCode: 402,
                body: CapturedErrorBodies.dialSubscription,
                expected: .http(
                    status: 402,
                    message: "This workspace's subscription is not active. Please update billing "
                        + "to resume calls and messaging."
                ),
                line: #line
            ),
            Row(
                // ⚠️ THE SENTENCE IS THE WHOLE PRODUCT HERE: this refusal carries
                // no code, so it is structurally identical to the ROLE refusal the
                // same route emits. Losing the message leaves the operator with a
                // button that failed and nothing else.
                name: "district-dial-dnc.json at 403",
                statusCode: 403,
                body: CapturedErrorBodies.dialDoNotCall,
                expected: .http(
                    status: 403,
                    message: "This number has opted out of calls from this workspace (DNC)."
                ),
                line: #line
            ),
            Row(
                // ⚠️ THE SAME STATUS AND THE SAME SHAPE AS THE ROW ABOVE, and
                // through this function the two are indistinguishable — `code`
                // has nowhere to travel on `ApiError`. The recovery is pinned
                // separately below.
                name: "district-dial-dormant.json at 403",
                statusCode: 403,
                body: CapturedErrorBodies.dialDormant,
                expected: .http(
                    status: 403,
                    message: "This workspace has not sent anything for 100 days, so outbound "
                        + "calling and messaging are paused pending an account review. Request "
                        + "reactivation from your dashboard and we will re-enable it."
                ),
                line: #line
            ),
        ]
        verify(rows)
    }

    /// ⛔ A 403 IS NOT ONE THING, AND THE NORMALISER CANNOT TELL THE TWO APART.
    /// The DNC refusal and the dormancy refusal reach a caller as the same
    /// `ApiError.http(403, …)`; only a second decode of the same bytes recovers
    /// `workspace_dormant`, which is the difference between "this number opted
    /// out" and "your workspace is paused, here is how to un-pause it". Pinned so
    /// that route stays open, exactly as it is for `REGIONS_DEGRADED`.
    func testTheDormancyCodeStaysRecoverableAlongsideTheApiError() {
        let dormantBody = Data(CapturedErrorBodies.dialDormant.utf8)
        let dncBody = Data(CapturedErrorBodies.dialDoNotCall.utf8)

        let dormant = ApiErrorNormalizer.apiError(statusCode: 403, body: dormantBody)
        let dnc = ApiErrorNormalizer.apiError(statusCode: 403, body: dncBody)

        XCTAssertEqual(dormant.httpStatus, dnc.httpStatus, "the status alone cannot separate them")
        XCTAssertFalse(dormant.isUnauthorized, "403 is not a token problem, refreshing cannot fix it")
        XCTAssertEqual(ApiErrorEnvelope.lenient(dormantBody)?.code, ApiErrorCode.workspaceDormant)
        XCTAssertNil(ApiErrorEnvelope.lenient(dncBody)?.code)
        XCTAssertEqual(dormant.message, ApiErrorEnvelope.lenient(dormantBody)?.message)
    }

    /// ⚠️ THE CODE AND THE REGION LIST DO NOT TRAVEL ON `ApiError` — it has
    /// nowhere to put them, so normalisation is lossy on purpose and the loss has
    /// to be recoverable. A caller that must tell "we could not look" from "there
    /// is nothing" decodes the same bytes again: `ApiErrorEnvelope.lenient(_:)`
    /// for the code, `WorkspaceListDegradedError` for the array. Pinned here so
    /// that route stays open.
    func testTheCodeAndRegionListStayRecoverableAlongsideTheApiError() throws {
        let body = Data(CapturedErrorBodies.workspaceListDegraded.utf8)

        let error = ApiErrorNormalizer.apiError(statusCode: 503, body: body)
        let envelope = ApiErrorEnvelope.lenient(body)
        let degraded = try JSONDecoder().decode(WorkspaceListDegradedError.self, from: body)

        XCTAssertEqual(error.httpStatus, 503)
        XCTAssertEqual(envelope?.code, ApiErrorCode.regionsDegraded)
        XCTAssertEqual(degraded.degradedRegions, ["eu", "apac"])
        XCTAssertEqual(error.message, envelope?.message)
        XCTAssertEqual(error.message, degraded.error)
    }

    // MARK: - 401 stays recognisable

    /// ⛔ THE REFRESH COORDINATOR'S ONLY SIGNAL. `ApiError.isUnauthorized` is
    /// `httpStatus == 401`, so the status has to survive normalisation for a body
    /// of any shape — including no body at all, which is what an edge-generated
    /// 401 looks like. 403 is deliberately NOT unauthorized: refreshing a token
    /// cannot fix "authenticated but not permitted".
    func testUnauthorizedSurvivesEveryBodyShape() {
        for body in [nil, "", "{}", #"{"error":"Unauthorized"}"#, CapturedErrorBodies.captivePortalHtml] {
            let error = ApiErrorNormalizer.apiError(statusCode: 401, body: body.map { Data($0.utf8) })
            XCTAssertTrue(error.isUnauthorized, "401 must stay recognisable for body: \(body ?? "<nil>")")
        }
        XCTAssertFalse(ApiErrorNormalizer.apiError(statusCode: 403, body: nil).isUnauthorized)
    }

    // MARK: - The 2xx path

    /// A 2xx only reaches this function when the caller could not decode the
    /// declared contract, so it maps to ``ApiError/decoding(_:)`` — never to
    /// `.http`, which would report contract drift as a server refusal and send
    /// the user to a retry button that cannot help.
    func testSuccessStatusesMapToDecoding() {
        for status in [200, 201, 204, 299] {
            let error = ApiErrorNormalizer.apiError(statusCode: status, body: Data("{}".utf8))
            XCTAssertNil(error.httpStatus, "a decode failure has no HTTP status to report")
            XCTAssertEqual(error, .decoding(ApiErrorNormalizer.decodingReason(statusCode: status, byteCount: 2)))
        }
    }

    func testDecodingReasonCarriesTheStatusAndTheSize() {
        XCTAssertEqual(
            ApiErrorNormalizer.apiError(statusCode: 200, body: Data("abcdefghij".utf8)).message,
            "The server's response did not match the shape this app expects (HTTP 200, 10 bytes)."
        )
        // nil and empty are the same fact, and a 204 with no body is the ordinary
        // way to reach that.
        XCTAssertEqual(
            ApiErrorNormalizer.apiError(statusCode: 204, body: nil),
            ApiErrorNormalizer.apiError(statusCode: 204, body: Data())
        )
        XCTAssertEqual(
            ApiErrorNormalizer.apiError(statusCode: 204, body: nil).message,
            "The server's response did not match the shape this app expects (HTTP 204, 0 bytes)."
        )
    }

    /// ⛔ NO BODY PREVIEW IN THE REASON. `ApiError.decoding`'s string IS
    /// `ApiError.message`, which the UI renders, and the bodies that fail to
    /// decode are call transcripts and contact records. Kotlin can afford a
    /// preview because it lives in a separate field nothing draws.
    func testDecodingReasonNeverQuotesTheBody() {
        let secret = #"{"transcript":"my card number is 4111 1111 1111 1111"}"#

        let reason = ApiErrorNormalizer.apiError(statusCode: 200, body: Data(secret.utf8)).message

        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.contains("4111") ?? true)
        XCTAssertFalse(reason?.contains("transcript") ?? true)
    }

    /// ⚠️ THE BOUNDARY IS 2xx, NOT `< 400`. A 3xx here is a redirect the transport
    /// did not follow — the recording route answers 302 with a `Location` the app
    /// reads — and calling that contract drift would blame the wrong layer.
    func testOnlyTwoHundredsAreTreatedAsSuccess() {
        XCTAssertTrue(ApiErrorNormalizer.isSuccess(200))
        XCTAssertTrue(ApiErrorNormalizer.isSuccess(299))
        XCTAssertFalse(ApiErrorNormalizer.isSuccess(199))
        XCTAssertFalse(ApiErrorNormalizer.isSuccess(300))
        XCTAssertEqual(
            ApiErrorNormalizer.apiError(statusCode: 302, body: nil),
            .http(status: 302, message: nil)
        )
        XCTAssertEqual(
            ApiErrorNormalizer.apiError(statusCode: 199, body: nil),
            .http(status: 199, message: nil)
        )
    }

    // MARK: - Helpers

    private func verify(_ rows: [Row]) {
        for row in rows {
            let actual = ApiErrorNormalizer.apiError(
                statusCode: row.statusCode,
                body: row.body.map { Data($0.utf8) }
            )
            XCTAssertEqual(actual, row.expected, row.name, line: row.line)
        }
    }
}
