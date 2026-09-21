import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Who answers a call, how long the app rings, and whether the caller can be rung.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT WHAT A SCREEN IS ALLOWED TO BELIEVE, NOT ABOUT
/// JSON. Two of them carry the whole design:
///
///   - a viewer's availability arrives as a **200** carrying `false` and
///     `reason: "role"`, not as a 403, so a screen that read only
///     `availableForCalls` would draw a live switch for somebody the server will
///     never ring;
///   - the availability PATCH's **409** is neither a validation failure nor a
///     permission failure. It means there is no `WorkspaceMember` row to write,
///     because the person holds their role through the owner fallback and the ring
///     fan-out reads that table. It reaches the caller with its status intact so
///     that sentence can be shown instead of a shrug.
///
/// ⚠️ THERE ARE NO CONTRACT FIXTURES FOR THIS FAMILY and that is a property of the
/// corpus rather than a lowered bar: the contract corpus mirrors the Kotlin client,
/// which has no call-handling surface. This file and the route source are what pin
/// the shapes, which is the same footing `searchMessages` and `createContact` sit
/// on.
final class CallHandlingRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> CallHandlingRepository {
        CallHandlingRepository(client: .repositoryTest(transport))
    }

    // MARK: - Call handling

    func testTheReadDecodesTheModeAndTheRingAndAsksTheRightURL() async {
        let transport = RepositoryTransport(json: Self.handling(mode: "ai_then_app", ring: 12))

        let result = await repository(transport).callHandling(workspaceId: "ws_1")

        guard case let .success(value) = result else {
            return XCTFail("expected the setting, got \(result)")
        }
        XCTAssertEqual(value.callHandling, CallHandling.aiThenApp)
        XCTAssertEqual(value.appRingSeconds, 12)
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/call-handling?workspaceId=ws_1"
        )
    }

    /// ⛔ A MODE THIS BUILD DOES NOT KNOW IS A SUCCESSFUL READ, NOT A DECODE FAILURE,
    /// AND THE DIRECTION IS THE WHOLE REASON `callHandling` IS A `String`. The server
    /// normalises an unrecognised STORED value to `ai_first` before answering, so this
    /// body should be unreachable — but an enum here would turn the day it becomes
    /// reachable (a fourth mode shipped server-side) into a screen that cannot read its
    /// own ring duration either, because one strict field takes the whole response with
    /// it.
    func testAModeThisBuildDoesNotKnowStillDecodes() async {
        let transport = RepositoryTransport(json: Self.handling(mode: "ai_then_pager", ring: 20))

        let result = await repository(transport).callHandling(workspaceId: "ws_1")

        guard case let .success(value) = result else {
            return XCTFail("an unknown mode must not fail the decode, got \(result)")
        }
        XCTAssertEqual(value.callHandling, "ai_then_pager")
        XCTAssertFalse(CallHandling.isKnown(value.callHandling), "and the caller can tell it is unknown")
        XCTAssertEqual(value.appRingSeconds, 20, "the ring survives an unreadable mode")
    }

    /// ⛔ A WELL-FORMED `success:false` ON A **200** IS THE ROUTE'S OWN CATCH BRANCH
    /// once the headers are written, and required fields do not reject it. The envelope
    /// check is the only thing that does, and without it "we could not look" would
    /// render as a setting.
    func testAReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"callHandling":"ai_first","appRingSeconds":20}"#)

        let result = await repository(transport).callHandling(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("CallHandlingResponse did not affirm success=true"))
    }

    /// ⛔ THE PATCH SENDS ONLY WHAT CHANGED AND ITS RESPONSE IS THE NEW BASELINE. This
    /// is the first write on the workspace surface that echoes what it wrote, so a
    /// caller that copied `saveTools`'s mandatory re-read would spend a request to
    /// learn what it had already been told.
    func testSavingTheModeAloneSendsOnlyTheModeAndAdoptsTheEcho() async {
        let transport = RepositoryTransport(json: Self.handling(mode: "app_first", ring: 20))

        let result = await repository(transport).saveCallHandling(
            workspaceId: "ws_1",
            callHandling: CallHandling.appFirst,
            appRingSeconds: nil
        )

        guard case let .success(value) = result else {
            return XCTFail("expected the new values, got \(result)")
        }
        XCTAssertEqual(value.callHandling, CallHandling.appFirst)
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(transport.bodies.first, #"{"callHandling":"app_first","workspaceId":"ws_1"}"#)
    }

    /// ⛔ AN INTEGER ON THE WIRE, NEVER `20.0`. The route validates with a zod `.int()`,
    /// so a `Double` that encodes with a decimal point is refused as fractional — a 400
    /// whose cause is invisible from the response and which an operator cannot act on.
    func testSavingTheRingAloneSendsAnIntegerAndNoMode() async {
        let transport = RepositoryTransport(json: Self.handling(mode: "ai_first", ring: 30))

        let result = await repository(transport).saveCallHandling(
            workspaceId: "ws_1",
            callHandling: nil,
            appRingSeconds: 30
        )

        XCTAssertEqual(result.successOnly?.appRingSeconds, 30)
        XCTAssertEqual(transport.bodies.first, #"{"appRingSeconds":30,"workspaceId":"ws_1"}"#)
    }

    /// ⛔ THREE REFUSALS THE ROUTE WOULD ANSWER 400 FOR, REFUSED HERE INSTEAD, AND NOT
    /// ONE REQUEST IS SENT. Each of them is a CLIENT bug — an empty body, a mode this
    /// build invented, a ring outside 5...30 — and a 400 arriving back from the server
    /// is indistinguishable from a refusal the operator could act on. Refusing locally
    /// keeps that distinction, and keeps a broken stepper from spending the workspace's
    /// rate limit.
    func testThePatchRefusesLocallyRatherThanSpendingAKnown400() async {
        let empty = RepositoryTransport(json: Self.handling(mode: "ai_first", ring: 20))
        let nothing = await repository(empty).saveCallHandling(
            workspaceId: "ws_1",
            callHandling: nil,
            appRingSeconds: nil
        )
        XCTAssertEqual(
            nothing.failureOnly,
            .decoding("saveCallHandling was given neither field, which the route answers 400")
        )
        XCTAssertTrue(empty.requests.isEmpty, "nothing may reach the wire")

        let bogus = RepositoryTransport(json: Self.handling(mode: "ai_first", ring: 20))
        let unknown = await repository(bogus).saveCallHandling(
            workspaceId: "ws_1",
            callHandling: "ring_everyone",
            appRingSeconds: nil
        )
        XCTAssertEqual(
            unknown.failureOnly,
            .decoding("saveCallHandling was given an unknown mode: ring_everyone")
        )
        XCTAssertTrue(bogus.requests.isEmpty)

        let wide = RepositoryTransport(json: Self.handling(mode: "ai_first", ring: 20))
        let outOfRange = await repository(wide).saveCallHandling(
            workspaceId: "ws_1",
            callHandling: nil,
            appRingSeconds: 31
        )
        XCTAssertEqual(outOfRange.failureOnly, .decoding("saveCallHandling was given 31s, outside 5...30"))
        XCTAssertTrue(wide.requests.isEmpty)
    }

    /// ⚠️ THE BOUNDS ARE INCLUSIVE AT BOTH ENDS, so the two values an operator can
    /// actually reach with a stepper must not be refused by the guard above.
    func testTheRangeGuardAdmitsBothEndsOfTheRange() async {
        for ring in [CallHandling.minimumRingSeconds, CallHandling.maximumRingSeconds] {
            let transport = RepositoryTransport(json: Self.handling(mode: "ai_first", ring: ring))
            let result = await repository(transport).saveCallHandling(
                workspaceId: "ws_1",
                callHandling: nil,
                appRingSeconds: ring
            )
            XCTAssertEqual(result.successOnly?.appRingSeconds, ring, "\(ring)s is in range")
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    // MARK: - Availability

    /// ⛔ THE ORDINARY ANSWER CARRIES AN EXPLICIT `null` REASON AND THE KEY IS ALWAYS
    /// THERE. That is the route's decision, taken because both native clients are
    /// strict about shape: a key present only in the interesting cases is exactly the
    /// shape that fails to decode the answer worth reading.
    func testAnAvailableMemberReadsTrueWithNoReason() async {
        let transport = RepositoryTransport(json: #"{"success":true,"availableForCalls":true,"reason":null}"#)

        let result = await repository(transport).availability(workspaceId: "ws_1")

        guard case let .success(value) = result else {
            return XCTFail("expected availability, got \(result)")
        }
        XCTAssertTrue(value.availableForCalls)
        XCTAssertNil(value.reason)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/availability?workspaceId=ws_1"
        )
    }

    /// ⛔ TWO REASONS, TWO DIFFERENT FACTS, AND BOTH ARRIVE ON A **200**. A viewer has
    /// no business being rung and can do nothing about it; somebody with no
    /// `WorkspaceMember` row holds their role through the owner fallback and CAN be
    /// fixed by being added to the workspace properly. Collapsing them into one
    /// "unavailable" line is the mistake `AvailabilityReason` exists to prevent.
    func testTheTwoReasonsArriveOnASuccessRatherThanAsRefusals() async {
        let viewer = RepositoryTransport(json: #"{"success":true,"availableForCalls":false,"reason":"role"}"#)
        let asViewer = await repository(viewer).availability(workspaceId: "ws_1")
        XCTAssertEqual(asViewer.successOnly?.reason, AvailabilityReason.role)
        XCTAssertEqual(asViewer.successOnly?.availableForCalls, false)

        let orphan = RepositoryTransport(
            json: #"{"success":true,"availableForCalls":false,"reason":"no_member_row"}"#
        )
        let noRow = await repository(orphan).availability(workspaceId: "ws_1")
        XCTAssertEqual(noRow.successOnly?.reason, AvailabilityReason.noMemberRow)
    }

    /// ⚠️ A REASON THIS BUILD HAS NEVER SEEN MUST NOT FAIL THE DECODE, which is why
    /// ``AvailabilityReason`` is constants rather than an enum. The screen shows
    /// "unavailable" with no explanation it can offer, which is worse than a sentence
    /// and far better than an unreadable response.
    func testAReasonThisBuildDoesNotKnowStillDecodes() async {
        let transport = RepositoryTransport(
            json: #"{"success":true,"availableForCalls":false,"reason":"on_holiday"}"#
        )

        let result = await repository(transport).availability(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.reason, "on_holiday")
    }

    /// ⛔ THE WRITE CARRIES NO IDENTITY AND MUST NEVER GROW ONE. The route writes the
    /// verified session's own membership row; an email or a user id in this body would
    /// be an identity the caller chose, and the first step towards a screen that offers
    /// to set a colleague's availability.
    func testTheWriteSendsOnlyTheWorkspaceAndTheFlag() async {
        let transport = RepositoryTransport(json: #"{"success":true,"availableForCalls":false,"reason":null}"#)

        let result = await repository(transport).saveAvailability(workspaceId: "ws_1", availableForCalls: false)

        XCTAssertEqual(result.successOnly?.availableForCalls, false)
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(transport.bodies.first, #"{"availableForCalls":false,"workspaceId":"ws_1"}"#)
    }

    /// ⛔ THE **409** IS NEITHER A VALIDATION NOR A PERMISSION FAILURE, AND IT REACHES
    /// THE CALLER WITH ITS STATUS INTACT SO THE SCREEN CAN SAY WHICH. There is no
    /// member row to write; the route does not create one, and neither may the client.
    /// ⚠️ Asserted alongside `isUnauthorized == false` because a screen that treated it
    /// as a token problem would sign the operator out over a data gap.
    func testTheNoMemberRowConflictArrivesWithItsStatus() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"No membership row for this workspace"}"#,
            status: 409
        )

        let result = await repository(transport).saveAvailability(workspaceId: "ws_1", availableForCalls: true)

        XCTAssertEqual(result.failureOnly?.httpStatus, 409)
        XCTAssertEqual(result.failureOnly?.isUnauthorized, false)
    }

    // MARK: - The vocabulary

    /// ⛔ THE THREE MODES AND THEIR ORDER ARE THE SERVER'S `CALL_HANDLING_MODES`, AND
    /// THE ORDER IS MEANINGFUL RATHER THAN INCIDENTAL: it runs from "the agent handles
    /// everything" to "your phone rings first", which is the order a picker has to
    /// offer them in. Reordering the list would change what an operator scanning the
    /// control reads without changing a single value, so it is pinned here.
    ///
    /// ⛔ AND THE DEFAULTS ARE THE SERVER'S TOO. `ai_first` is what an unrecognised
    /// STORED mode reads back as, and 20 seconds is `DEFAULT_APP_RING_SECONDS`; both
    /// exist here so a screen can draw a control before its first read lands rather
    /// than inventing a starting value that disagrees with the one it is about to get.
    func testTheVocabularyAndBoundsMirrorTheServers() {
        XCTAssertEqual(CallHandling.modes, ["ai_first", "ai_then_app", "app_first"])
        XCTAssertEqual(CallHandling.default, CallHandling.aiFirst)
        XCTAssertEqual(CallHandling.defaultRingSeconds, 20)
        XCTAssertEqual(CallHandling.minimumRingSeconds, 5)
        XCTAssertEqual(CallHandling.maximumRingSeconds, 30)
        XCTAssertTrue(CallHandling.modes.allSatisfy(CallHandling.isKnown))
        XCTAssertFalse(CallHandling.isKnown("ai_then_pager"))
    }

    /// ⛔ THE CLAMP IS FOR THE OUTBOUND VALUE ONLY, NEVER FOR THE ONE THAT ARRIVED. The
    /// route answers a **400** for an out-of-range ring rather than coercing it, so a
    /// stepper that could emit 31 would produce a refusal the operator cannot act on;
    /// what comes BACK is already clamped server-side and must be displayed as sent.
    func testClampingHoldsARingInsideTheRangeThePatchAccepts() {
        XCTAssertEqual(CallHandling.clampRing(0), 5)
        XCTAssertEqual(CallHandling.clampRing(4), 5)
        XCTAssertEqual(CallHandling.clampRing(5), 5)
        XCTAssertEqual(CallHandling.clampRing(20), 20)
        XCTAssertEqual(CallHandling.clampRing(30), 30)
        XCTAssertEqual(CallHandling.clampRing(31), 30)
        XCTAssertEqual(CallHandling.clampRing(600), 30)
    }

    private static func handling(mode: String, ring: Int) -> String {
        #"{"success":true,"callHandling":"\#(mode)","appRingSeconds":\#(ring)}"#
    }
}
