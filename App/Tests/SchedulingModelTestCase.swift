@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import XCTest

/// The repository factories every scheduling model test builds its subject from.
///
/// ⛔ A BASE CLASS RATHER THAN A COPY IN EACH FILE, AND THE SPLIT THAT CREATED IT WAS A
/// LINT CEILING RATHER THAN A DESIGN STATEMENT. `swiftlint --strict` caps a type body at
/// 300 lines and a file at 500, and one class covering ten models reached both. What
/// matters is that the factories stay in ONE place: two copies of "which repositories does
/// this model take" is two things to update when a model gains a collaborator, and the
/// second copy is the one that gets missed.
class SchedulingModelTestCase: XCTestCase {
    func admin(_ transport: SchedulingTestTransport) -> SchedulingAdminRepository {
        // ⚠️ `reportUnknownOp` IS OVERRIDDEN TO A NO-OP. The default `assertionFailure`
        // traps in a debug build, and a test run IS a debug build — so leaving it in place
        // would make any future test of the `unknown_op` path unrunnable rather than red.
        SchedulingAdminRepository(client: client(transport), reportUnknownOp: { _ in })
    }

    func scheduling(_ transport: SchedulingTestTransport) -> SchedulingRepository {
        SchedulingRepository(client: client(transport))
    }

    func media(_ transport: SchedulingTestTransport) -> SchedulingAdminMediaRepository {
        SchedulingAdminMediaRepository(client: client(transport))
    }

    func workspaces(_ transport: SchedulingTestTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: client(transport))
    }

    /// ⚠️ ONE TRANSPORT SHARED BY EVERY REPOSITORY A MODEL USES, which is what lets one
    /// stub table answer both the status route and the admin route.
    func client(_ transport: SchedulingTestTransport) -> ApiClient {
        ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        )
    }

    /// ⚠️ `@MainActor` BECAUSE THE MODELS ARE. Every one of them is `@MainActor @Observable`,
    /// so even its initialiser is isolated; the factory has to be too.
    @MainActor
    func overview(_ transport: SchedulingTestTransport) -> SchedulingOverviewModel {
        SchedulingOverviewModel(
            repository: admin(transport),
            scheduling: scheduling(transport),
            workspaceId: "ws_1"
        )
    }

    @MainActor
    func eventTypes(_ transport: SchedulingTestTransport) -> SchedulingEventTypesModel {
        SchedulingEventTypesModel(
            repository: admin(transport),
            scheduling: scheduling(transport),
            workspaceId: "ws_1"
        )
    }

    @MainActor
    func bookings(_ transport: SchedulingTestTransport) -> SchedulingBookingsModel {
        SchedulingBookingsModel(
            repository: admin(transport),
            scheduling: scheduling(transport),
            workspaceId: "ws_1"
        )
    }

    @MainActor
    func bookingDetail(_ transport: SchedulingTestTransport, id: String = "bk_1") -> SchedulingBookingDetailModel {
        SchedulingBookingDetailModel(repository: admin(transport), workspaceId: "ws_1", bookingId: id)
    }

    @MainActor
    func calendar(_ transport: SchedulingTestTransport) -> SchedulingCalendarModel {
        SchedulingCalendarModel(repository: admin(transport), workspaceId: "ws_1")
    }

    /// ⚠️ THE ONE MODEL THAT TAKES ``WorkspaceRepository``, because its member list is a
    /// join across District membership and the scheduler's own user table.
    @MainActor
    func team(_ transport: SchedulingTestTransport) -> SchedulingTeamModel {
        SchedulingTeamModel(
            repository: admin(transport),
            workspaces: workspaces(transport),
            workspaceId: "ws_1"
        )
    }

    @MainActor
    func settings(_ transport: SchedulingTestTransport) -> SchedulingSettingsModel {
        SchedulingSettingsModel(repository: admin(transport), workspaceId: "ws_1")
    }

    @MainActor
    func developer(_ transport: SchedulingTestTransport) -> SchedulingDeveloperModel {
        SchedulingDeveloperModel(
            repository: admin(transport),
            scheduling: scheduling(transport),
            workspaceId: "ws_1"
        )
    }
}
