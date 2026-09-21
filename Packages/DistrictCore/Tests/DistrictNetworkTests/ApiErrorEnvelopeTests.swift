import DistrictModel
@testable import DistrictNetwork
import XCTest

/// Table-driven cover of every error-body shape the API can produce, at the
/// decode level: `ApiErrorEnvelope.lenient(_:)` and the `error`-versus-`code`
/// rule in `ApiErrorEnvelope.message`. ``ApiErrorNormalizerTests`` covers what a
/// status code then makes of them.
///
/// ⚠️ The type under test is `DistrictModel.ApiErrorEnvelope`; only the two
/// members exercised here belong to DistrictNetwork. Decoding the SHAPE is the
/// strict contract gate's job and is not repeated — what is asserted here is
/// the lenient behaviour the gate deliberately does not have.
final class ApiErrorEnvelopeTests: XCTestCase {
    /// The fields a row expects to find. `var` with defaults so a row states only
    /// what it is about.
    private struct Fields {
        var success: Bool?
        var error: String?
        var code: String?
        var message: String?
    }

    /// One row of the shape table.
    ///
    /// ⚠️ `line` is carried so a failing row points at ITS OWN declaration rather
    /// than at the assertions inside the loop. Without it a table of twenty cases
    /// reports every failure on the same line and the table stops being cheaper
    /// to read than twenty functions.
    private struct Row {
        let name: String
        let body: String?
        /// nil when the bytes carry no envelope at all.
        let expected: Fields?
        let line: UInt
    }

    // MARK: - The three envelopes

    func testDecodesTheThreeEnvelopeShapes() {
        let rows: [Row] = [
            Row(
                name: "a route's own failure: {success: false, error}",
                body: #"{"success":false,"error":"Missing workspaceId"}"#,
                expected: Fields(success: false, error: "Missing workspaceId", message: "Missing workspaceId"),
                line: #line
            ),
            Row(
                // ⛔ THE SHARED AUTH GUARD'S SHAPE. No `success` key at all, and it
                // is returned verbatim by every district route on 401/403/404 — so
                // this is the most common error body in the API, and the one a
                // strict {success, error} DTO would throw on.
                name: "the shared auth guard: bare {error}",
                body: #"{"error":"Unauthorized"}"#,
                expected: Fields(error: "Unauthorized", message: "Unauthorized"),
                line: #line
            ),
            Row(
                name: "the newer helpers: {error, code}",
                body: #"{"error":"Something went wrong.","code":"INTERNAL_ERROR"}"#,
                expected: Fields(
                    error: "Something went wrong.",
                    code: "INTERNAL_ERROR",
                    message: "Something went wrong."
                ),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - error versus code

    /// ⛔ THE ONE RULE THE TWO CLIENTS MUST AGREE ON. Kotlin's `mapFailure` reads
    /// `envelope.error?.takeIf { it.isNotBlank() }` and carries `code` in a
    /// separate field of `ApiResult.HttpFailure`, so `error` wins whenever it is
    /// non-blank and `code` is NEVER promoted to the message. A client that fell
    /// back to the code would show `INTERNAL_ERROR` to an operator.
    func testErrorWinsOverCodeAndCodeIsNeverTheMessage() {
        let rows: [Row] = [
            Row(
                name: "both present: error wins",
                body: #"{"error":"We could not reach the carrier.","code":"INTERNAL_ERROR"}"#,
                expected: Fields(
                    error: "We could not reach the carrier.",
                    code: "INTERNAL_ERROR",
                    message: "We could not reach the carrier."
                ),
                line: #line
            ),
            Row(
                name: "empty error with a code: NO message, not the code",
                body: #"{"error":"","code":"INTERNAL_ERROR"}"#,
                expected: Fields(error: "", code: "INTERNAL_ERROR", message: nil),
                line: #line
            ),
            Row(
                // Kotlin `isBlank()` parity: whitespace-only is absent, not a
                // message made of spaces.
                name: "whitespace-only error with a code: NO message",
                body: "{\"error\":\"  \\n\\t \",\"code\":\"REGIONS_DEGRADED\"}",
                expected: Fields(error: "  \n\t ", code: "REGIONS_DEGRADED", message: nil),
                line: #line
            ),
            Row(
                name: "explicit null error with a code",
                body: #"{"error":null,"code":"member_exists"}"#,
                expected: Fields(code: "member_exists"),
                line: #line
            ),
            Row(
                // ⚠️ NOT TRIMMED. A non-blank value is returned exactly as the
                // server sent it, because Kotlin returns the raw string too and
                // the two copies get compared in support threads.
                name: "a padded message is returned verbatim",
                body: #"{"error":"  Nope.  "}"#,
                expected: Fields(error: "  Nope.  ", message: "  Nope.  "),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Bodies that carry no envelope

    func testEmptyAndNonJsonBodiesCarryNoEnvelope() {
        let rows: [Row] = [
            Row(name: "nil body", body: nil, expected: nil, line: #line),
            Row(name: "empty body", body: "", expected: nil, line: #line),
            Row(name: "whitespace-only body", body: "   \n  ", expected: nil, line: #line),
            Row(name: "truncated JSON", body: #"{"error":"half a bo"#, expected: nil, line: #line),
            Row(
                // ⛔ WHAT A CAPTIVE PORTAL ANSWERS. On the Kotlin side a JSON
                // content type is what separates this from contract drift; here it
                // is simply a body with nothing in it, and the status code is all
                // there is.
                name: "an HTML page",
                body: CapturedErrorBodies.captivePortalHtml,
                expected: nil,
                line: #line
            ),
        ]
        verify(rows)
    }

    func testJsonThatIsNotAnErrorObjectCarriesNoEnvelope() {
        let rows: [Row] = [
            Row(name: "a JSON array, not an object", body: #"[{"error":"nope"}]"#, expected: nil, line: #line),
            Row(name: "a bare JSON string fragment", body: #""nope""#, expected: nil, line: #line),
            Row(name: "a bare JSON number", body: "429", expected: nil, line: #line),
            Row(
                // ⚠️ THE WHOLE ENVELOPE IS DISCARDED, INCLUDING THE PERFECTLY GOOD
                // `code`. kotlinx throws on the first type mismatch and loses the
                // rest, so salvaging the code here would make the two clients
                // branch differently on identical bytes.
                name: "a wrong-typed error field discards the whole envelope",
                body: #"{"error":42,"code":"INTERNAL_ERROR"}"#,
                expected: nil,
                line: #line
            ),
            Row(
                // ⚠️ AN EMPTY OBJECT IS AN ENVELOPE, unlike everything above: it
                // decodes, it just carries nothing. The distinction is worth
                // keeping — "the server sent an error object with no message" and
                // "the server sent no JSON at all" are different faults.
                name: "an empty JSON object",
                body: "{}",
                expected: Fields(),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Leniency in the field

    func testUnknownKeysAreIgnoredAndOddShapesStillYieldTheMessage() {
        let rows: [Row] = [
            Row(
                // Strict in the gate, lenient in the field: a field added
                // server-side must degrade to "ignored" on installed builds.
                name: "an unknown key is ignored",
                body: #"{"error":"Nope.","retryAfterSeconds":30,"nested":{"a":[1,2]}}"#,
                expected: Fields(error: "Nope.", message: "Nope."),
                line: #line
            ),
            Row(
                // Never observed. Asserted so that if it ever happens the message
                // still reaches the user rather than the body reading as a success.
                name: "success: true alongside an error is still an error body",
                body: #"{"success":true,"error":"Nope."}"#,
                expected: Fields(success: true, error: "Nope.", message: "Nope."),
                line: #line
            ),
            Row(
                // The 503 body's own array is not on this type at all — see
                // `WorkspaceListDegradedError` — so it is an unknown key here and
                // must not stop the message arriving.
                name: "degradedRegions is an unknown key on this type",
                body: #"{"error":"Nope.","degradedRegions":["eu"]}"#,
                expected: Fields(error: "Nope.", message: "Nope."),
                line: #line
            ),
        ]
        verify(rows)
    }

    // MARK: - Real captured bodies

    /// ⛔ THE CODE IS WHAT STOPS "WE COULD NOT LOOK" BEING DRAWN AS "THERE IS
    /// NOTHING", so it is asserted off a real captured body rather than off a
    /// shape someone typed out.
    func testCapturedDegradedWorkspaceListBody() {
        let decoded = ApiErrorEnvelope.lenient(Data(CapturedErrorBodies.workspaceListDegraded.utf8))

        XCTAssertEqual(decoded?.code, ApiErrorCode.regionsDegraded)
        // ⛔ NO `success` KEY AT ALL — the fact that makes a strict DTO throw.
        XCTAssertNil(decoded?.success)
        XCTAssertEqual(
            decoded?.message,
            "Your workspaces could not be listed because one or more regions are "
                + "unreachable right now. This is not a change to your account."
        )
    }

    func testCapturedRouteOwnedRefusalBodies() {
        let enrich = ApiErrorEnvelope.lenient(Data(CapturedErrorBodies.enrichDisabled.utf8))
        // ⚠️ PRESENT AND FALSE, unlike the degraded body where the key is absent
        // entirely. That contrast is why `success` is `Bool?` and not `Bool`.
        XCTAssertEqual(enrich?.success, false)
        XCTAssertNil(enrich?.code, "a route's own refusal carries nothing to branch on")
        XCTAssertEqual(
            enrich?.message,
            "Lead enrichment is off for this workspace. Turn it on in Settings → AI Agent → "
                + "Skills & Integrations to enrich contacts with external business data."
        )

        let dnc = ApiErrorEnvelope.lenient(Data(CapturedErrorBodies.dialDoNotCall.utf8))
        XCTAssertEqual(dnc?.success, false)
        XCTAssertNil(dnc?.code)
        XCTAssertEqual(dnc?.message, "This number has opted out of calls from this workspace (DNC).")
    }

    /// ⛔ TWO 403s FROM ONE ROUTE THAT DIFFER ONLY BY `code`, WHICH IS WHY THE
    /// CODE IS ASSERTED OFF THE REAL BODY. The DNC refusal above and this one are
    /// the same key set minus one field; branch on the sentence instead and the
    /// app either sends a DNC'd number to a reactivation page or leaves a dormant
    /// workspace with no way back.
    ///
    /// ⚠️ THE MESSAGE IS CHECKED VERBATIM. It is server-owned copy carrying the
    /// only statement of the 100-day window and the reactivation instruction, so
    /// `message` returning it unaltered is the behaviour, not an incidental.
    func testCapturedDormantWorkspaceBody() {
        let decoded = ApiErrorEnvelope.lenient(Data(CapturedErrorBodies.dialDormant.utf8))

        XCTAssertEqual(decoded?.success, false)
        XCTAssertEqual(decoded?.code, ApiErrorCode.workspaceDormant)
        XCTAssertEqual(decoded?.code, "workspace_dormant", "the raw value is the wire contract")
        XCTAssertEqual(
            decoded?.message,
            "This workspace has not sent anything for 100 days, so outbound calling and "
                + "messaging are paused pending an account review. Request reactivation from "
                + "your dashboard and we will re-enable it."
        )
    }

    /// The widest error body in the suite: `success`, `error`, `code` and a
    /// `status` this type deliberately does not model.
    func testCapturedDialSubscriptionBody() {
        let decoded = ApiErrorEnvelope.lenient(Data(CapturedErrorBodies.dialSubscription.utf8))

        XCTAssertEqual(decoded?.success, false)
        XCTAssertEqual(decoded?.code, "subscription_inactive")
        XCTAssertEqual(
            decoded?.message,
            "This workspace's subscription is not active. Please update billing to "
                + "resume calls and messaging."
        )
    }

    // MARK: - Helpers

    private func verify(_ rows: [Row]) {
        for row in rows {
            let decoded = ApiErrorEnvelope.lenient(row.body.map { Data($0.utf8) })
            guard let expected = row.expected else {
                XCTAssertNil(decoded, row.name, line: row.line)
                continue
            }
            guard let decoded else {
                XCTFail("\(row.name): expected an envelope, decoded none", line: row.line)
                continue
            }
            XCTAssertEqual(decoded.success, expected.success, row.name, line: row.line)
            XCTAssertEqual(decoded.error, expected.error, row.name, line: row.line)
            XCTAssertEqual(decoded.code, expected.code, row.name, line: row.line)
            XCTAssertEqual(decoded.message, expected.message, row.name, line: row.line)
        }
    }
}
