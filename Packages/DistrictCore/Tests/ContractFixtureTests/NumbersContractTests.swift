import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the three marketplace bodies.
///
/// ⛔ THE OWNED PAIR IS THE PAIR THE STRICT GATE CANNOT SEPARATE ON ITS OWN. A
/// clean list and a `partial` one are the same type with two extra keys, and the
/// gate compares shape rather than values — so "this 200 is describing less
/// inventory than the workspace owns" is entirely value-level and only
/// assertions like these hold it. It is the dangerous middle: not the all-clear
/// and not the failure, but the answer that decodes perfectly and draws like a
/// complete one.
final class NumbersContractTests: XCTestCase {
    // MARK: - Search

    /// ⛔ THE PRICELESS ROW, LITERALLY, AND FIVE KEYS ARE ABSENT ON IT RATHER
    /// THAN NULL. The Twilio implementation swallows a failed pricing lookup and
    /// `JSON.stringify` DROPS the undefined, so a client typing `monthlyPrice` as
    /// required throws on the first search from an account with no Pricing API
    /// access — in production, with a decode failure that reads like contract
    /// drift rather than like a missing price.
    ///
    /// ⚠️ `provider` IS THE SERVER'S CHOICE ECHOED BACK, not the one that was
    /// asked for: the resolved credentials decide which carrier answered.
    func testASearchCarriesTheAnsweringCarrierAndOneRowWithNoPriceAtAll() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-numbers-search.json",
            as: NumberSearchResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.provider, "twilio")
        XCTAssertEqual(response.numbers.map(\.type), ["local", "tollFree"])

        let priced = response.numbers[0]
        XCTAssertEqual(priced.monthlyPrice, 1.15)
        XCTAssertEqual(priced.currency, "USD", "⚠️ a price with no currency must not be given a symbol")
        XCTAssertEqual(priced.locality, "Toronto")
        XCTAssertEqual(priced.setupPrice, 0, "a measured zero, not an absence")

        let unpriced = response.numbers[1]
        XCTAssertNil(unpriced.monthlyPrice, "⛔ absent, not null — the lookup was swallowed")
        XCTAssertNil(unpriced.setupPrice)
        XCTAssertNil(unpriced.currency)
        XCTAssertNil(unpriced.locality, "a toll-free result has no locality to report")
        XCTAssertNil(unpriced.region)
        XCTAssertEqual(unpriced.capabilities, ["sms", "voice"], "present and non-empty on both rows")
    }

    // MARK: - What the workspace already owns

    /// ⛔ BOTH HALVES OF THE LIST IN ONE RESPONSE, FROM DIFFERENT DATABASES. The
    /// `managed: false` rows are what the tenant's own carrier account reports;
    /// the `managed: true` rows are hub records of lines held on DISTRONODE's
    /// account, which the carrier fetch deliberately never sees. Before the hub
    /// read existed, a workspace with live managed DIDs got an empty list, which
    /// is indistinguishable from owning none.
    ///
    /// ⚠️ A CLEAN LIST CARRIES NEITHER FLAG AT ALL — absent, not false and not an
    /// empty array — which is why both are Optional and why
    /// ``OwnedNumbersResponse/failedProviderNames`` is what a caller should read.
    func testACleanOwnedListMixesBothSourcesAndCarriesNeitherDegradationFlag() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-provider-numbers.json",
            as: OwnedNumbersResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertTrue(response.numbers.contains(where: \.managed))
        XCTAssertTrue(response.numbers.contains(where: { !$0.managed }))
        XCTAssertNil(response.partial, "⚠️ absent, not false")
        XCTAssertNil(response.failedProviders, "⚠️ absent, not empty")
        XCTAssertEqual(response.failedProviderNames, [], "nothing to name, so nothing to warn about")
    }

    /// ⚠️ THE ALL-FALLBACKS ROW IS WHY EVERY ONE OF THESE FIELDS IS SHAPED THE
    /// WAY IT IS: a rebuilt number with a defaulted type and status, a provider
    /// inherited from `messagingConfig.managed`, no webhooks of the tenant's to
    /// report, no recorded price, and an EMPTY capability list rather than an
    /// absent one — which is a measured "we do not know what this line can do",
    /// not "it can do nothing".
    func testTheAllFallbacksManagedRowKeepsItsEmptyCapabilitiesAndDropsEverythingElse() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-provider-numbers.json",
            as: OwnedNumbersResponse.self
        )
        let fallback = try XCTUnwrap(response.numbers.first { $0.phoneNumber == "+18005550188" })

        XCTAssertTrue(fallback.managed, "⛔ theirs to USE, not to administer")
        XCTAssertEqual(fallback.provider, "telnyx")
        XCTAssertEqual(fallback.type, "local", "defaulted server-side")
        XCTAssertEqual(fallback.status, "active", "defaulted server-side")
        XCTAssertEqual(fallback.capabilities, [], "present and empty")
        XCTAssertNil(fallback.monthlyPrice, "absent, not null")
        XCTAssertNil(fallback.friendlyName)
        XCTAssertNil(fallback.smsUrl, "the webhooks belong to our account, not the tenant's")
        XCTAssertNil(fallback.voiceUrl)

        let own = try XCTUnwrap(response.numbers.first { !$0.managed })
        XCTAssertEqual(own.friendlyName, "Main line")
        XCTAssertNotNil(own.smsUrl)
        XCTAssertNotNil(own.voiceUrl)
        XCTAssertEqual(own.status, "in-use")
    }

    /// ⛔ THE DANGEROUS MIDDLE: A **200** CARRYING A SHORT LIST. One carrier
    /// answered, another did not, and the response decodes perfectly while
    /// describing less inventory than the workspace owns. The route reserves its
    /// 502 for "a carrier failed AND nothing resolved at all", because a failed
    /// lookup rendered as an empty list reads as "you own no numbers".
    ///
    /// ⛔ AND THE ROWS ARE STILL THERE. A screen must render the list AND name
    /// the carrier that is missing: a banner that REPLACED the list would discard
    /// an answer already in hand, and a list with no banner would draw an
    /// incomplete inventory as a complete one.
    func testAPartialOwnedListKeepsItsRowsAndNamesTheCarrierThatDidNotAnswer() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-provider-numbers-partial.json",
            as: OwnedNumbersResponse.self
        )

        XCTAssertTrue(response.success, "⛔ a 200 and an affirmed envelope, not an error")
        XCTAssertEqual(response.partial, true)
        XCTAssertEqual(response.failedProviders, ["telnyx"])
        XCTAssertEqual(response.failedProviderNames, ["telnyx"], "named so the banner can say WHICH")
        XCTAssertFalse(response.numbers.isEmpty, "⛔ the answer already in hand is not discarded")
    }

    /// ⚠️ THE TWO FLAGS READ AS ONE FACT, AND THIS IS THE CASE THAT PROVES IT.
    /// The route sends `failedProviders` only alongside `partial`, so a body
    /// carrying names WITHOUT the flag is drift rather than a warning — and
    /// surfacing names off it would tell an operator their list is short when
    /// nothing said so. Decoded from literal bytes; no fixture holds the pairing.
    func testFailedProviderNamesStayEmptyWhenTheShortListFlagIsNotSet() throws {
        let response = try decode(
            OwnedNumbersResponse.self,
            from: #"{"success":true,"numbers":[],"failedProviders":["telnyx"]}"#
        )

        XCTAssertNil(response.partial)
        XCTAssertEqual(response.failedProviders, ["telnyx"], "the key decodes")
        XCTAssertEqual(response.failedProviderNames, [], "⛔ and is not surfaced without the flag")
    }

    /// ⛔ THE OTHER HALF OF THE SAME PAIRING, AND THE ONE THAT WOULD BE A CRASH
    /// RATHER THAN A WRONG LABEL. A `partial: true` with NO `failedProviders` is
    /// drift the server should not produce, but a client that force-unwrapped the
    /// names off the flag would die on it — and the honest rendering is a warning
    /// with no carrier named, not a refusal to draw the list. Decoded from literal
    /// bytes; no fixture holds this pairing either.
    func testAShortListWithNoNamedCarrierWarnsWithoutNamingRatherThanFailing() throws {
        let response = try decode(
            OwnedNumbersResponse.self,
            from: #"{"success":true,"numbers":[],"partial":true}"#
        )

        XCTAssertEqual(response.partial, true)
        XCTAssertNil(response.failedProviders)
        XCTAssertEqual(response.failedProviderNames, [], "⛔ nothing to name, and nothing to unwrap")
    }
}
