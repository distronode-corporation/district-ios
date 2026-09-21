@testable import DistrictAI
import XCTest

/// ⛔ THE REGRESSION THIS PINS SHIPPED IN EVERY BUILD AND WAS INVISIBLE IN ALL OF
/// THEM. `PushRegistrar` and `IncomingCallModel` each reached the delegate with
/// `UIApplication.shared.delegate as? AppDelegate` and returned silently when the
/// cast failed. It fails on device, so ``AppDelegate/registrar`` stayed nil: APNs
/// issued a device token, the delegate callback ran, and
/// `registrar?.deviceTokenReceived(hex)` did nothing at all. `DevicePushToken` was
/// empty in all four regions, and a VoIP push had no model to ring.
///
/// ⚠️ THIS DOES NOT ASSERT THAT `DistrictApp.body` CALLS `adopt`, because
/// evaluating a `Scene`'s body in a unit test is not something SwiftUI offers. It
/// pins the half that IS reachable — that adoption is observable at all — so the
/// nil-reference state can never again be indistinguishable from the wired one.
@MainActor
final class AppDelegateAdoptionTests: XCTestCase {
    func testAFreshDelegateHasAdoptedNothing() {
        XCTAssertFalse(AppDelegate().hasAdoptedRegistrar)
    }

    func testAdoptGivesADeviceTokenSomewhereToLand() {
        let delegate = AppDelegate()
        let registrar = PushRegistrar(container: AppContainer())
        delegate.adopt(registrar: registrar)
        XCTAssertTrue(
            delegate.hasAdoptedRegistrar,
            "a device token arriving now would be dropped, which is the shipped bug"
        )
        // ⚠️ `registrar` is referenced after the assertion on purpose: the delegate
        // holds it WEAKLY, so a local released early would nil the reference and
        // make this test pass or fail for the wrong reason.
        withExtendedLifetime(registrar) {}
    }
}
