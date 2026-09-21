import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the calls, softphone and analytics DTOs.
///
/// ⚠️ THE STRICT GATE AND THESE TESTS DO DIFFERENT JOBS AND BOTH ARE NEEDED.
/// `StrictDecodeVerifier` proves the DTO's key set matches the server's exactly;
/// it deliberately does not compare values. What it therefore cannot notice is a
/// fixture being REGENERATED against thinner data — every key still present,
/// every awkward branch gone. These tests pin the branches each fixture is
/// supposed to cover, so a regeneration that stopped exercising one fails here.
final class CallsAnalyticsContractTests: XCTestCase {
    // MARK: - Transcript

    /// ⛔ THE "NOTHING TO SHOW" TEST IS `isEmpty`, NOT A NIL CHECK. The handler
    /// writes `call.transcript || ""`, so a nil check would never fire and an
    /// empty transcript would render as if it had content.
    func testTranscriptIsANonOptionalStringWithAnEmptyAbsence() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-call-transcript.json",
            as: CallTranscriptResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertTrue(response.transcript.contains("Caller:"), "the fixture covers a two-speaker transcript")
        XCTAssertTrue(response.hasTranscript)

        // ⚠️ DECODED RATHER THAN CONSTRUCTED. The DTOs publish no memberwise
        // initialiser — they are wire shapes, and a synthesised `internal` init
        // is not reachable from this module anyway — so a synthetic branch is
        // exercised the way the app would reach it.
        let empty = try decode(CallTranscriptResponse.self, from: #"{"success":true,"transcript":"   "}"#)
        XCTAssertFalse(empty.hasTranscript, "whitespace is not content")
    }

    // MARK: - The feed row: the transcript flag and phone intel

    /// ⛔ THE TEXT IS NOT IN THE FEED BUT THE KEY IS. `transcript` stays, always
    /// empty, because builds already installed require it; `hasTranscript` is
    /// what says the transcript route has something, and `phoneIntel` describes
    /// the other party. Both branches of the carrier half are pinned: a stored
    /// lookup on the answered caller, none on the missed one.
    func testFeedCarriesTheTranscriptFlagAndPhoneIntel() throws {
        let calls = try StrictDecodeVerifier.verify(
            fixture: "district-calls.json",
            as: [CallSummary].self
        )
        let byId = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
        let answered = try XCTUnwrap(byId["call_contract_answered"])
        let missed = try XCTUnwrap(byId["call_contract_missed"])
        let outbound = try XCTUnwrap(byId["call_contract_outbound"])

        XCTAssertEqual(answered.transcript, "", "the feed must never carry transcript text")
        XCTAssertEqual(answered.hasTranscript, true)
        XCTAssertEqual(missed.hasTranscript, false)

        let intel = try XCTUnwrap(answered.phoneIntel)
        XCTAssertEqual(intel.country, "CA")
        XCTAssertEqual(intel.region?.code, "ON")
        XCTAssertEqual(intel.lineType, "mobile")
        XCTAssertEqual(intel.carrier, "Rogers")
        XCTAssertNil(missed.phoneIntel?.lineType, "no stored lookup means no line type")
        XCTAssertNotNil(missed.phoneIntel?.nationalFormat)
        // An outbound row with no recorded callee describes nobody, never our own trunk.
        XCTAssertNil(outbound.phoneIntel)

        let detail = try StrictDecodeVerifier.verify(
            fixture: "district-contact-detail.json",
            as: ContactDetailResponse.self
        )
        XCTAssertEqual(detail.phoneIntel?.region?.code, "ON")
        XCTAssertEqual(detail.phoneIntel?.internationalFormat, "+1 416 555 1234")
    }

    // MARK: - The softphone dial

    /// ⛔ THE PREFIX IS THE ASSERTION THAT KEEPS THE AI OFF A HUMAN'S CALL. The
    /// voice agent auto-dispatches into every room it does not refuse and refuses
    /// `direct_` BY NAME, so a server that started answering with a different
    /// prefix would put an agent on the line. This client never builds the name;
    /// it checks the one it is given.
    func testDialAnswersADirectRoomAndAMediaNodeUrl() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-dial.json",
            as: DialResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertTrue(
            response.roomName.hasPrefix(DialRoom.directPrefix),
            "a non-direct_ prefix would let the voice agent join the operator's own call"
        )
        // ⚠️ The room name embeds the call id, which is why nothing here mints one.
        XCTAssertTrue(response.roomName.hasSuffix(response.callId))
        XCTAssertFalse(response.token.isEmpty)
        // ⛔ The TRUNK's deployment, used verbatim — not derived from the region.
        XCTAssertTrue(response.url.hasPrefix("wss://"))
    }

    /// ⛔ TWO REFUSALS OF ONE BILLABLE ROUTE, AND ONLY ONE OF THEM HAS A CODE.
    /// The DNC 403 carries a sentence and nothing else, so the sentence is all a
    /// client has; the 402 carries `code` and must be branched on that.
    func testDialRefusalsCarryTheirDistinctShapes() throws {
        let dnc = try StrictDecodeVerifier.verify(
            fixture: "district-dial-dnc.json",
            as: ApiErrorEnvelope.self
        )
        XCTAssertEqual(dnc.success, false)
        XCTAssertNil(dnc.code, "the DNC refusal has nothing to branch on")
        XCTAssertTrue(dnc.error?.contains("DNC") ?? false)

        let lapsed = try StrictDecodeVerifier.verify(
            fixture: "district-dial-subscription.json",
            as: SubscriptionInactiveError.self
        )
        XCTAssertFalse(lapsed.success)
        XCTAssertEqual(lapsed.code, ApiErrorCode.subscriptionInactive)
        // ⛔ DIAGNOSTIC ONLY. Which Stripe states count as delinquent is the
        // server's decision, so nothing may branch on this — it is asserted here
        // solely to prove the key is modelled, which is why this body needs its
        // own type instead of ApiErrorEnvelope.
        XCTAssertEqual(lapsed.status, "past_due")
        XCTAssertFalse(lapsed.error.isEmpty)
    }

    /// ⛔ THE THIRD REFUSAL, AND THE ONLY ONE WITH A WAY OUT. The dormancy 403 is
    /// shaped exactly like the DNC one plus a `code`, and that code is the whole
    /// difference: without branching on it the app draws a refusal the operator
    /// can do nothing about, when in fact the dashboard's reactivation route
    /// turns the workspace back on.
    ///
    /// ⚠️ THE SENTENCE IS ASSERTED VERBATIM BECAUSE IT IS SERVER-OWNED COPY. It
    /// is the only place the 100-day window and the reactivation instruction are
    /// stated, so a client that paraphrases it tells the operator something the
    /// server did not say, and a regeneration that thins it out has to be
    /// visible here rather than on a phone.
    func testDormancyRefusalCarriesTheCodeThatOffersAWayOut() throws {
        let dormant = try StrictDecodeVerifier.verify(
            fixture: "district-dial-dormant.json",
            as: ApiErrorEnvelope.self
        )
        XCTAssertEqual(dormant.success, false)
        XCTAssertEqual(dormant.code, ApiErrorCode.workspaceDormant)
        XCTAssertEqual(
            dormant.error,
            "This workspace has not sent anything for 100 days, so outbound calling and "
                + "messaging are paused pending an account review. Request reactivation from "
                + "your dashboard and we will re-enable it."
        )
    }

    // MARK: - Analytics

    /// ⛔ EVERY NUMBER IS THE SERVER'S AND NONE OF THEM MAY BE RE-DERIVED. The
    /// two traps pinned here are the ones that produce plausible wrong answers
    /// rather than obvious ones: `conversionRate` is already a percentage, and
    /// `avgDuration` averages COMPLETED calls while `calls` counts all of them —
    /// so a bucket with traffic and a zero average is correct, not corrupt.
    func testAnalyticsCarriesServerDerivedTotalsAndAFullTrendSeries() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-analytics.json",
            as: AnalyticsResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.metrics.totalCalls, 48)
        XCTAssertLessThanOrEqual(response.metrics.conversionRate, 100, "already a percentage, never a ratio")
        // ⛔ HARDCODED ZERO SERVER-SIDE. There is no live-agent presence signal in
        // this product; a tile built on it would read "0 agents online" forever.
        XCTAssertEqual(response.metrics.activeAgents, 0)

        // ⚠️ The bars sum to totalCalls; the averages do not sum to anything.
        XCTAssertEqual(response.engagementTrends.reduce(0) { $0 + $1.calls }, response.metrics.totalCalls)
        XCTAssertTrue(
            response.engagementTrends.contains { $0.calls > 0 && $0.avgDuration == 0 },
            "the fixture must keep a bucket with traffic and a zero completed-call average"
        )

        // ⛔ isoDate is the only sortable field. `date` is operator-localised
        // display text with no year and must never be parsed.
        let isoDates = response.engagementTrends.map(\.isoDate)
        XCTAssertEqual(isoDates, isoDates.sorted(), "the series is oldest-first")
        XCTAssertTrue(response.engagementTrends.allSatisfy { !$0.date.contains("-") })

        XCTAssertEqual(response.funnelData.map(\.name).first, "Total Dials")
        XCTAssertEqual(
            response.funnelData.map(\.count),
            response.funnelData.map(\.count).sorted(by: >),
            "the funnel is ordered widest first and this client preserves that order"
        )
        // ⚠️ All three slices always present, and `color` stays an opaque String.
        XCTAssertEqual(response.sentimentDistribution.count, 3)
        XCTAssertTrue(response.sentimentDistribution.allSatisfy { $0.color.hasPrefix("#") })
    }

    /// ⛔ nil `pct` MEANS "New", NOT 0%. The fixture that pins it
    /// (`district-analytics-new-workspace.json`) carries an explicit null and so
    /// cannot enter the strict gate without an allowlist decision — which is
    /// exactly why the branch is asserted on the type here rather than left to a
    /// fixture nobody can gate.
    func testCallVolumeDeltaSeparatesTheArrowFromThePercentage() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-analytics.json",
            as: AnalyticsResponse.self
        )
        XCTAssertEqual(response.callVolumeDelta.direction, CallVolumeDirection.up)
        XCTAssertEqual(response.callVolumeDelta.pct, 20)
        XCTAssertFalse(response.callVolumeDelta.isNew)

        // A first-ever week: `up` with no baseline to be a percentage of. Both
        // no-baseline rows are decoded from the exact bytes the route emits —
        // `pct` as an explicit null, which is the shape the strict gate cannot
        // accept and the runtime parser must.
        let brandNew = try decode(
            CallVolumeDelta.self,
            from: #"{"current":3,"prior":0,"pct":null,"direction":"up"}"#
        )
        XCTAssertTrue(brandNew.isNew)
        XCTAssertEqual(brandNew.direction, CallVolumeDirection.up)
        // And the other half of the same shape: nothing then, nothing now.
        let quiet = try decode(
            CallVolumeDelta.self,
            from: #"{"current":0,"prior":0,"pct":null,"direction":"flat"}"#
        )
        XCTAssertTrue(quiet.isNew)
        XCTAssertEqual(quiet.direction, CallVolumeDirection.flat)
        XCTAssertEqual(CallVolumeDirection.down, "down")
    }

    // ⚠️ THE `range` WINDOW IS NOT ASSERTED HERE. `AnalyticsRange` is a REQUEST
    // concern and lives in `DistrictNetwork`, where `RoomNameTests` already pins
    // its three wire values — the contract this response side depends on is the
    // BUCKETING those values imply (daily for 7d/30d, weekly for 90d), which is
    // why `EngagementPoint` documents it and nothing here assumes a series
    // length.
}

/// Decode a literal body into a DTO.
///
/// ⚠️ FOR SYNTHETIC BRANCHES ONLY — anything that models a real response goes
/// through `StrictDecodeVerifier` so the key set is checked too. This exists for
/// the shapes a committed fixture cannot carry, notably an explicit `null` the
/// no-nulls invariant would reject.
func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
