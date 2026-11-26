@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// The base of the scheduling write-sheet snapshots: the recorded rows a sheet is opened
/// over, and the replies for the states the fixtures do not record.
///
/// ⛔ A SHEET IS OPENED OVER A ROW ITS SCREEN HAS READ, SO THE ROW IS READ HERE THE SAME
/// WAY: through a real ``SchedulingAdminRepository`` over the contract fixtures, never
/// built by hand. A hand-built ``SchedulingEventType`` would draw a form for a row the
/// service never sends.
@MainActor
class SchedulingWriteSnapshotCase: ScreenSnapshotTestCase {
    static let workspace = "ws-contract-test"
    /// The recorded event type's slug, which every event-type sheet is opened on.
    static let slug = "phone-consultation"
    /// The recorded booking.
    static let bookingId = "bk-contract-1"

    /// The containers ``admin(_:)`` built, kept for the test's length: a repository's
    /// bearer comes from its container's session.
    private var readers: [AppContainer] = []

    override func tearDown() async throws {
        readers = []
        try await super.tearDown()
    }

    /// The repository a screen would have read its rows through, answering from the
    /// fixtures (or from `replies`).
    func admin(_ replies: [String: FixtureTransport.Reply] = [:]) async throws -> SchedulingAdminRepository {
        let reader = try await container(FixtureTransport(replies))
        readers.append(reader)
        return reader.schedulingAdmin
    }

    func recordedEventType() async throws -> SchedulingEventType {
        try await admin().eventType(workspaceId: Self.workspace, slug: Self.slug)
    }

    func recordedMe() async throws -> SchedulingMe {
        try await admin().me(workspaceId: Self.workspace)
    }

    /// The recorded "Sales" team, the one with members.
    func recordedTeam() async throws -> SchedulingTeam {
        try await XCTUnwrap(admin().teams(workspaceId: Self.workspace).first)
    }

    /// The recorded webhooks: an active one, and one whose only event this build no
    /// longer offers.
    func recordedWebhooks() async throws -> [SchedulingWebhook] {
        try await admin().webhooks(workspaceId: Self.workspace)
    }

    /// The recorded Google connection, the destination.
    func recordedConnection() async throws -> SchedulingCalendarConnection {
        try await XCTUnwrap(admin().calendarStatus(workspaceId: Self.workspace).connections.first)
    }
}

extension FixtureTransport.Reply {
    /// ⛔ THE SCHEDULER'S OWN REFUSAL, A 200 CARRYING `{ok:false}`, as recorded.
    static var refused: Self {
        .fixture("district-scheduling-admin-failure")
    }

    /// Our route's 409 before the scheduler was asked: the tenancy is not ready.
    static var notReady: Self {
        Self(status: 409, body: FixtureTransport.fixtureData("district-scheduling-admin-not-ready"))
    }

    /// A list op's answer with nothing in it, in the `items` envelope most list ops use.
    static var noItems: Self {
        .json(#"{"ok":true,"data":{"items":[]}}"#)
    }

    /// A route that failed outright.
    static var serverError: Self {
        .json(#"{"error":"internal"}"#, status: 500)
    }
}

/// A view with a step run before it is drawn: a model put into the state under test the
/// way the person would have put it there (a form opened, a field typed, a save pressed).
///
/// ⚠️ THE STEP RUNS IN THE VIEW'S OWN `task`, so the harness's wait for the transport to
/// go quiet covers any request the step sends, and the drawing is of its outcome.
struct SnapshotPrepared<Content: View>: View {
    let content: Content
    let prepare: @MainActor () async -> Void

    init(_ content: Content, prepare: @escaping @MainActor () async -> Void) {
        self.content = content
        self.prepare = prepare
    }

    var body: some View {
        content
            .task { await prepare() }
    }
}
