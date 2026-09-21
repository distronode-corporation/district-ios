import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// ⛔ EVERY BODY HERE IS INLINE AND NONE OF IT IS A CONTRACT FIXTURE, which is
/// the right way round for this file: what is under test is the ENVELOPE, and the
/// envelope's failure half is a shape no fixture corpus carries — a **200** whose
/// meaning is "the scheduler refused". The contract corpus mirrors the Kotlin
/// client and that client has no scheduling admin at all.
///
/// ⚠️ THE PAYLOAD TYPE IS DELIBERATELY TRIVIAL. `perform` is generic and decodes
/// whatever the caller names, so a realistic DTO here would test `Decodable` and
/// not this layer. The real row types are tested in their own suites.
final class SchedulingAdminRepositoryTests: XCTestCase {
    private struct Row: Decodable, Equatable {
        let id: String
    }

    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    // MARK: - The success half

    func testATwoHundredWithOkTrueDecodesData() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"id":"et_1"}}"#)
        let row = try await repository(transport).perform(
            .eventTypesGet,
            workspaceId: "ws_1",
            params: .object([("slug", .string("intro-call"))]),
            as: Row.self
        )
        XCTAssertEqual(row, Row(id: "et_1"))
    }

    /// ⛔ THE PATH KEY IS STILL IN THE BODY. The server strips `slug` after
    /// validating against a schema that REQUIRES it; a client that removed it
    /// first would get a 400 naming the field it was being helpful about.
    func testTheRequestCarriesTheOpNameAndTheParamsUntouched() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"id":"et_1"}}"#)
        _ = try await repository(transport).perform(
            .eventTypesGet,
            workspaceId: "ws_1",
            params: .object([("slug", .string("intro-call"))]),
            as: Row.self
        )
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"eventTypes.get","params":{"slug":"intro-call"},"workspaceId":"ws_1"}"#]
        )
        XCTAssertEqual(transport.requestedURLs, ["https://www.distronode.com/api/district/scheduling/admin"])
    }

    /// ⛔ AN OP THAT TAKES NOTHING SENDS `"params":{}`, NOT A DROPPED KEY. The
    /// route defaults an absent `params` to `{}` as well, so the two agree today —
    /// sending it makes the agreement a contract rather than a coincidence.
    func testAnOpWithNoParamsSendsAnEmptyObject() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        let answer = try await repository(transport).perform(
            .meAvatarDelete,
            workspaceId: "ws_1",
            params: .object([]),
            as: SchedulingNoContent.self
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(transport.bodies, [#"{"op":"me.avatar.delete","params":{},"workspaceId":"ws_1"}"#])
    }

    // MARK: - The 200 that is a failure

    /// ⛔ HTTP 200 CARRYING `{ok:false}`. `sendUnmapped` is what makes this
    /// reachable at all; the ordinary typed send would have handed these bytes to
    /// `JSONDecoder` and reported a scheduler outage as a decode failure.
    func testATwoHundredWithOkFalseThrowsTheMappedFailure() async {
        let cases: [(String, SchedulingAdminFailureCode)] = [
            ("unavailable", .unavailable),
            ("instance_unavailable", .unavailable),
            ("slot_taken", .slotTaken),
            ("conflict", .unknown),
            ("not_found", .unknown),
            ("rejected", .unknown),
        ]
        for (failure, expected) in cases {
            let transport = RepositoryTransport(json: #"{"ok":false,"failure":"\#(failure)","status":502}"#)
            await assertThrows(transport, .failure(expected), because: failure)
        }
    }

    /// ⚠️ A `{ok:false}` WITH NO `failure` KEY IS STILL A FAILURE. The field is
    /// optional on the way in and lands on the honest generic rather than making
    /// the whole envelope unreadable.
    func testAFailureWithNoKindIsUnknownRatherThanUnreadable() async {
        await assertThrows(RepositoryTransport(json: #"{"ok":false,"status":500}"#), .failure(.unknown))
    }

    /// ⛔ A 200 THAT IS NEITHER SHAPE IS `.unknown`, AND NOT A RETRY. Same arm as
    /// the browser's.
    func testATwoHundredWithNoOkFlagIsUnknown() async {
        await assertThrows(RepositoryTransport(json: #"{"data":{"id":"et_1"}}"#), .unknown)
    }

    /// ⚠️ THE FLAG IS READ BEFORE THE PAYLOAD, so `ok:true` with a `data` the
    /// caller's type cannot read is a DECODING failure and not an `unknown`.
    func testAnOkTrueWhoseDataDoesNotMatchIsADecodingFailure() async {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"nope":1}}"#)
        let error = await performExpectingError(transport)
        guard case let .decoding(reason) = error else {
            return XCTFail("expected a decoding failure, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("eventTypes.get"), reason)
        // ⛔ NO BODY PREVIEW: these bodies are customer bookings and transcripts,
        // and this string can reach a screen.
        XCTAssertFalse(reason.contains("nope"), reason)
        XCTAssertEqual(error?.uiCode, .unknown)
    }

    // MARK: - Our own refusals, which are not 200s

    func testFourHundredInvalidParamsCarriesTheFieldNames() async {
        let transport = RepositoryTransport(
            json: #"{"error":"invalid_params","fields":["slug","duration_minutes"]}"#,
            status: 400
        )
        await assertThrows(transport, .invalidParams(["slug", "duration_minutes"]))
    }

    /// ⚠️ AN EMPTY `fields` MEANS "WE COULD NOT SAY WHICH", NOT "NOTHING WAS
    /// WRONG". The route caps the set at 20 issues and a body carrying none is
    /// still a 400.
    func testInvalidParamsWithNoFieldsIsStillInvalidParams() async {
        await assertThrows(
            RepositoryTransport(json: #"{"error":"invalid_params"}"#, status: 400),
            .invalidParams([])
        )
    }

    /// ⛔ `unknown_op` MEANS THIS ENUM AND `ADMIN_OPS` HAVE DIVERGED — a
    /// programmer error, invisible to the compiler because the op crosses the wire
    /// as a string. The reporter is required, and the app's traps in a debug build,
    /// so this one records instead and proves it is called exactly once.
    func testUnknownOpReportsTheDivergenceAndThrowsUnknown() async {
        let seen = Recorder()
        let repo = SchedulingAdminRepository(
            client: .repositoryTest(RepositoryTransport(json: #"{"error":"unknown_op"}"#, status: 400)),
            reportUnknownOp: { seen.record($0) }
        )
        do {
            _ = try await repo.perform(.teamsGet, workspaceId: "ws_1", params: .object([]), as: Row.self)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SchedulingAdminError, .unknown)
        }
        XCTAssertEqual(seen.ops, [.teamsGet])
    }

    /// ⚠️ A 400 THAT IS NEITHER NAMED CODE FALLS THROUGH TO THE STATUS MAPPING,
    /// which has no 400 arm, so it lands on the honest generic.
    func testAnUnrecognisedFourHundredIsUnknown() async {
        await assertThrows(RepositoryTransport(json: #"{"error":"Workspace ID is required"}"#, status: 400), .unknown)
    }

    func testForbiddenStatuses() async {
        await assertThrows(RepositoryTransport(json: #"{"error":"forbidden"}"#, status: 403), .forbidden)
        await assertThrows(RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401), .forbidden)
    }

    /// ⛔ THE `error` STRING IS CHECKED BEFORE THE STATUS FOR 409. The route
    /// answers 409 for exactly one reason today, but `conflict` is a generic shape
    /// and a future 409 that is not about provisioning would otherwise tell an
    /// operator to go set up a feature they already have.
    func testNotReadyIsA409NamedSchedulingNotReady() async {
        await assertThrows(
            RepositoryTransport(json: #"{"error":"scheduling_not_ready"}"#, status: 409),
            .notReady
        )
        await assertThrows(RepositoryTransport(json: #"{"error":"conflict"}"#, status: 409), .unknown)
    }

    /// ⚠️ 413 IS GROUPED WITH 429 AND 5xx HERE AND IS NOT IN THE BROWSER'S
    /// `codeForStatus`, where it falls through to `unknown`. See the ⚠️ on
    /// `SchedulingAdminRepository.refusal`.
    func testUnavailableStatuses() async {
        for status in [413, 429, 500, 502, 503] {
            await assertThrows(
                RepositoryTransport(json: #"{"error":"rate_limited"}"#, status: status),
                .unavailable,
                because: "HTTP \(status)"
            )
        }
    }

    /// ⚠️ A NON-JSON REFUSAL BODY IS NOT AN EXTRA FAILURE MODE. An edge 502 with
    /// an HTML page still maps on its status alone.
    func testANonJsonRefusalBodyStillMapsOnItsStatus() async {
        let transport = RepositoryTransport([
            HTTPResponse(statusCode: 502, headers: [:], body: Data("<html>bad gateway</html>".utf8)),
        ])
        await assertThrows(transport, .unavailable)
    }

    // MARK: - Requests that never produced a response

    func testATransportFailureCarriesItsCause() async {
        let error = await performExpectingError(FailingTransport())
        guard case let .transport(reason) = error else {
            return XCTFail("expected a transport failure, got \(String(describing: error))")
        }
        XCTAssertTrue(reason.contains("BrokenSocket"), reason)
        XCTAssertEqual(error?.uiCode, .unavailable)
    }

    /// ⛔ A MISSING CREDENTIAL IS A SYNTHETIC 401 THAT NEVER LEFT THE PROCESS, and
    /// it deliberately lands on the same answer a real 403 does: both mean this
    /// member cannot do it now.
    func testNoCredentialIsForbiddenRatherThanTransport() async {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"id":"et_1"}}"#)
        let repo = SchedulingAdminRepository(
            client: ApiClient(transport: transport, accessToken: { nil }),
            reportUnknownOp: { _ in }
        )
        do {
            _ = try await repo.perform(.eventTypesGet, workspaceId: "ws_1", params: .object([]), as: Row.self)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SchedulingAdminError, .forbidden)
        }
        XCTAssertTrue(transport.requests.isEmpty, "nothing may be sent without a credential")
    }

    // MARK: - Helpers

    private func performExpectingError(_ transport: any HTTPTransport) async -> SchedulingAdminError? {
        let repo = SchedulingAdminRepository(
            client: ApiClient(transport: transport, accessToken: { "t" }),
            reportUnknownOp: { _ in }
        )
        do {
            _ = try await repo.perform(.eventTypesGet, workspaceId: "ws_1", params: .object([]), as: Row.self)
            XCTFail("expected a refusal")
            return nil
        } catch {
            return error as? SchedulingAdminError
        }
    }

    private func assertThrows(
        _ transport: RepositoryTransport,
        _ expected: SchedulingAdminError,
        because note: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let error = await performExpectingError(transport)
        XCTAssertEqual(error, expected, note, file: file, line: line)
    }
}

/// ⚠️ A CLASS, NOT A CAPTURED `var`. The reporter is `@Sendable`, so a mutable
/// local cannot be written from it under Swift 6's concurrency checking.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ops: [SchedulingAdminOp] = []

    func record(_ op: SchedulingAdminOp) {
        lock.withLock { ops.append(op) }
    }
}

/// A transport that never answers.
private struct FailingTransport: HTTPTransport {
    struct BrokenSocket: Error {}

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = (request, followRedirects)
        throw BrokenSocket()
    }
}
