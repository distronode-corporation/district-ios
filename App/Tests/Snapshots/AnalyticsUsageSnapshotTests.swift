@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The Analytics usage cards drawn from the service's recorded usage month and history.
///
/// ⚠️ THE CARDS, NOT THE SCREEN: `usage` and `usage history` are one path that differs only
/// by its query, and ``FixtureTransport`` answers by path, so the screen cannot be given
/// both recorded bodies. Each card takes its decoded value directly, the way the screen
/// hands it on.
final class AnalyticsUsageSnapshotTests: ScreenSnapshotTestCase {
    private static func decode<T: Decodable>(_: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: FixtureTransport.fixtureData(name))
    }

    /// This month's recorded usage: every metered line the service sent, zero included.
    func testUsageThisMonth() async throws {
        let usage = try Self.decode(UsageResponse.self, "district-usage").usage
        try await assertScreen { _ in
            AnalyticsUsageCard(usage: usage).padding()
        }
    }

    /// Nothing metered this month: the card says so rather than drawing zeros.
    func testUsageThisMonthEmpty() async throws {
        let usage = try Self.decode(UsageResponse.self, "district-usage-empty").usage
        XCTAssertNil(usage)
        try await assertScreen(devices: [.iPhone]) { _ in
            AnalyticsUsageCard(usage: usage).padding()
        }
    }

    /// Three recorded months, newest first, the older ones sparse: bars scaled to the
    /// busiest month, and a month with no call minutes drawn without a bar.
    func testUsageHistory() async throws {
        let months = try Self.decode(UsageHistoryResponse.self, "district-usage-history").usage
        try await assertScreen { _ in
            AnalyticsHistoryCard(months: months).padding()
        }
    }

    /// No history: the card's own sentence.
    func testUsageHistoryEmpty() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            AnalyticsHistoryCard(months: []).padding()
        }
    }

    /// Only the lines the service sent become rows, in the card's fixed order.
    func testUsageRowsSkipWhatWasNotSent() throws {
        let months = try Self.decode(UsageHistoryResponse.self, "district-usage-history").usage
        let june = try XCTUnwrap(months.last)
        XCTAssertEqual(AnalyticsUsageCard.rows(june).map(\.label), [AnalyticsCopy.smsSent])
        XCTAssertEqual(AnalyticsUsageCard.rows(june).map(\.amount), [12])

        let august = try XCTUnwrap(months.first)
        XCTAssertEqual(AnalyticsUsageCard.rows(august).first?.label, AnalyticsCopy.smsSent)
        XCTAssertTrue(
            AnalyticsUsageCard.rows(august).contains { $0.label == AnalyticsCopy.whatsappSent && $0.amount == 0 },
            "a zero the service sent is a row"
        )
        XCTAssertFalse(AnalyticsUsageCard.rows(august).contains { $0.label == AnalyticsCopy.whatsappReceived })
    }
}
