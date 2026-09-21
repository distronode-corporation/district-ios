import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The two NON-RPC routes: the multipart image upload and the recording redirect.
///
/// ⛔ THE BOUNDARY IS INJECTED SO THE BYTES CAN BE ASSERTED. `ApiClient` defaults
/// to a fresh UUID per request, which is correct in production and makes a
/// multipart body untestable; the same escape `ApiClientTests` uses.
final class SchedulingAdminMediaRepositoryTests: XCTestCase {
    private func repository(_ transport: any HTTPTransport) -> SchedulingAdminMediaRepository {
        SchedulingAdminMediaRepository(client: ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" },
            boundary: { "media-boundary" }
        ))
    }

    private static let pixel = SchedulingUploadFile(
        fileName: "logo.png",
        mimeType: "image/png",
        bytes: Data([0x89, 0x50])
    )

    // MARK: - The upload

    /// ⛔ THE WORKSPACE IS A QUERY PARAMETER AND `target` IS A FORM FIELD, which is
    /// a third shape again on this API. The split is the server's: the workspace id
    /// has to be readable before `req.formData()` so the session check can run
    /// ahead of a multipart parse of a body up to 100 MB.
    func testTheUploadPutsTheWorkspaceInTheQueryAndTheTargetInTheForm() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"logo_url":"https://book.test/l.png"}}"#)
        let result = try await repository(transport).upload(
            workspaceId: "ws_1",
            target: .logo,
            file: Self.pixel
        )
        XCTAssertEqual(result.logoUrl, "https://book.test/l.png")
        XCTAssertEqual(result.publishedUrl, "https://book.test/l.png")
        XCTAssertEqual(
            transport.requestedURLs,
            ["https://www.distronode.com/api/district/scheduling/admin/upload?workspaceId=ws_1"]
        )
    }

    /// ⛔ THE FILE PART IS NAMED `file` AND IS RENAMED AT THE FAR END. Our route
    /// reads `form.get("file")` and forwards it to the fork under `logo`, `banner`
    /// or `avatar`; a part named after the TARGET is "Missing file field" here,
    /// before the scheduler is ever asked. Asserted as bytes because nothing else
    /// can see a part name.
    func testTheMultipartBodyCarriesTheTargetFieldAndAFilePartNamedFile() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"banner_url":"https://book.test/b.png"}}"#)
        _ = try await repository(transport).upload(
            workspaceId: "ws_1",
            target: .banner,
            file: SchedulingUploadFile(fileName: "banner.gif", mimeType: "image/gif", bytes: Data("GIF".utf8))
        )
        XCTAssertEqual(
            transport.bodies,
            [
                "--media-boundary\r\n"
                    + "Content-Disposition: form-data; name=\"target\"\r\n\r\n"
                    + "banner\r\n"
                    + "--media-boundary\r\n"
                    + "Content-Disposition: form-data; name=\"file\"; filename=\"banner.gif\"\r\n"
                    + "Content-Type: image/gif\r\n\r\n"
                    + "GIF\r\n"
                    + "--media-boundary--\r\n",
            ]
        )
    }

    /// ⚠️ ALL THREE TARGETS GO THROUGH ONE DESCRIPTOR AND ONE RESPONSE TYPE, and
    /// the key that comes back is the only thing that differs. `avatar` is the
    /// caller's own picture and is viewer-level, so it spends the per-MEMBER budget
    /// rather than the workspace's.
    func testTheAvatarTargetAnswersItsOwnKey() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"avatar_url":"https://book.test/a.png"}}"#)
        let result = try await repository(transport).upload(
            workspaceId: "ws_1",
            target: .avatar,
            file: Self.pixel
        )
        XCTAssertNil(result.logoUrl)
        XCTAssertEqual(result.avatarUrl, "https://book.test/a.png")
    }

    /// ⛔ A REFUSAL FROM THE SCHEDULER IS A **200** ON THIS ROUTE TOO. It is not in
    /// the op catalog, yet it answers the catalog's envelope on purpose so both
    /// surfaces share one failure vocabulary — and a client reading the status
    /// alone would report a rejected image as a successful upload.
    func testASchedulerRefusalIsATwoHundredCarryingOkFalse() async {
        let transport = RepositoryTransport(json: #"{"ok":false,"failure":"instance_unavailable","status":502}"#)
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a failure")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .failure(.unavailable))
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⛔ `{ok:false}` WITH NO `failure` STRING IS STILL A REFUSAL AND MUST NOT
    /// DECODE AS A SUCCESS. The key is `.optional()` on the head, so a body that
    /// carried only the flag would satisfy a type whose every other field is
    /// optional — which is the "reports an outage as an empty success" failure the
    /// envelope split exists to prevent. It lands on
    /// ``SchedulingAdminFailureCode/unknown``, the honest generic, rather than on a
    /// specific code this client cannot have inferred.
    func testARefusalWithNoFailureStringIsStillARefusal() async {
        let transport = RepositoryTransport(json: #"{"ok":false}"#)
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a failure")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .failure(.unknown))
            XCTAssertEqual(error.uiCode, .unknown)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⛔ THE FOUR REFUSALS A CUSTOMER ACTUALLY MEETS, AND TWO OF THEM LAND ON
    /// ``SchedulingAdminError/unknown`` DELIBERATELY. The five-code vocabulary has
    /// no "wrong file type" arm, and inventing a sixth here would make this client
    /// disagree with the browser about one refusal. ⚠️ The mitigation is on the way
    /// IN — offer only the four accepted types — which is what makes the gap
    /// acceptable rather than merely tolerated.
    func testTheUploadsOwnRefusalsMapThroughTheSharedStatusVocabulary() async {
        let cases: [UploadRefusal] = [
            UploadRefusal(status: 403, code: "forbidden", expected: .forbidden),
            UploadRefusal(status: 409, code: "scheduling_not_ready", expected: .notReady),
            UploadRefusal(status: 413, code: "file_too_large", expected: .unavailable),
            UploadRefusal(status: 429, code: "rate_limited", expected: .unavailable),
            UploadRefusal(status: 415, code: "unsupported_media_type", expected: .unknown),
            UploadRefusal(status: 400, code: "unknown_target", expected: .unknown),
        ]
        for refusal in cases {
            let transport = RepositoryTransport(json: #"{"error":"\#(refusal.code)"}"#, status: refusal.status)
            do {
                _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
                XCTFail("expected \(refusal.expected) for \(refusal.status)")
            } catch let error as SchedulingAdminError {
                XCTAssertEqual(error, refusal.expected, "status \(refusal.status) / \(refusal.code)")
            } catch {
                XCTFail("expected a SchedulingAdminError, got \(error)")
            }
        }
    }

    /// ⚠️ A NON-2xx WITH A BODY THAT IS NOT JSON AT ALL — a captive portal, an edge
    /// error page — still has to map from the STATUS. The code defaults to "" and
    /// the status decides.
    func testANonJsonRefusalStillMapsFromItsStatus() async {
        let transport = RepositoryTransport([
            HTTPResponse(statusCode: 502, headers: [:], body: Data("<html>bad gateway</html>".utf8)),
        ])
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⛔ A **2xx THAT IS NEITHER ENVELOPE SHAPE** IS A CONTRACT WE CANNOT READ AND
    /// IS NOT A RETRY — the same arm the RPC route takes.
    func testATwoHundredThatIsNotAnEnvelopeIsUnknownRatherThanADecodeError() async {
        let transport = RepositoryTransport(json: #"["not an envelope"]"#)
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .unknown)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⛔ NO BODY PREVIEW IN THE MESSAGE. This text can reach a screen, and these
    /// bodies belong to customers; the size is enough to tell "sent nothing" from
    /// "sent a shape we do not know".
    func testAnEnvelopeWhoseDataIsTheWrongShapeIsADecodingFailureWithNoPreview() async {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":"https://book.test/l.png"}"#)
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a decoding failure")
        } catch let error as SchedulingAdminError {
            guard case let .decoding(reason) = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("The scheduler's answer to an image upload"), reason)
            XCTAssertFalse(reason.contains("book.test"), "the body must not be echoed: \(reason)")
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⚠️ A REQUEST THAT NEVER PRODUCED A RESPONSE ARRIVES AS
    /// ``SchedulingAdminError/transport(_:)``, which carries the cause rather than
    /// swallowing it — "offline" and "TLS rejected" need different diagnostics.
    func testATransportFailureCarriesItsCause() async {
        let transport = ThrowingTransport()
        do {
            _ = try await repository(transport).upload(workspaceId: "ws_1", target: .logo, file: Self.pixel)
            XCTFail("expected a transport failure")
        } catch let error as SchedulingAdminError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
            XCTAssertEqual(error.uiCode, .unavailable)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    // MARK: - The recording redirect

    /// ⛔ THE 302 IS NOT FOLLOWED AND THE `Location` IS THE ANSWER. Following it
    /// would stream a whole video through this process to learn its address.
    func testTheDownloadReportsWhereTheRedirectPointsWithoutFollowingIt() async throws {
        let transport = RepositoryTransport(redirectTo: "https://objects.test/rec_1.mp4?sig=abc")
        let url = try await repository(transport).recordingDownloadURL(
            workspaceId: "ws_1",
            recordingId: "rec_1"
        )
        XCTAssertEqual(url, "https://objects.test/rec_1.mp4?sig=abc")
        XCTAssertEqual(
            transport.requestedURLs,
            ["https://www.distronode.com/api/district/scheduling/admin/download/rec_1?workspaceId=ws_1"]
        )
    }

    /// ⛔ `agency` AND `client` ONLY, WHICH IS STRICTER THAN THE OP THAT LISTS
    /// THESE. A viewer may see that a recording exists and may not take a copy of a
    /// customer conversation away — so a row drawn from the list must not assume
    /// this will answer.
    func testAViewerIsRefusedTheDownloadEvenThoughTheListAnswered() async {
        let transport = RepositoryTransport(json: #"{"error":"forbidden"}"#, status: 403)
        do {
            _ = try await repository(transport).recordingDownloadURL(workspaceId: "ws_1", recordingId: "rec_1")
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⚠️ A RECORDING WITH NO FILE ANSWERS A **404 WITH A JSON BODY**, not a
    /// redirect, so it falls past the redirect check into the ordinary status
    /// mapping. Read ``SchedulingRecording/hasFile`` before offering the control.
    func testARecordingWithNoFileAnswersAFourOhFourRatherThanARedirect() async {
        let transport = RepositoryTransport(json: #"{"error":"not_found"}"#, status: 404)
        do {
            _ = try await repository(transport).recordingDownloadURL(workspaceId: "ws_1", recordingId: "rec_9")
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .unknown)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    // MARK: - The client-side pre-checks

    /// ⛔ FOUR TYPES, AND **SVG IS NOT ONE OF THEM**. An SVG logo is the obvious
    /// thing to want and an SVG is a script-bearing document; the route answers 415
    /// for it, which this client cannot word usefully — see the ⚠️ on `upload`.
    func testTheAcceptedTypesAreTheForksFourAndExcludeSvg() {
        XCTAssertEqual(
            SchedulingUploadFile.acceptedMimeTypes,
            ["image/jpeg", "image/png", "image/gif", "image/webp"]
        )
        XCTAssertFalse(SchedulingUploadFile.acceptedMimeTypes.contains("image/svg+xml"))
        XCTAssertEqual(SchedulingUploadFile.maxBytes, 5 * 1024 * 1024)
    }

    /// ⚠️ ADVISORY IN ONE DIRECTION ONLY: false means "do not send", true means
    /// only that the two checks a client CAN make passed. The fork sniffs the first
    /// 512 bytes and is the real boundary.
    func testThePreCheckRefusesTheThreeThingsAClientCanSee() {
        XCTAssertTrue(Self.pixel.isProbablyAcceptable)
        XCTAssertFalse(
            SchedulingUploadFile(fileName: "logo.svg", mimeType: "image/svg+xml", bytes: Data([0x3C]))
                .isProbablyAcceptable
        )
        XCTAssertFalse(
            SchedulingUploadFile(fileName: "empty.png", mimeType: "image/png", bytes: Data())
                .isProbablyAcceptable
        )
        XCTAssertFalse(
            SchedulingUploadFile(
                fileName: "huge.png",
                mimeType: "image/png",
                bytes: Data(count: SchedulingUploadFile.maxBytes + 1)
            ).isProbablyAcceptable
        )
    }
}

/// One row of the upload's refusal table.
///
/// ⚠️ A STRUCT RATHER THAN A THREE-MEMBER TUPLE, which SwiftLint's `large_tuple`
/// refuses at two — and reasonably here, because `status` and `code` are both
/// stringly adjacent and a transposition in a tuple literal is invisible.
private struct UploadRefusal {
    let status: Int
    let code: String
    let expected: SchedulingAdminError
}

/// A transport that never answers, for the ``SchedulingAdminError/transport(_:)``
/// arm.
///
/// ⚠️ LOCAL TO THIS FILE because `RepositoryTransport` answers a synthetic 500
/// when its queue runs dry, which is a RESPONSE and therefore exercises the other
/// arm entirely.
private struct ThrowingTransport: HTTPTransport {
    struct Offline: Error {}

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = (request, followRedirects)
        throw Offline()
    }
}
