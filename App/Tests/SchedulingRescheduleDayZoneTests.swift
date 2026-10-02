@testable import DistrictAI
import DistrictModel
import SwiftUI
import UIKit
import XCTest

/// The reschedule sheet's day picker, on a device whose zone is ahead of the profile's.
///
/// ⛔ THE BUG THIS PINS: ``SchedulingBookingRescheduleModel/dayKey`` reads the picked
/// `Date` in the PROFILE zone, so a picker drawn in the DEVICE zone showed one day and
/// fetched another. A Toronto-profile operator in Tokyo picking Oct 5 got Oct 4's slots
/// listed under Oct 5. The assertion is made against the `UIDatePicker` SwiftUI draws,
/// because the day on screen is what the operator chose.
@MainActor
final class SchedulingRescheduleDayZoneTests: XCTestCase {
    private var savedZone: TimeZone?
    private var window: UIWindow?

    override func setUp() async throws {
        savedZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        if let savedZone {
            NSTimeZone.default = savedZone
        }
    }

    func testADeviceAheadOfTheProfileFetchesTheDayThePickerShows() async throws {
        // 16:00Z on Oct 4 is Oct 5 01:00 in Tokyo and Oct 4 12:00 in Toronto.
        let instant = try XCTUnwrap(WireInstant.parse("2026-10-04T16:00:00Z"))
        let transport = SettingsTransport(Array(
            repeating: SchedulingWritesBFixtures.ok("{\"slots\":[]}"),
            count: 4
        ))
        let model = SchedulingBookingRescheduleModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            bookingId: "bk-1",
            eventTypeSlug: "intro",
            timezone: "America/Toronto",
            startingFrom: instant,
            onSaved: { _ in }
        )

        // ⚠️ THE DEVICE ZONE IS SET IN SWIFTUI'S ENVIRONMENT AS WELL AS ON `NSTimeZone`.
        // The simulator's SwiftUI zone follows the host machine, not `NSTimeZone.default`,
        // so without this the "device" would quietly be wherever the test runs.
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let picker = try await hostedDatePicker(
            SchedulingBookingRescheduleSheet(model: model, onClose: {}).environment(\.timeZone, tokyo)
        )
        let shownDay = Self.day(of: picker.date, in: picker.timeZone ?? .current)

        await model.loadSlots()
        let params = SchedulingWritesBFixtures.params(transport, transport.requests.count - 1)
        XCTAssertEqual(shownDay, "2026-10-04")
        XCTAssertEqual(params["from"] as? String, shownDay)
        XCTAssertEqual(params["to"] as? String, shownDay)
    }

    // MARK: - Hosting

    /// Puts the sheet in a real window and waits for SwiftUI to draw its `UIDatePicker`.
    private func hostedDatePicker(_ root: some View) async throws -> UIDatePicker {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
        for _ in 0 ..< 50 {
            window.layoutIfNeeded()
            if let picker = Self.firstDatePicker(in: window) {
                return picker
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("SwiftUI drew no UIDatePicker for the sheet's DatePicker")
        throw CancellationError()
    }

    private static func firstDatePicker(in view: UIView) -> UIDatePicker? {
        if let picker = view as? UIDatePicker {
            return picker
        }
        for child in view.subviews {
            if let picker = firstDatePicker(in: child) {
                return picker
            }
        }
        return nil
    }

    private static func day(of date: Date, in zone: TimeZone) -> String {
        SchedulingBookingRescheduleModel.dayFormatter(zone).string(from: date)
    }
}
