@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The analytics window and the two metered-usage reads.
///
/// ⚠️ A SEPARATE FILE FROM `RepositoryTests`, for the reason that file's own header
/// gives about the inbox: SwiftLint's ceilings are 500 lines per file and 400 per
/// type, and `RepositoryTests` is already within tens of the first. The split is by
/// SURFACE.
///
/// ⛔ THE ASSERTIONS THAT MATTER HERE ARE ABOUT WHAT IS NOT COLLAPSED. `usage: null`
/// must arrive as a SUCCESS carrying nil ("we asked, and nothing is recorded") while
/// an unaffirmed envelope must arrive as a FAILURE ("we could not find out"), and
/// the screen says different things about them. A repository that folded either way
/// would put a fabricated billing figure on a screen or a retry button under a
/// correct answer.
final class AnalyticsRepositoryTests: XCTestCase {
    // MARK: - Analytics

    /// ⛔ THE WINDOW MUST REACH THE WIRE AS ITS OWN VALUE. An unrecognised
    /// `timeRange` is not an error server-side — the route silently serves 7d with a
    /// 200 — so a wrong value here shows a week's figures under a 90-day heading with
    /// nothing anywhere reporting a problem.
    func testTheAnalyticsWindowReachesTheWireAsItsOwnValue() async {
        let transport = RepositoryTransport(json: Self.analytics())

        let result = await AnalyticsRepository(client: .repositoryTest(transport))
            .analytics(workspaceId: "ws_1", range: .ninetyDays)

        XCTAssertEqual(result.successOnly?.metrics.totalCalls, 48)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/analytics?workspaceId=ws_1&timeRange=90d"
        )
    }

    /// ⛔ AN EMPTY `{}` MUST NOT DECODE. Every field of the Kotlin DTO carries a
    /// default, which is why its repository's envelope check is load-bearing; here
    /// the required keys do most of that work, and this is the test that says so.
    func testAnEmptyAnalyticsBodyIsADecodeFailure() async {
        let repository = AnalyticsRepository(client: .repositoryTest(RepositoryTransport(json: "{}")))

        let result = await repository.analytics(workspaceId: "ws_1", range: .sevenDays)

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH: every required key present and the
    /// flag false. Without the envelope guard this renders as zero calls, zero
    /// conversions and a flat trend — a fabricated empty state an operator cannot
    /// tell from a genuinely quiet week.
    func testAnalyticsThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = Self.analytics().replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let repository = AnalyticsRepository(client: .repositoryTest(RepositoryTransport(json: body)))

        let result = await repository.analytics(workspaceId: "ws_1", range: .sevenDays)

        XCTAssertEqual(result.failureOnly, .decoding("AnalyticsResponse did not affirm success=true"))
    }

    /// ⚠️ THE PROOF THAT A SEGMENTED `Picker` CAN TAG ITS SEGMENTS WITH THIS TYPE,
    /// taken on the Linux tier where SwiftUI does not exist. `Picker(selection:)`
    /// requires a `Hashable` tag and ``AnalyticsRange`` declares only
    /// `Sendable, CaseIterable`; the conformance it relies on is the one Swift
    /// synthesises for an enum with no associated values, which is a LANGUAGE rule
    /// and therefore checkable here. Keying a dictionary by it fails to compile the
    /// day that stops being true, rather than on a macOS runner weeks later.
    func testEveryWindowCanTagAPickerSegment() {
        let labels: [AnalyticsRange: String] = [
            .sevenDays: "7 days",
            .thirtyDays: "30 days",
            .ninetyDays: "90 days",
        ]

        XCTAssertEqual(AnalyticsRange.allCases.compactMap { labels[$0] }.count, 3)
        XCTAssertEqual(AnalyticsRange.allCases.map(\.wire), ["7d", "30d", "90d"])
    }

    // MARK: - This month's usage

    /// ⛔ THE NULL IS THE PAYLOAD, NOT AN ABSENCE OF ONE. `.success(nil)` is what
    /// lets the screen say "no usage has been recorded yet" instead of drawing a
    /// column of zeros beside billing labels.
    ///
    /// ⚠️ THE REQUEST CARRIES NEITHER SWITCH. `history` and `months` are passed as
    /// explicit nils so the call site reads as the history read with the switch off,
    /// and ``ApiURL`` drops them — `history=false` would be a different claim about
    /// the route.
    func testAMonthWithNothingMeteredIsASuccessCarryingNil() async {
        let transport = RepositoryTransport(json: #"{"success":true,"usage":null}"#)

        let result = await AnalyticsRepository(client: .repositoryTest(transport)).usage(workspaceId: "ws_1")

        guard case let .success(usage) = result else {
            return XCTFail("a null usage is an answer, not a failure: \(result)")
        }
        XCTAssertNil(usage)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/usage?workspaceId=ws_1"
        )
    }

    func testAPopulatedMonthIsUnwrappedFromItsEnvelope() async {
        let transport = RepositoryTransport(json: Self.usage())

        let result = await AnalyticsRepository(client: .repositoryTest(transport)).usage(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly??.month, "2026-08")
        XCTAssertEqual(result.successOnly??.smsOutbound, 412)
        // ⛔ Fractional, which is what forces `Double` on every metric.
        XCTAssertEqual(result.successOnly??.callMinutesInbound, 1204.25)
    }

    /// ⛔ "WE COULD NOT FIND OUT" IS NOT "THERE IS NOTHING". A 200 whose envelope
    /// does not affirm success must not become the same `.success(nil)` a genuinely
    /// unmetered month produces, because the screen offers a retry for one and a
    /// settled sentence for the other.
    func testAnUnaffirmedUsageEnvelopeIsAFailureRatherThanAnEmptyMonth() async {
        let transport = RepositoryTransport(json: #"{"success":false,"usage":null}"#)

        let result = await AnalyticsRepository(client: .repositoryTest(transport)).usage(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("UsageResponse did not affirm success=true"))
    }

    // MARK: - The history

    /// ⚠️ THE DEFAULT SPAN IS THE REPOSITORY'S, NOT THE CALLER'S. Naming a number at
    /// each call site would be a second copy of a decision that has to match the web
    /// console, and two surfaces showing different spans under one "Recent months"
    /// heading is exactly how that drift presents.
    func testTheHistorySpanDefaultsToTheOneTheWebConsoleAsksFor() async {
        let transport = RepositoryTransport(json: Self.history())

        let result = await AnalyticsRepository(client: .repositoryTest(transport))
            .usageHistory(workspaceId: "ws_1")

        XCTAssertEqual(AnalyticsRepository.defaultHistoryMonths, 3)
        XCTAssertEqual(result.successOnly?.map(\.month), ["2026-08", "2026-07"])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/usage?workspaceId=ws_1&history=true&months=3"
        )
    }

    /// ⚠️ AN EMPTY LIST IS "NOTHING HAS EVER BEEN METERED", AND IT IS A SUCCESS. The
    /// server appends only months that had rows, so a short or empty answer is
    /// ordinary rather than a truncated one.
    func testAnExplicitSpanIsSentAndAnEmptyHistoryIsASuccess() async {
        let transport = RepositoryTransport(json: #"{"success":true,"usage":[]}"#)

        let result = await AnalyticsRepository(client: .repositoryTest(transport))
            .usageHistory(workspaceId: "ws_1", months: 24)

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/usage?workspaceId=ws_1&history=true&months=24"
        )
    }

    /// The same distinction as the current month's: a refused envelope is a failure,
    /// never an empty list.
    func testAnUnaffirmedHistoryEnvelopeIsAFailureRatherThanAnEmptyList() async {
        let transport = RepositoryTransport(json: #"{"success":false,"usage":[]}"#)

        let result = await AnalyticsRepository(client: .repositoryTest(transport))
            .usageHistory(workspaceId: "ws_1", months: 3)

        XCTAssertEqual(result.failureOnly, .decoding("UsageHistoryResponse did not affirm success=true"))
    }

    // MARK: - Bodies

    // ⚠️ LOCAL TO THIS FILE RATHER THAN IN `Bodies`, and small on purpose: these are
    // the smallest documents that satisfy the Swift types, so each test is about
    // envelope handling and query construction rather than about JSON. The wire
    // shape is pinned by the contract fixtures, which is a different job.

    private static func analytics() -> String {
        #"""
        {"success":true,
         "metrics":{"totalCalls":48,"avgDuration":120,"conversionRate":38,
                    "abandonedCalls":4,"missedCalls":9,"activeAgents":0},
         "callVolumeDelta":{"current":48,"prior":40,"pct":20,"direction":"up"},
         "engagementTrends":[{"date":"Aug 15","isoDate":"2026-08-15","calls":48,"avgDuration":120}],
         "funnelData":[{"name":"Total Dials","count":48}],
         "sentimentDistribution":[{"name":"Positive Sentiment","value":21,"color":"#10b981"}]}
        """#
    }

    private static func usage() -> String {
        #"""
        {"success":true,
         "usage":{"month":"2026-08","smsOutbound":412,"callMinutesInbound":1204.25}}
        """#
    }

    private static func history() -> String {
        #"""
        {"success":true,
         "usage":[{"month":"2026-08","smsOutbound":412},{"month":"2026-07"}]}
        """#
    }
}
