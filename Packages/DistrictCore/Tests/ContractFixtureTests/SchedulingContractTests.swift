import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the four scheduling states and the enable body.
///
/// ⛔ THE STRICT GATE CANNOT TELL THESE FOUR FIXTURES APART, WHICH IS EXACTLY WHY
/// THIS FILE EXISTS. All four status bodies have an identical key set — the route
/// serialises the whole Prisma selection and derives `bookingUrl` with a
/// `?? null`, so nothing is ever omitted — and `StrictDecodeVerifier` deliberately
/// compares shapes and not values. What distinguishes a provisioning tenancy from
/// a failed one is entirely which columns are null, and every one of those facts
/// is value-level.
final class SchedulingContractTests: XCTestCase {
    // MARK: - The legacy state

    /// ⛔ `tenant: null` IS THE ORDINARY STATE OF EVERY WORKSPACE THAT HAS NOT
    /// PRESSED ENABLE, NOT AN ERROR AND NOT AN EMPTY TENANCY. A card that rendered
    /// it as a failure would report a fault to every customer who has simply never
    /// used the feature. ⚠️ And it is a different question from `eligible`: this
    /// workspace is admitted (`eligible: true`) and has no row, which is precisely
    /// the combination that means "offer the button".
    func testAWorkspaceWithNoTenancyDecodesAsAStateRatherThanAFailure() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-scheduling-status-legacy.json",
            as: SchedulingStatusResponse.self
        )

        XCTAssertTrue(response.eligible)
        XCTAssertTrue(response.canManage)
        XCTAssertNil(response.tenant, "no row is a state; the screen offers Enable")
    }

    // MARK: - The three tenancy states

    /// ⛔ THREE NULLS THAT ARE ONE FACT: this tenancy has never once been ready.
    /// `lastReadyAt` is stamped only on an observed-complete provision,
    /// `hasCredentials` is false because the platform call has not stored the
    /// once-only API key yet, and `bookingUrl` is null because the server derives
    /// it from the status. ⚠️ `publicHost` IS ALREADY REAL, which is the trap: the
    /// host is allocated BEFORE the platform call, so a client that built a link
    /// from it would publish one for a tenancy that cannot serve a booking.
    func testAProvisioningTenancyHasAHostAndNoBookingUrl() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-scheduling-status-provisioning.json",
            as: SchedulingStatusResponse.self
        )
        let tenant = try XCTUnwrap(response.tenant)

        XCTAssertEqual(tenant.status, .provisioning)
        XCTAssertEqual(tenant.publicHost, "book.example.com")
        XCTAssertEqual(tenant.region, "us")
        XCTAssertFalse(tenant.hasCredentials, "the once-only key has not been stored yet")
        XCTAssertNil(tenant.lastReadyAt, "never yet observed complete")
        XCTAssertNil(tenant.lastError, "not failed, which is not the same as ready")
        XCTAssertNil(tenant.bookingUrl, "⛔ derived from the status, and only `ready` gets one")
    }

    /// The only state that carries a link, and the only one a screen may publish.
    /// ⚠️ `lastError` is null while `lastReadyAt` is set, which is the mirror of
    /// the error row below.
    func testAReadyTenancyIsTheOnlyStateThatCarriesABookingUrl() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-scheduling-status-ready.json",
            as: SchedulingStatusResponse.self
        )
        let tenant = try XCTUnwrap(response.tenant)

        XCTAssertEqual(tenant.status, .ready)
        XCTAssertTrue(tenant.hasCredentials)
        XCTAssertEqual(tenant.lastReadyAt, "2026-09-06T11:20:00.000Z")
        XCTAssertNil(tenant.lastError)
        XCTAssertEqual(
            tenant.bookingUrl,
            "https://book.example.com/book/phone-consultation"
        )
    }

    /// ⛔ THE MOST INFORMATIVE FIXTURE IN THE SET: a tenancy that WAS ready, still
    /// owns its host and its stored credential, has a `lastReadyAt` from the last
    /// time it worked, and has NO `bookingUrl`. Every ingredient for a link is
    /// present and the server withheld it, so this is the row that catches a client
    /// rebuilding the URL from `publicHost`. ⚠️ `lastReadyAt` survives the failure
    /// because the server does not clear it — "ready on Saturday, broken since" is
    /// the fact the card needs, and a DTO that treated the two as mutually
    /// exclusive would lose it.
    ///
    /// ⚠️ `canManage: false` HERE, WHICH IS THE VIEWER'S VIEW. A read-only member
    /// sees the same failure and the same reason and gets no button, which is why
    /// `lastError` is deliberately shown to every role rather than to owners only.
    func testAFailedTenancyKeepsItsHostAndCredentialAndStillHasNoBookingUrl() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-scheduling-status-error.json",
            as: SchedulingStatusResponse.self
        )
        let tenant = try XCTUnwrap(response.tenant)

        XCTAssertTrue(response.eligible)
        XCTAssertFalse(response.canManage, "a viewer reads the same facts and gets no button")

        XCTAssertEqual(tenant.status, .error)
        XCTAssertEqual(tenant.publicHost, "book.example.com")
        XCTAssertTrue(tenant.hasCredentials, "the stored key outlives a failed re-provision")
        XCTAssertEqual(tenant.lastReadyAt, "2026-09-06T11:20:00.000Z", "not cleared by the failure")
        XCTAssertEqual(tenant.lastError, "cloudflare refused the dns record (HTTP 403)")
        XCTAssertNil(tenant.bookingUrl, "⛔ every ingredient present, and still no link")
    }

    // MARK: - Enable

    /// The 202's success branch. ⚠️ `error: null` is SENT rather than omitted —
    /// the route writes `result.ok ? null : (result.message ?? null)`, so the key
    /// exists on both branches, which is why it needs an allowlist entry.
    func testASuccessfulEnableCarriesTheHostAndANullError() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-scheduling-enable.json",
            as: SchedulingEnableResponse.self
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.status, "ready")
        XCTAssertEqual(response.publicHost, "book.example.com")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.tenantStatus, .ready)
    }

    /// ⛔ `ok: false` IS A WELL-FORMED 202 CARRYING A SENTENCE, NOT A FAILURE
    /// SHAPE, and no committed fixture holds it — the corpus records the happy
    /// branch only — so it is decoded from literal bytes here. The sentence is the
    /// whole product of this branch: the provision ran, refused, and said why.
    func testARefusedEnableStillDecodesAndKeepsItsSentence() throws {
        let response = try decode(
            SchedulingEnableResponse.self,
            from: #"""
            {"ok":false,"status":"error","publicHost":"acme-book.distronode.com",
             "error":"cloudflare refused the dns record (HTTP 403)"}
            """#
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.tenantStatus, .error)
        XCTAssertEqual(response.error, "cloudflare refused the dns record (HTTP 403)")
        XCTAssertEqual(response.publicHost, "acme-book.distronode.com", "the host survives a failure")
    }

    /// ⛔ THE `disabled` BRANCH OF ENABLE, WHICH READS AS A SUCCESS AND IS A
    /// REFUSAL. `provisionSchedulingTenant` leaves a `disabled` row alone —
    /// somebody switched this off, or the workspace is being deleted, and
    /// re-provisioning would resurrect booking pages against an explicit decision
    /// — so pressing Enable on one answers `ok: false, status: "disabled"` rather
    /// than doing anything. No fixture carries it either.
    func testEnablingADisabledTenancyRefusesRatherThanReprovisioning() throws {
        let response = try decode(
            SchedulingEnableResponse.self,
            from: #"""
            {"ok":false,"status":"disabled","publicHost":"acme-book.distronode.com",
             "error":"scheduling is disabled for this workspace"}
            """#
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.tenantStatus, .disabled)
    }

    /// ⛔ `status` ON THE ENABLE BODY IS A WIDER UNION THAN THE COLUMN'S, WHICH IS
    /// WHY IT IS A `String` AND ``SchedulingTenant/status`` IS AN ENUM. The route
    /// forwards `ProvisionResult.status`, typed `SchedulingTenantStatus |
    /// "skipped"` because one provisioner type serves both provisioning and
    /// deprovisioning. The enable path cannot reach `"skipped"` today; a throwing
    /// enum would turn a future one into a decode failure on a body whose `error`
    /// sentence is perfectly readable.
    func testAStatusOutsideTheTenancyVocabularyStillDecodes() throws {
        let response = try decode(
            SchedulingEnableResponse.self,
            from: #"{"ok":true,"status":"skipped","publicHost":null,"error":null}"#
        )

        XCTAssertEqual(response.status, "skipped")
        XCTAssertNil(response.tenantStatus, "not a tenancy state, which is not an error")
    }

    // MARK: - The vocabulary itself

    /// ⛔ AN UNKNOWN TENANT STATUS IS A HARD DECODE FAILURE, AND THAT IS THE
    /// DECISION THIS TEST EXISTS TO PIN. The column is CHECK-constrained in SQL
    /// and unioned in TypeScript, so the vocabulary is closed and server-owned; a
    /// lenient fallback would decode `"retiring"` as `.error`, re-encode it as
    /// `"error"`, and sail through the strict gate, which compares shape and never
    /// values. ⚠️ The opposite decision is correct for ``WorkspaceRole`` and the
    /// difference is the server-side constraint, not taste.
    func testAnUnknownTenantStatusFailsToDecodeRatherThanDefaulting() {
        let body = #"""
        {"eligible":true,"canManage":true,"tenant":{"status":"retiring",
         "publicHost":"acme-book.distronode.com","region":"us","lastReadyAt":null,
         "lastError":null,"hasCredentials":true,"bookingUrl":null}}
        """#

        XCTAssertThrowsError(try decode(SchedulingStatusResponse.self, from: body))
    }

    /// The four wire spellings, pinned as strings. ⚠️ Asserted rather than derived
    /// from `rawValue`, which would assert that the enum equals itself.
    func testTheTenancyVocabularyIsTheFourServerStates() {
        XCTAssertEqual(
            SchedulingTenantStatus.allCases.map(\.rawValue),
            ["provisioning", "ready", "error", "disabled"]
        )
    }
}
