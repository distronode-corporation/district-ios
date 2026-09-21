@testable import DistrictNetwork
import XCTest

/// ⛔ THE 75 KEYS ARE WRITTEN OUT A SECOND TIME, AND DERIVING THEM FROM
/// `allCases` WOULD DEFEAT THE WHOLE FILE. The op crosses the wire as a STRING,
/// so a key renamed on the server is a 400 `unknown_op` at runtime and not a
/// compile error anywhere; a test that read the enum would assert that the code
/// equals itself and would pass through any rename, in either direction. These
/// strings were read off the server's `ADMIN_OPS` catalog.
///
/// ⚠️ THE COUNTS BELOW WERE COUNTED, NOT COMPUTED. 75 ops, 35 `viewer` / 40
/// `client`, 29 reads / 46 writes — the last pair from the server's own test
/// (`method !== "GET"`), which is NOT the role split: four viewer-level ops write.
final class SchedulingAdminOpTests: XCTestCase {
    /// `ADMIN_OPS`' keys, in catalog order.
    private let catalogKeys = [
        "me.get",
        "me.patch",
        "me.avatar.delete",
        "eventTypes.list",
        "eventTypes.get",
        "eventTypes.create",
        "eventTypes.patch",
        "eventTypes.delete",
        "eventTypes.hosts.get",
        "eventTypes.hosts.put",
        "eventTypes.testEmail",
        "eventTypes.questions.list",
        "eventTypes.questions.create",
        "eventTypes.questions.patch",
        "eventTypes.questions.delete",
        "eventTypes.slots",
        "availability.rules.list",
        "availability.rules.create",
        "availability.rules.patch",
        "availability.rules.delete",
        "availability.overrides.list",
        "availability.overrides.create",
        "availability.overrides.patch",
        "availability.overrides.delete",
        "availability.overrides.deleteGroup",
        "bookings.list",
        "bookings.answers",
        "bookings.cancel",
        "bookings.reschedule",
        "bookings.reassign",
        "bookings.notes",
        "bookings.notes.regenerate",
        "bookings.transcript",
        "calendar.status",
        "calendar.caldav.connect",
        "calendar.connections.calendars.get",
        "calendar.connections.calendars.put",
        "calendar.connections.destination",
        "calendar.connections.delete",
        "zoom.status",
        "users.list",
        "users.archive",
        "users.upcomingBookings",
        "teams.list",
        "teams.get",
        "teams.create",
        "teams.patch",
        "teams.delete",
        "teams.members.add",
        "teams.members.patch",
        "teams.members.remove",
        "recordings.list",
        "recordings.delete",
        "recordings.deleteAll",
        "recordings.consent",
        "settings.branding.get",
        "settings.branding.patch",
        "settings.branding.logo.delete",
        "settings.branding.banner.delete",
        "settings.storage.get",
        "settings.storage.patch",
        "settings.notetaker.get",
        "settings.notetaker.patch",
        "settings.llm.get",
        "settings.llm.patch",
        "apiKeys.list",
        "apiKeys.create",
        "apiKeys.delete",
        "oauth.connections.list",
        "oauth.connections.delete",
        "webhooks.list",
        "webhooks.create",
        "webhooks.patch",
        "webhooks.delete",
        "webhooks.deliveries",
    ]

    /// The ops the catalog marks `viewer`, written out independently of
    /// ``SchedulingAdminOp/minRole``.
    ///
    /// ⛔ IT IS NOT "THE READS". Six of these are writes: `me.patch`,
    /// `me.avatar.delete` and the four `calendar.*` mutations, which are `viewer`
    /// because they touch only the CALLER'S OWN scheduler user. A viewer who
    /// cannot set their own timezone is offered every booking window in the wrong
    /// hours, and one who cannot connect their own calendar cannot be booked at
    /// all.
    private let viewerKeys: Set<String> = [
        "me.get", "me.patch", "me.avatar.delete",
        "eventTypes.list", "eventTypes.get", "eventTypes.hosts.get",
        "eventTypes.questions.list", "eventTypes.slots",
        "availability.rules.list", "availability.overrides.list",
        "bookings.list", "bookings.answers", "bookings.notes", "bookings.transcript",
        "calendar.status", "calendar.caldav.connect",
        "calendar.connections.calendars.get", "calendar.connections.calendars.put",
        "calendar.connections.destination", "calendar.connections.delete", "zoom.status",
        "users.list", "users.upcomingBookings",
        "teams.list", "teams.get",
        "recordings.list", "recordings.consent",
        "settings.branding.get", "settings.storage.get",
        "settings.notetaker.get", "settings.llm.get",
        "apiKeys.list", "oauth.connections.list",
        "webhooks.list", "webhooks.deliveries",
    ]

    /// The ops the catalog gives a `GET`, i.e. the ones that spend no write
    /// budget.
    private let readKeys: Set<String> = [
        "me.get",
        "eventTypes.list", "eventTypes.get", "eventTypes.hosts.get",
        "eventTypes.questions.list", "eventTypes.slots",
        "availability.rules.list", "availability.overrides.list",
        "bookings.list", "bookings.answers", "bookings.notes", "bookings.transcript",
        "calendar.status", "calendar.connections.calendars.get", "zoom.status",
        "users.list", "users.upcomingBookings",
        "teams.list", "teams.get",
        "recordings.list", "recordings.consent",
        "settings.branding.get", "settings.storage.get",
        "settings.notetaker.get", "settings.llm.get",
        "apiKeys.list", "oauth.connections.list",
        "webhooks.list", "webhooks.deliveries",
    ]

    func testTheEnumIsTheCatalogExactly() {
        XCTAssertEqual(SchedulingAdminOp.allCases.count, 75)
        XCTAssertEqual(catalogKeys.count, 75)
        XCTAssertEqual(SchedulingAdminOp.allCases.map(\.rawValue), catalogKeys)
    }

    /// ⚠️ A DUPLICATE RAW VALUE IS NOT A COMPILE ERROR IN SWIFT WHEN THE VALUES
    /// ARE WRITTEN OUT — two cases may carry the same string, and the second one
    /// then becomes unreachable through `init(rawValue:)` while `allCases` still
    /// reports 75. The count assertion above cannot see it; this can.
    func testEveryRawValueIsUnique() {
        XCTAssertEqual(Set(SchedulingAdminOp.allCases.map(\.rawValue)).count, 75)
    }

    func testEveryKeyRoundTrips() {
        for key in catalogKeys {
            XCTAssertEqual(SchedulingAdminOp(rawValue: key)?.rawValue, key, "\(key) is not a case")
        }
    }

    func testTheRoleSplitIsThirtyFiveViewerAndFortyClient() {
        let viewer = SchedulingAdminOp.allCases.filter { $0.minRole == .viewer }
        XCTAssertEqual(viewer.count, 35)
        XCTAssertEqual(SchedulingAdminOp.allCases.filter { $0.minRole == .client }.count, 40)
        XCTAssertEqual(Set(viewer.map(\.rawValue)), viewerKeys)
    }

    /// ⛔ THE TWO SPLITS DISAGREE ON SIX OPS AND THAT IS THE ASSERTION. Reading
    /// `isWrite` off `minRole` would put the four viewer-level writes back in the
    /// workspace's shared 120/hour budget, which is exactly the bucket the server
    /// separated them out of: otherwise one viewer changing their avatar in a loop
    /// locks every administrator out of writes for an hour.
    func testTheWriteSplitIsTwentyNineReadsAndFortySixWrites() {
        let reads = SchedulingAdminOp.allCases.filter { !$0.isWrite }
        XCTAssertEqual(reads.count, 29)
        XCTAssertEqual(SchedulingAdminOp.allCases.filter(\.isWrite).count, 46)
        XCTAssertEqual(Set(reads.map(\.rawValue)), readKeys)

        let viewerWrites = SchedulingAdminOp.allCases.filter { $0.minRole == .viewer && $0.isWrite }
        XCTAssertEqual(
            Set(viewerWrites.map(\.rawValue)),
            [
                "me.patch", "me.avatar.delete",
                "calendar.caldav.connect", "calendar.connections.calendars.put",
                "calendar.connections.destination", "calendar.connections.delete",
            ]
        )
    }

    /// ⚠️ `agency` IS ABSENT FROM ``SchedulingAdminRole`` BECAUSE IT CLEARS BOTH
    /// BARS AND IS THEREFORE NEVER A MINIMUM. A third case would be a value no op
    /// could hold.
    func testTheRoleEnumIsTheTwoBarsOnly() {
        XCTAssertEqual(SchedulingAdminRole.allCases.map(\.rawValue), ["viewer", "client"])
    }
}
