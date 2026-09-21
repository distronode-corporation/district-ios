import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the two metered-usage shapes.
///
/// ⚠️ THE STRICT GATE AND THESE TESTS DO DIFFERENT JOBS. `StrictDecodeVerifier`
/// proves the key set matches the server's exactly and deliberately compares no
/// values; what it therefore cannot notice is a fixture REGENERATED against
/// thinner data — every key still present, every awkward branch gone. The three
/// branches this surface exists to keep apart are all value-level: a metric
/// measured at zero, a metric never metered, and a month with nothing metered at
/// all. They are pinned here.
final class UsageContractTests: XCTestCase {
    // MARK: - The current month

    /// ⛔ ZERO AND ABSENT ARE DIFFERENT FACTS, AND ONE FIXTURE CARRIES BOTH.
    /// `whatsappOutbound` is present as `0` (the channel is metered and was quiet)
    /// while `whatsappInbound` has no key at all (it is not metered for this
    /// workspace). Defaulting the second to zero would make an unmetered channel
    /// look like an idle one, under a billing label.
    ///
    /// ⛔ AND THE MINUTES ARE FRACTIONAL, which is what forces `Double`. An `Int`
    /// property fails to decode `1204.25` outright, and the obvious "fix" of
    /// rounding would round a bill.
    func testTheCurrentMonthKeepsAMeteredZeroApartFromAnAbsentMetric() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-usage.json",
            as: UsageResponse.self
        )
        XCTAssertTrue(response.success)
        let usage = try XCTUnwrap(response.usage)

        XCTAssertEqual(usage.month, "2026-08")
        XCTAssertEqual(usage.provider, "twilio")
        XCTAssertEqual(usage.smsOutbound, 412)
        XCTAssertEqual(usage.smsInbound, 87)
        XCTAssertEqual(usage.mmsOutbound, 6)
        XCTAssertEqual(usage.numberCount, 3)
        XCTAssertEqual(usage.videoMinutes, 42)
        XCTAssertEqual(usage.lastUpdated, "2026-08-15T14:30:00.000Z")

        XCTAssertEqual(usage.whatsappOutbound, 0, "metered and quiet")
        XCTAssertNil(usage.whatsappInbound, "not metered at all, which is not the same claim")

        XCTAssertEqual(usage.callMinutesOutbound, 318.5)
        XCTAssertEqual(usage.callMinutesInbound, 1204.25, "an Int property could not hold this")
    }

    /// ⛔ `usage: null` IS "NOTHING METERED THIS MONTH", NOT ZERO OF EVERYTHING.
    /// The fixture is that one null and nothing else, which is why it needs the
    /// single allowlist entry rather than a loosened invariant.
    func testAMonthWithNoMeteringRowsAnswersNullRatherThanZeros() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-usage-empty.json",
            as: UsageResponse.self
        )
        XCTAssertTrue(response.success, "a 200 that affirms success, carrying nothing")
        XCTAssertNil(response.usage)
    }

    // MARK: - The history

    /// ⛔ THE SPARSE ROWS ARE THE POINT OF THIS FIXTURE. Its second and third
    /// months omit the metrics nobody metered rather than nulling them, so this is
    /// the shape that proves absence survives the round trip — Swift writes a nil
    /// Optional as an ABSENT key, so a DTO that defaulted these would re-encode
    /// keys the server never sent and fail the gate's key-set walk.
    ///
    /// ⚠️ NEWEST FIRST, AS SENT. Asserted rather than sorted: `month` is a
    /// `YYYY-MM` string that happens to sort correctly, which is exactly the kind
    /// of accident a re-sort would come to depend on.
    func testTheHistoryIsNewestFirstAndKeepsUnmeteredMetricsAbsent() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-usage-history.json",
            as: UsageHistoryResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.usage.map(\.month), ["2026-08", "2026-07", "2026-06"])

        let sparse = response.usage[1]
        XCTAssertEqual(sparse.smsOutbound, 355)
        XCTAssertEqual(sparse.callMinutesOutbound, 290.75)
        XCTAssertEqual(sparse.numberCount, 3)
        XCTAssertNil(sparse.provider, "the row carries no provider, which is the ordinary case")
        XCTAssertNil(sparse.smsInbound)
        XCTAssertNil(sparse.callMinutesInbound)
        XCTAssertNil(sparse.lastUpdated)

        // The thinnest row the corpus has: one metric and the month key.
        let thinnest = response.usage[2]
        XCTAssertEqual(thinnest.smsOutbound, 12)
        XCTAssertNil(thinnest.mmsOutbound)
        XCTAssertNil(thinnest.videoMinutes)
    }

    /// ⛔ AN EMPTY ARRAY IS "NOTHING HAS EVER BEEN METERED", NOT A FAILURE. The
    /// server appends only months that had rows, so a workspace nobody has metered
    /// answers this on a 200 — and no committed fixture carries it, which is why
    /// the branch is decoded from literal bytes here.
    func testAnEmptyHistoryIsASuccessfulAnswer() throws {
        let response = try decode(UsageHistoryResponse.self, from: #"{"success":true,"usage":[]}"#)

        XCTAssertTrue(response.success)
        XCTAssertTrue(response.usage.isEmpty)
    }

    /// ⚠️ `whatsappInbound` IS MODELLED THOUGH NO FIXTURE CARRIES IT. `UsageMetric`
    /// declares it server-side, so the day one is recorded the key must land on the
    /// property rather than being ignored — and a decode-only proof is the only one
    /// available while the corpus has no row with it.
    func testTheUnfixturedWhatsAppInboundMetricStillDecodes() throws {
        let month = try decode(UsageMonth.self, from: #"{"month":"2026-09","whatsappInbound":3.5}"#)

        XCTAssertEqual(month.whatsappInbound, 3.5)
        XCTAssertNil(month.whatsappOutbound)
    }
}
