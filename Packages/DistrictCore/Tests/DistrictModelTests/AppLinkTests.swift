@testable import DistrictModel
import XCTest

/// What a Universal Link means, and which ones this app refuses.
///
/// ⛔ THE REFUSALS ARE THE HALF WORTH TESTING. A wrong host or a near-miss path that
/// resolved to a real section would be an app claiming a URL it has no business
/// claiming, and every failure in this area looks identical from the outside (the link
/// opens Safari), so nothing about it is observable without assertions. Ported from
/// the Android client's `AppLinkResolverTest.kt`.
///
/// ⛔ AND THE THREE ANSWERS MUST NOT BE COLLAPSED INTO TWO. nil ("never ours, leave the
/// URL alone"), ``AppLinkOutcome/openInBrowser`` ("ours, and the honest answer is the web
/// page") and ``AppLinkOutcome/destination(_:)`` ("somewhere in this app") fail
/// differently and the middle one is new. Every assertion below says which of the three
/// it expects rather than only whether something came back.
final class AppLinkTests: XCTestCase {
    // MARK: - Refusals

    func testANonHttpsSchemeIsRefused() {
        // ⚠️ The OS cannot deliver this as a Universal Link at all; the assertion pins
        // that a URL arriving some other way is left alone rather than acted on.
        XCTAssertNil(AppLinkResolver.resolve(url("http://www.distronode.com/dashboard/district")))
        XCTAssertNil(AppLinkResolver.resolve(url("districtai://auth?code=abc")))
    }

    func testTheFrenchCanadianDomainIsNotClaimed() {
        // ⛔ `distronode.ca` is absent from the entitlement, from the served association
        // file and from the resolver. All three, deliberately.
        XCTAssertNil(AppLinkResolver.resolve(url("https://distronode.ca/dashboard/district")))
        XCTAssertNil(AppLinkResolver.resolve(url("https://www.distronode.ca/dashboard/district/inbox")))
    }

    func testAnotherHostEntirelyIsRefused() {
        XCTAssertNil(AppLinkResolver.resolve(url("https://example.com/dashboard/district")))
    }

    func testAPathThatMerelyBEGINSWithThePrefixIsRefused() {
        // ⛔ A prefix match is not a `startsWith`. These are different pages.
        // ⛔ AND THIS IS NIL RATHER THAN THE BROWSER, WHICH IS WHERE ANDROID ANSWERS
        // DIFFERENTLY. Its manifest `pathPrefix` filter really does deliver these, so it
        // has to send them back out; Apple's `*` pattern never matches them, so here they
        // are URLs that were never ours.
        XCTAssertNil(AppLinkResolver.resolve(url("https://www.distronode.com/dashboard/districts-of-europe")))
        XCTAssertNil(AppLinkResolver.resolve(url("https://www.distronode.com/dashboard/districtai-pricing")))
    }

    func testAnUnclaimedPathOnAClaimedHostIsRefused() {
        XCTAssertNil(AppLinkResolver.resolve(url("https://www.distronode.com/pricing")))
        XCTAssertNil(AppLinkResolver.resolve(url("https://www.distronode.com")))
    }

    /// ⛔ A MALFORMED URL IS REFUSED, NOT GUESSED AT AND NOT HANDED TO A BROWSER. Handing
    /// one to the browser sheet would be worse than doing nothing: the value that reaches
    /// `SFSafariViewController` is the value the OS delivered, and a URL with no host is
    /// not a page anybody can be shown.
    ///
    /// ⚠️ EACH CANDIDATE IS SKIPPED WHEN `URL(string:)` REFUSES IT OUTRIGHT, BECAUSE
    /// DARWIN AND LINUX DO NOT AGREE ON WHICH OF THESE PARSE. The counter is what stops
    /// that tolerance turning into a test that asserts nothing on the platform that
    /// matters: at least one has to have reached the resolver.
    func testAMalformedURLIsRefusedRatherThanActedOn() {
        let candidates = [
            "https://",
            "https:///dashboard/district",
            "https:///dashboard/district/inbox",
            "https://:8443/dashboard/district",
        ]
        var reached = 0
        for candidate in candidates {
            guard let parsed = URL(string: candidate) else { continue }
            XCTAssertNil(AppLinkResolver.resolve(parsed), candidate)
            reached += 1
        }
        XCTAssertGreaterThan(reached, 0, "no candidate parsed, so the resolver was never actually asked")
    }

    // MARK: - Both claimed hosts

    func testBothClaimedHostsResolve() {
        // ⚠️ The apex is accepted here although the entitlement claims only `www`; see
        // the ⚠️ on `AppLinkResolver.hosts`.
        XCTAssertEqual(destination("https://distronode.com/dashboard/district")?.section, .overview)
        XCTAssertEqual(destination("https://www.distronode.com/dashboard/district")?.section, .overview)
    }

    func testTheHostIsCaseFolded() {
        XCTAssertEqual(destination("https://WWW.Distronode.COM/dashboard/district/inbox")?.section, .inbox)
    }

    func testTheSchemeIsCaseFolded() {
        XCTAssertEqual(destination("HTTPS://www.distronode.com/dashboard/district")?.section, .overview)
    }

    // MARK: - The root and its equivalents

    func testTheDashboardRootAndItsTrailingSlashesAreAllTheOverview() {
        // ⚠️ These are one page to the web server, so they have to be one destination
        // here: a link copied with a trailing slash behaving differently from the same
        // link without one is indistinguishable from a bug.
        // ⛔ AND THE ROOT IS STILL THE OVERVIEW AFTER THE FALLBACK CHANGED. It reaches
        // that section because it NAMES it, not because it fell through to it.
        for path in ["/dashboard/district", "/dashboard/district/", "/dashboard/district//"] {
            let resolved = destination("https://www.distronode.com" + path)
            XCTAssertEqual(resolved?.section, .overview, path)
            XCTAssertNil(resolved?.detailId, path)
        }
    }

    // MARK: - The mapped sections

    func testEveryMappedSectionResolves() {
        let expected: [String: DistrictSection] = [
            "inbox": .inbox,
            "calls": .calls,
            "contacts": .contacts,
            "analytics": .analytics,
            "scheduling": .scheduling,
            "devices": .devices,
        ]
        for (segment, section) in expected {
            let resolved = destination("https://www.distronode.com/dashboard/district/" + segment)
            XCTAssertEqual(resolved?.section, section, segment)
            XCTAssertNil(resolved?.detailId, segment)
        }
    }

    func testTheSegmentIsCaseFolded() {
        // ⚠️ A path is case-sensitive to a server, but a shared link is retyped by
        // humans. Folding can only widen what reaches a real section.
        XCTAssertEqual(destination("https://www.distronode.com/dashboard/district/Inbox")?.section, .inbox)
    }

    // MARK: - The fallback

    /// ⛔ THE BROWSER, NOT THE OVERVIEW, AND THIS TEST ASSERTED THE OPPOSITE UNTIL THE
    /// FALLBACK RULE CHANGED. Every segment below is a real web page with no screen on
    /// this client; landing them on the overview resolved the tap onto a screen the user
    /// did not ask for and said nothing about the page they did.
    func testAnUnmappedPageOpensInTheBrowserRatherThanTheOverview() {
        let unmapped = [
            "settings", "hq", "billing", "marketplace", "workflows", "rooms",
            "meetings", "live", "campaigns", "dgi", "support", "desk", "workspaces",
        ]
        for segment in unmapped {
            let resolved = AppLinkResolver.resolve(url("https://www.distronode.com/dashboard/district/" + segment))
            XCTAssertEqual(resolved, AppLinkOutcome.openInBrowser, segment)
        }
    }

    func testAnUnmappedSectionCarriesNoWorkspaceEither() {
        // ⚠️ The query item is not read at all once the section falls through, so a link
        // naming a tenant cannot switch the app to it on the way out to a browser.
        let resolved = AppLinkResolver.resolve(
            url("https://www.distronode.com/dashboard/district/billing?workspaceId=ws-2")
        )
        XCTAssertEqual(resolved, AppLinkOutcome.openInBrowser)
    }

    func testOnlyTheFirstSegmentDecidesTheOutcome() {
        // `billing/invoices` is a sub-page of a section this app does not map; it goes
        // where `billing` goes.
        let resolved = AppLinkResolver.resolve(
            url("https://www.distronode.com/dashboard/district/billing/invoices")
        )
        XCTAssertEqual(resolved, AppLinkOutcome.openInBrowser)
    }

    func testAMeetingIdIsNeverCarried() {
        // ⛔ `Route.activeRoom` needs the full `meet_<workspaceId>_<suffix>` name, and
        // rebuilding one from a URL segment is how a billable `video_` name gets built by
        // mistake. There is now no destination to carry it ON: `meetings` is unmapped, so
        // the whole URL goes to the web page that does own the room.
        let resolved = AppLinkResolver.resolve(
            url("https://www.distronode.com/dashboard/district/meetings/abc123")
        )
        XCTAssertEqual(resolved, AppLinkOutcome.openInBrowser)
    }

    // MARK: - The one drill-down

    func testACallIdIsCarried() {
        let resolved = destination("https://www.distronode.com/dashboard/district/calls/call-42")
        XCTAssertEqual(resolved?.section, .calls)
        XCTAssertEqual(resolved?.detailId, "call-42")
    }

    func testOnlyTheFirstSegmentAfterCallsIsTheId() {
        let resolved = destination("https://www.distronode.com/dashboard/district/calls/call-42/transcript")
        XCTAssertEqual(resolved?.section, .calls)
        XCTAssertEqual(resolved?.detailId, "call-42")
    }

    func testADeeperPathUnderAnyOtherMappedSectionCarriesNoDetail() {
        let resolved = destination("https://www.distronode.com/dashboard/district/contacts/contact-9")
        XCTAssertEqual(resolved?.section, .contacts)
        XCTAssertNil(resolved?.detailId)
    }

    // MARK: - The workspace query item

    func testTheWorkspaceIdQueryItemIsCarried() {
        let resolved = destination("https://www.distronode.com/dashboard/district/inbox?workspaceId=ws-2")
        XCTAssertEqual(resolved?.section, .inbox)
        XCTAssertEqual(resolved?.workspaceId, "ws-2")
    }

    func testAnEmptyWorkspaceIdIsTreatedAsAbsent() {
        // ⚠️ What a truncated or hand-edited link looks like. Switching to a workspace
        // named by the empty string cannot succeed.
        let resolved = destination("https://www.distronode.com/dashboard/district/inbox?workspaceId=")
        XCTAssertNil(resolved?.workspaceId)
    }

    func testOtherQueryItemsAndFragmentsAreIgnored() {
        let resolved = destination("https://www.distronode.com/dashboard/district/calls?utm_source=email&page=2#top")
        XCTAssertEqual(resolved?.section, .calls)
        XCTAssertNil(resolved?.workspaceId)
        XCTAssertNil(resolved?.detailId)
    }

    func testNoQueryAtAllIsNotAWorkspace() {
        XCTAssertNil(destination("https://www.distronode.com/dashboard/district")?.workspaceId)
    }

    // MARK: - Waiting for a workspace

    func testOnlyTheDestinationsThatNeedAnIdWait() {
        // ⛔ WAIT, NOT NOWHERE. The tabs carry no tenant, so they can be selected while
        // the workspace list is still in flight; the three that become a `Route` cannot.
        XCTAssertFalse(AppLinkDestination(section: .overview).requiresWorkspace)
        XCTAssertFalse(AppLinkDestination(section: .inbox).requiresWorkspace)
        XCTAssertFalse(AppLinkDestination(section: .contacts).requiresWorkspace)
        XCTAssertFalse(AppLinkDestination(section: .devices).requiresWorkspace)

        XCTAssertTrue(AppLinkDestination(section: .analytics).requiresWorkspace)
        XCTAssertTrue(AppLinkDestination(section: .scheduling).requiresWorkspace)
    }

    func testTheCallLogWaitsOnlyWhenItCarriesAnId() {
        XCTAssertFalse(AppLinkDestination(section: .calls).requiresWorkspace)
        XCTAssertTrue(AppLinkDestination(section: .calls, detailId: "call-42").requiresWorkspace)
    }

    // MARK: - Helpers

    /// The in-app destination a URL resolves to, or nil for either of the other two
    /// answers.
    ///
    /// ⚠️ THIS HELPER IS DELIBERATELY NOT USED FOR A REFUSAL ASSERTION. It flattens nil
    /// and ``AppLinkOutcome/openInBrowser`` into the same nil, so a test that used it to
    /// prove "this URL is refused" would pass just as happily on a URL handed to a
    /// browser. Those two are asserted on ``AppLinkResolver/resolve(_:)`` directly.
    private func destination(_ string: String) -> AppLinkDestination? {
        guard let outcome = AppLinkResolver.resolve(url(string)) else { return nil }
        guard case let .destination(resolved) = outcome else { return nil }
        return resolved
    }

    /// ⚠️ FORCE-UNWRAPPED IN A TEST ONLY. Every string here is a literal in this file,
    /// so a nil is a typo in the test rather than a runtime condition worth handling.
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }
}
