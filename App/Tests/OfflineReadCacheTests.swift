@testable import DistrictAI
import DistrictL10n
import DistrictNetwork
import XCTest

/// The offline read cache: what it keeps, what it never stands in for, and the
/// placeholder token that must never leave the device.
final class OfflineReadCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineReadCacheTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        L10nRuntime.locale = .en
    }

    private func request(
        _ method: HTTPMethod = .get,
        _ path: String = "/api/district/calls",
        query: String = "?workspaceId=ws_1",
        token: String = "live-token",
        language: String = "en"
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            url: URL(string: "https://example.test\(path)\(query)")!,
            headers: ["Authorization": "Bearer \(token)", "Accept-Language": language],
            body: nil
        )
    }

    private let body = Data(#"{"success":true,"calls":[]}"#.utf8)

    // MARK: - The store

    func test_OFF_01_aCacheableReadIsKeptAndReturned() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = OfflineReadCache(directory: directory) { start }
        cache.store(body, for: request(), generation: cache.generation)
        XCTAssertEqual(cache.entry(for: request()), OfflineReadCache.Entry(body: body, savedAt: start))
        // Another workspace is another key.
        XCTAssertNil(cache.entry(for: request(query: "?workspaceId=ws_2")))
    }

    /// ⛔ ONLY THE LISTED READS, AND ONLY A GET.
    func test_OFF_02_writesAndOtherPathsAreNeverKept() {
        let cache = OfflineReadCache(directory: directory)
        cache.store(body, for: request(.post), generation: cache.generation)
        cache.store(body, for: request(.get, "/api/district/calls/token"), generation: cache.generation)
        cache.store(body, for: request(.get, "/api/district/messages/send"), generation: cache.generation)
        XCTAssertNil(cache.entry(for: request(.post)))
        XCTAssertNil(cache.entry(for: request(.get, "/api/district/calls/token")))
        XCTAssertNil(cache.entry(for: request(.get, "/api/district/messages/send")))
        for path in OfflineReadCache.cachedPaths {
            XCTAssertTrue(OfflineReadCache.isCacheable(request(.get, path)), path)
            XCTAssertFalse(OfflineReadCache.isCacheable(request(.patch, path)), path)
        }
    }

    /// ⚠️ THE LANGUAGE IS PART OF THE KEY: a French answer never fills an English screen.
    func test_OFF_03_theLanguageIsPartOfTheKey() {
        let cache = OfflineReadCache(directory: directory)
        cache.store(body, for: request(language: "fr-CA"), generation: cache.generation)
        XCTAssertNil(cache.entry(for: request(language: "en")))
        XCTAssertNotNil(cache.entry(for: request(language: "fr-CA")))
    }

    func test_OFF_04_anOldCopyIsNotShownAndClearRemovesEverything() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = OfflineReadCache(directory: directory) { now }
        cache.store(body, for: request(), generation: cache.generation)
        now += OfflineReadCache.maximumAge + 1
        XCTAssertNil(cache.entry(for: request()), "a copy older than a week is shown")
        now -= 2
        XCTAssertNotNil(cache.entry(for: request()))
        cache.clear()
        XCTAssertNil(cache.entry(for: request()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_OFF_05_emptyAndOversizedBodiesAreNotKept() {
        let cache = OfflineReadCache(directory: directory)
        cache.store(Data(), for: request(), generation: cache.generation)
        XCTAssertNil(cache.entry(for: request()))
        cache.store(Data(count: OfflineReadCache.maximumBodyBytes + 1), for: request(), generation: cache.generation)
        XCTAssertNil(cache.entry(for: request()))
    }

    /// ⛔ THE FILE NAMES NAME NOTHING: no workspace id, no path.
    func test_OFF_06_fileNamesAreHashes() throws {
        let cache = OfflineReadCache(directory: directory)
        cache.store(body, for: request(query: "?workspaceId=ws_secret"), generation: cache.generation)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].wholeMatch(of: /[0-9a-f]{64}/) != nil, names[0])
    }

    /// ⛔ A SAVE FROM BEFORE A SIGN-OUT IS DROPPED: the next account must never be shown
    /// the last one's answer because a read was still in flight when the cache was wiped.
    func test_OFF_14_aSaveFromBeforeAClearIsDropped() {
        let cache = OfflineReadCache(directory: directory)
        let before = cache.generation
        cache.clear()
        cache.store(body, for: request(), generation: before)
        XCTAssertNil(cache.entry(for: request()), "a save from before the clear came back")
        cache.store(body, for: request(), generation: cache.generation)
        XCTAssertNotNil(cache.entry(for: request()))
    }

    /// ⚠️ BOUNDED: expired files go, and at most `maximumFiles` stay, newest first.
    func test_OFF_15_theCacheIsPruned() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = OfflineReadCache(directory: directory) { now }
        cache.store(body, for: request(query: "?workspaceId=old"), generation: cache.generation)
        now += OfflineReadCache.maximumAge + 60
        for page in 0 ..< OfflineReadCache.maximumFiles + 5 {
            now += 1
            cache.store(body, for: request(query: "?workspaceId=ws_1&page=\(page)"), generation: cache.generation)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, OfflineReadCache.maximumFiles)
        XCTAssertNil(cache.entry(for: request(query: "?workspaceId=old")))
        XCTAssertNil(cache.entry(for: request(query: "?workspaceId=ws_1&page=0")), "the oldest page was kept")
        let last = OfflineReadCache.maximumFiles + 4
        XCTAssertNotNil(cache.entry(for: request(query: "?workspaceId=ws_1&page=\(last)")))
    }

    /// ⚠️ THE BANNER FOLLOWS EACH SCREEN: a live answer on one path does not make another
    /// path's saved copy live, and the oldest copy still shown is the one stated.
    @MainActor
    func test_OFF_16_theStatusIsKeptPerPath() {
        let status = OfflineStatus()
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        status.servedSaved(path: "/api/district/overview", savedAt: older)
        status.servedSaved(path: "/api/district/calls", savedAt: older + 60)
        XCTAssertEqual(status.showingSavedAt, older)
        status.servedLive(path: "/api/district/calls")
        XCTAssertEqual(status.showingSavedAt, older, "a live Calls read hid Overview's saved copy")
        status.servedLive(path: "/api/district/overview")
        XCTAssertNil(status.showingSavedAt)
        status.servedSaved(path: "/api/district/contacts", savedAt: older)
        status.reset()
        XCTAssertNil(status.showingSavedAt)
    }

    // MARK: - The transport

    /// ⛔ THE PLACEHOLDER NEVER REACHES THE NETWORK, whatever the request.
    func test_OFF_07_thePlaceholderIsNeverSent() async throws {
        let inner = RecordingTransport()
        let reports = Reports()
        let cache = OfflineReadCache(directory: directory)
        let transport = OfflineCachingTransport(wrapping: inner, cache: cache) { await reports.add($1) }
        let placeholder = OfflineCachingTransport.offlinePlaceholderToken

        for req in [request(token: placeholder), request(.post, token: placeholder)] {
            do {
                _ = try await transport.send(req, followRedirects: true)
                XCTFail("an uncached placeholder request was answered")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .notConnectedToInternet)
            }
        }
        cache.store(body, for: request(), generation: cache.generation)
        let saved = try await transport.send(request(token: placeholder), followRedirects: true)
        XCTAssertEqual(saved.statusCode, 200)
        XCTAssertEqual(saved.body, body)
        XCTAssertNotNil(saved.header(OfflineCachingTransport.savedAtHeader))
        XCTAssertEqual(inner.sent.count, 0, "the placeholder reached the network")
        let reported = await reports.values
        XCTAssertEqual(reported.count, 1)
        XCTAssertNotNil(reported.first ?? nil)
    }

    func test_OFF_08_aLiveReadIsSavedThenServedWhenTheServiceCannotBeReached() async throws {
        let inner = RecordingTransport()
        let reports = Reports()
        let transport = OfflineCachingTransport(wrapping: inner, cache: OfflineReadCache(directory: directory)) {
            await reports.add($1)
        }
        inner.answer = .success(HTTPResponse(statusCode: 200, body: body))
        let live = try await transport.send(request(), followRedirects: true)
        XCTAssertNil(live.header(OfflineCachingTransport.savedAtHeader))

        inner.answer = .failure(URLError(.notConnectedToInternet))
        let saved = try await transport.send(request(), followRedirects: true)
        XCTAssertEqual(saved.body, body)
        XCTAssertNotNil(saved.header(OfflineCachingTransport.savedAtHeader))
        let reported = await reports.values
        XCTAssertEqual(reported.count, 2)
        XCTAssertNil(reported[0] ?? nil, "a live read must clear the banner")
        XCTAssertNotNil(reported[1] ?? nil)
    }

    /// ⛔ A WRITE IS NEVER ANSWERED FROM THE CACHE, and a failure that may have reached the
    /// service (or an error answer) is never covered over.
    func test_OFF_09_writesAndReachedFailuresAreNotCoveredOver() async throws {
        let inner = RecordingTransport()
        let cache = OfflineReadCache(directory: directory)
        cache.store(body, for: request(), generation: cache.generation)
        let transport = OfflineCachingTransport(wrapping: inner, cache: cache) { _, _ in }

        inner.answer = .failure(URLError(.notConnectedToInternet))
        await XCTAssertThrowsAsync(try await transport.send(request(.post), followRedirects: true))
        inner.answer = .failure(URLError(.badServerResponse))
        await XCTAssertThrowsAsync(try await transport.send(request(), followRedirects: true))

        inner.answer = .success(HTTPResponse(statusCode: 500, body: Data("{}".utf8)))
        let refused = try await transport.send(request(), followRedirects: true)
        XCTAssertEqual(refused.statusCode, 500, "an error answer was replaced by the saved copy")
        XCTAssertEqual(cache.entry(for: request())?.body, body, "an error answer overwrote the saved copy")
    }

    func test_OFF_10_whichFailuresMeanUnreachable() {
        for code in [
            URLError.Code.notConnectedToInternet,
            .cannotFindHost,
            .cannotConnectToHost,
            .timedOut,
            .networkConnectionLost,
            .dataNotAllowed,
        ] {
            XCTAssertTrue(OfflineCachingTransport.isUnreachable(URLError(code)), "\(code)")
        }
        for code in [URLError.Code.badServerResponse, .cancelled, .userAuthenticationRequired] {
            XCTAssertFalse(OfflineCachingTransport.isUnreachable(URLError(code)), "\(code)")
        }
        XCTAssertFalse(OfflineCachingTransport.isUnreachable(CocoaError(.fileNoSuchFile)))
    }

    // MARK: - The wiring

    /// ⛔ ONLY `api` GETS THE PLACEHOLDER AND THE CACHING TRANSPORT. The scheduling SSO
    /// client sends with the plain transport, so the plain bearer is the only safe one there.
    func test_OFF_11_onlyTheAPIClientTakesThePlaceholder() throws {
        let root = try SourceScan.sourceRoot()
        let container = try SourceScan.stripComments(
            String(contentsOf: root.appendingPathComponent("AppContainer.swift"), encoding: .utf8)
        )
        let api = try XCTUnwrap(container.components(separatedBy: "api = ApiClient(").dropFirst().first?.prefix(300))
        XCTAssertTrue(api.contains("transport: OfflineRead.transport(wrapping: transport),"))
        XCTAssertTrue(api.contains("accessToken: Self.offlineBearer(coordinator),"))
        let sso = try XCTUnwrap(
            container.components(separatedBy: "schedulingSSO = SchedulingSSOClient(").dropFirst().first?.prefix(200)
        )
        XCTAssertTrue(sso.contains("transport: transport,"))
        XCTAssertTrue(sso.contains("accessToken: Self.bearer(coordinator)"))
        XCTAssertEqual(container.components(separatedBy: "offlineBearer").count, 2, "a second client takes it")

        let credentials = try SourceScan.stripComments(
            String(contentsOf: root.appendingPathComponent("AppContainerCredentials.swift"), encoding: .utf8)
        )
        XCTAssertTrue(credentials
            .contains("case .retryLater(.refreshNotSent): OfflineCachingTransport.offlinePlaceholderToken"))
        XCTAssertEqual(credentials.components(separatedBy: "offlinePlaceholderToken").count, 2)
    }

    /// ⛔ BOTH SIGN-OUT PATHS CLEAR THE CACHE: the button and the session the server ended.
    func test_OFF_12_bothSignOutsClearTheCache() throws {
        let root = try SourceScan.sourceRoot()
        let session = try SourceScan.stripComments(
            String(contentsOf: root.appendingPathComponent("Session/SessionModel.swift"), encoding: .utf8)
        )
        let reauth = try XCTUnwrap(session.components(separatedBy: "case let .reauthRequired(reason):").dropFirst()
            .first?
            .components(separatedBy: "case let .retryLater").first)
        XCTAssertTrue(reauth.contains("OfflineRead.cache.clear()"))
        // ⛔ AND OFFLINE WITH THE SESSION INTACT OPENS THE SHELL, so a cold launch offline
        // reaches the saved copy; every other retry reason keeps the "try again" screen.
        let lines = session.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let compact = lines.joined(separator: "\n")
        XCTAssertTrue(compact.contains("case .retryLater(.refreshNotSent):\n            phase = .signedIn"))
        XCTAssertTrue(
            compact.contains("case let .retryLater(reason):\n            phase = .unavailable(Self.text(for: reason))")
        )
        let signOut = try XCTUnwrap(session.components(separatedBy: "func signOut() async {").dropFirst().first?
            .prefix(600))
        XCTAssertTrue(signOut.contains("OfflineRead.cache.clear()"))
        // ⛔ AND EVERY SIGN-IN, which all settle through `settle(.success)`, before the phase.
        let signIn = try XCTUnwrap(session.components(separatedBy: "case .success:").last?.prefix(400))
        let clearAt = try XCTUnwrap(signIn.range(of: "OfflineRead.cache.clear()"))
        let phaseAt = try XCTUnwrap(signIn.range(of: "await refreshPhase()"))
        XCTAssertLessThan(clearAt.lowerBound, phaseAt.lowerBound)
    }

    // MARK: - The banner

    func test_OFF_13_theBannerNamesWhenTheCopyWasSaved() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let savedAt = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06 21:20 UTC
        let sameDay = savedAt.addingTimeInterval(60)
        L10nRuntime.locale = .frCA
        let today = OfflineBanner.text(savedAt: savedAt, now: sameDay, zone: zone)
        XCTAssertTrue(today.hasPrefix("Hors ligne. Affichage des données enregistrées à 16\u{00A0}h\u{00A0}20"), today)
        let earlier = OfflineBanner.text(savedAt: savedAt, now: savedAt.addingTimeInterval(3 * 86400), zone: zone)
        XCTAssertTrue(earlier.hasPrefix("Hors ligne. Affichage des données enregistrées le "), earlier)
        L10nRuntime.locale = .en
        XCTAssertTrue(
            OfflineBanner.text(savedAt: savedAt, now: sameDay, zone: zone)
                .hasPrefix("Offline. Showing what was saved at ")
        )
    }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [HTTPRequest] = []
    private var _answer: Result<HTTPResponse, URLError> = .failure(URLError(.notConnectedToInternet))

    var sent: [HTTPRequest] {
        lock.withLock { _sent }
    }

    var answer: Result<HTTPResponse, URLError> {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func send(_ request: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        let answer = lock.withLock { () -> Result<HTTPResponse, URLError> in
            _sent.append(request)
            return _answer
        }
        return try answer.get()
    }
}

private actor Reports {
    private(set) var values: [Date?] = []

    func add(_ value: Date?) {
        values.append(value)
    }
}

private func XCTAssertThrowsAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
