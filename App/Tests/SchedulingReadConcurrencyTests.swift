@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The scheduling read screens send their independent reads together, and a recording's
/// Play says when it fails.
///
/// ⛔ CONCURRENCY IS MEASURED, NOT INFERRED FROM ORDER. ``ProbeTransport`` holds each
/// request until as many as the screen should have in flight have arrived (or a short
/// deadline passes) and records the most it ever saw at once. A screen awaiting its reads
/// in turn never has more than one in flight, so it reads 1 here and fails.
final class SchedulingReadConcurrencyTests: SchedulingModelTestCase {
    // MARK: - Independent reads

    @MainActor
    func testRecordingsSendsTheProfileStorageAndListTogether() async {
        let probe = ProbeTransport(expected: 3, inner: SchedulingTestTransport([
            "me.get": .me(timezone: "America/Toronto"),
            "settings.storage.get": .data(#"{"recordings_enabled":true,"recordings_storage_ready":true}"#),
            "recordings.list": .data(#"{"recordings":[{"id":"rec_1","status":"ready","has_file":true}]}"#),
        ]))
        let model = SchedulingRecordingsModel(
            repository: SchedulingAdminRepository(client: probeClient(probe), reportUnknownOp: { _ in }),
            media: SchedulingAdminMediaRepository(client: probeClient(probe)),
            workspaceId: "ws_1"
        )
        await model.load()

        XCTAssertEqual(probe.maxInFlight, 3)
        XCTAssertEqual(model.timezone, "America/Toronto")
        XCTAssertEqual(model.state.value?.count, 1)
    }

    @MainActor
    func testBookingsSendsItsThreeContextReadsTogether() async {
        let probe = ProbeTransport(expected: 3, inner: SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(timezone: "America/Toronto"),
            "eventTypes.list": .data(#"{"items":[]}"#),
            "bookings.list": .data(#"{"items":[],"total":0}"#),
        ]))
        let model = SchedulingBookingsModel(
            repository: SchedulingAdminRepository(client: probeClient(probe), reportUnknownOp: { _ in }),
            scheduling: SchedulingRepository(client: probeClient(probe)),
            workspaceId: "ws_1"
        )
        await model.load()

        XCTAssertEqual(probe.maxInFlight, 3)
        // ⛔ THE PAGE STILL WAITS FOR THE CONTEXT. See SCHSECMODEL_01.
        XCTAssertEqual(probe.inner.ops.last, "bookings.list")
        XCTAssertEqual(model.timezone, "America/Toronto")
    }

    @MainActor
    func testDeveloperSendsTheProfileAndStatusTogether() async {
        let probe = ProbeTransport(expected: 2, inner: SchedulingTestTransport([
            "status": .readyStatus(host: "acme.example.com"),
            "me.get": .me(timezone: "America/Toronto"),
            "apiKeys.list": .data(#"{"items":[]}"#),
        ]))
        let model = SchedulingDeveloperModel(
            repository: SchedulingAdminRepository(client: probeClient(probe), reportUnknownOp: { _ in }),
            scheduling: SchedulingRepository(client: probeClient(probe)),
            workspaceId: "ws_1"
        )
        await model.loadContext()

        XCTAssertEqual(probe.maxInFlight, 2)
        XCTAssertEqual(model.publicHost, "acme.example.com")
        XCTAssertEqual(model.timezone, "America/Toronto")
    }

    @MainActor
    func testEventTypesSendsTheStatusAndListTogether() async {
        let probe = ProbeTransport(expected: 2, inner: SchedulingTestTransport([
            "status": .readyStatus(host: "acme.example.com"),
            "eventTypes.list": .data(#"{"items":[]}"#),
        ]))
        let model = SchedulingEventTypesModel(
            repository: SchedulingAdminRepository(client: probeClient(probe), reportUnknownOp: { _ in }),
            scheduling: SchedulingRepository(client: probeClient(probe)),
            workspaceId: "ws_1"
        )
        await model.load()

        XCTAssertEqual(probe.maxInFlight, 2)
        XCTAssertEqual(model.publicHost, "acme.example.com")
        XCTAssertEqual(model.state.value?.count, 0)
    }

    @MainActor
    func testCalendarSendsTheStatusAndZoomTogether() async {
        let probe = ProbeTransport(expected: 2, inner: SchedulingTestTransport([
            "calendar.status": .data(#"{"connected":false,"configured":true,"connections":[]}"#),
            "zoom.status": .refused("unavailable"),
        ]))
        let model = SchedulingCalendarModel(
            repository: SchedulingAdminRepository(client: probeClient(probe), reportUnknownOp: { _ in }),
            workspaceId: "ws_1"
        )
        await model.load()

        XCTAssertEqual(probe.maxInFlight, 2)
        XCTAssertEqual(model.state.value?.connections.count, 0)
        XCTAssertNil(model.zoom)
    }

    // MARK: - Play

    /// ⛔ A FAILED MINT IS SAID ON THE ROW. It used to return nil and leave the button
    /// doing nothing at all.
    @MainActor
    func testAFailedPlayIsVisibleOnTheRow() async {
        // ⚠️ No stub for the download route, so it answers 500.
        let model = recordings(SchedulingTestTransport([:]))

        let url = await model.downloadURL(for: "rec_1")

        XCTAssertNil(url)
        XCTAssertEqual(model.playFailures["rec_1"]?.message, SchedulingFailureCopy.unavailable)
        XCTAssertTrue(model.minting.isEmpty)
    }

    /// ⛔ A FAILED PLAY NEVER SAYS "That did not save". The catch-all is reworded for
    /// playback and keeps its offer; a specific refusal keeps its shared sentence.
    @MainActor
    func testAnUnclassifiedPlayFailureSaysTheRecordingCouldNotBeOpened() {
        let unknown = SchedulingRecordingsModel.playFailure(SchedulingAdminError.unknown)
        XCTAssertEqual(unknown.message, "That recording could not be opened. Try again.")
        XCTAssertEqual(unknown.action, .retry)

        let invalid = SchedulingRecordingsModel.playFailure(SchedulingAdminError.invalidParams([]))
        XCTAssertEqual(invalid.message, SchedulingCopy.recordingPlayFailed)
        XCTAssertEqual(invalid.action, .none)

        let offline = SchedulingRecordingsModel.playFailure(SchedulingAdminError.transport("offline"))
        XCTAssertEqual(offline.message, SchedulingFailureCopy.offline)
    }

    /// ⛔ A SECOND PRESS WHILE THE FIRST IS MINTING SPENDS NOTHING. Each press used to
    /// mint its own presigned URL and present its own player.
    @MainActor
    func testASecondPressWhileMintingIsDropped() async throws {
        let gate = GatedRedirectTransport(location: "https://media.example/rec_1.mp4")
        let model = SchedulingRecordingsModel(
            repository: SchedulingAdminRepository(client: gatedClient(gate), reportUnknownOp: { _ in }),
            media: SchedulingAdminMediaRepository(client: gatedClient(gate)),
            workspaceId: "ws_1"
        )

        let first = Task { await model.downloadURL(for: "rec_1") }
        for _ in 0 ..< 500 where gate.requests == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.minting.contains("rec_1"))
        let second = await model.downloadURL(for: "rec_1")
        gate.open()
        let url = await first.value

        XCTAssertNil(second)
        XCTAssertEqual(url?.absoluteString, "https://media.example/rec_1.mp4")
        XCTAssertEqual(gate.requests, 1)
        XCTAssertTrue(model.minting.isEmpty)
        XCTAssertNil(model.playFailures["rec_1"])
    }

    // MARK: - Support

    private func probeClient(_ probe: ProbeTransport) -> ApiClient {
        ApiClient(baseURL: ApiClient.productionBaseURL, transport: probe, accessToken: { "session-token" })
    }

    private func gatedClient(_ gate: GatedRedirectTransport) -> ApiClient {
        ApiClient(baseURL: ApiClient.productionBaseURL, transport: gate, accessToken: { "session-token" })
    }
}

/// Counts how many requests are in flight at once, holding each until `expected` have
/// arrived or a short deadline passes, then answers from ``SchedulingTestTransport``.
final class ProbeTransport: HTTPTransport, @unchecked Sendable {
    let inner: SchedulingTestTransport
    private let expected: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var highWater = 0
    private var arrived = 0

    init(expected: Int, inner: SchedulingTestTransport) {
        self.expected = expected
        self.inner = inner
    }

    var maxInFlight: Int {
        lock.withLock { highWater }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        lock.withLock {
            inFlight += 1
            arrived += 1
            highWater = max(highWater, inFlight)
        }
        // ⚠️ A DEADLINE RATHER THAN A WAIT FOREVER, so serial code reads 1 and fails on
        // the assertion instead of hanging the run.
        for _ in 0 ..< 100 where lock.withLock({ arrived < expected }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { lock.withLock { inFlight -= 1 } }
        return try await inner.send(request, followRedirects: followRedirects)
    }
}

/// Answers every request with a 302 to `location`, but only once ``open()`` is called.
final class GatedRedirectTransport: HTTPTransport, @unchecked Sendable {
    private let location: String
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var count = 0

    init(location: String) {
        self.location = location
    }

    var requests: Int {
        lock.withLock { count }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = request
        _ = followRedirects
        await withCheckedContinuation { continuation in
            let proceed = lock.withLock { () -> Bool in
                count += 1
                if isOpen {
                    return true
                }
                waiting.append(continuation)
                return false
            }
            if proceed {
                continuation.resume()
            }
        }
        return HTTPResponse(statusCode: 302, headers: ["Location": location], body: nil)
    }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}
