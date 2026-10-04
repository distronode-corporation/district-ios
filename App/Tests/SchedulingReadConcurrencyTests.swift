@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The scheduling read screens send their independent reads together.
///
/// ⛔ CONCURRENCY IS MEASURED, NOT INFERRED FROM ORDER. ``ProbeTransport`` holds each
/// request until as many as the screen should have in flight have arrived (or a short
/// deadline passes) and records the most it ever saw at once. A screen awaiting its reads
/// in turn never has more than one in flight, so it reads 1 here and fails.
final class SchedulingReadConcurrencyTests: SchedulingModelTestCase {
    // MARK: - Independent reads

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

    // MARK: - Support

    private func probeClient(_ probe: ProbeTransport) -> ApiClient {
        ApiClient(baseURL: ApiClient.productionBaseURL, transport: probe, accessToken: { "session-token" })
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
