import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Proof that `allowedExplicitNulls` exempts exactly what it claims to, in both
/// directions.
///
/// ⛔ THE ALLOWLIST IS THE ONE HOLE IN THE INVARIANT THE WHOLE GATE RESTS ON, SO
/// ITS MECHANICS ARE TESTED RATHER THAN ASSUMED. Two failure modes would each
/// look like "the allowlist works" from a green pipeline: an entry that exempted
/// the null assertion but not the re-encode key loss (every allowlisted fixture
/// fails, which at least is loud), and an entry that exempted the whole OBJECT
/// it sits in (nothing fails, ever again, at that path — which is silent and is
/// the one worth paying for a test). Both are pinned below, along with the
/// property every shipped entry depends on: a listed path holding a real value
/// is fine, because these are nullable columns and not required nulls.
///
/// ⚠️ IN-MEMORY PAYLOADS, NOT COMMITTED FIXTURES — a broken fixture on disk would
/// be picked up by the corpus enumeration and counted as part of the burn-down.
final class AllowlistMechanicsTests: XCTestCase {
    // MARK: - The exemption itself

    /// ⛔ THE HALF THAT IS EASY TO GET WRONG. Swift encodes a nil Optional as an
    /// ABSENT key, so an allowlisted null passes step 1 and then reaches step 4
    /// as a key the fixture had and the re-encode does not. Exempting only the
    /// null assertion would trade one failure for another and teach the next
    /// reader that the allowlist does not work.
    func testAnAllowlistedNullIsExemptFromBothTheAssertionAndTheKeyLoss() throws {
        let value = try StrictDecodeVerifier.verify(
            name: "row.json",
            json: Data(nullableRow.utf8),
            as: NullableRow.self,
            allowingExplicitNulls: ["$.rows[0].note"]
        )
        XCTAssertNil(value.rows[0].note, "the null decoded to nil")
        XCTAssertEqual(value.rows[0].id, "a")
    }

    /// And without the entry the same payload is refused, so the test above is
    /// measuring the allowlist rather than a gate that never minded.
    func testTheSamePayloadIsRefusedWithoutTheEntry() {
        let failure = gateFailure("row.json", nullableRow, as: NullableRow.self)
        guard case let .explicitNull(_, path)? = failure else {
            return XCTFail("expected explicitNull, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.rows[0].note")
    }

    // MARK: - What the exemption must NOT reach

    /// ⛔ THE SILENT FAILURE MODE. If the exemption were computed per OBJECT
    /// rather than per key, an entry for `note` would also hide a genuinely
    /// unmodelled sibling — and unmodelled keys are the entire reason this gate
    /// exists, since `JSONDecoder` cannot reject one.
    func testAnEntryDoesNotExcuseAnUnmodelledSiblingKey() {
        let json = """
        {"rows":[{"id":"a","note":null,"serverAddedThis":"surprise"}]}
        """
        let failure = gateFailure(
            "sibling.json",
            json,
            as: NullableRow.self,
            allowingExplicitNulls: ["$.rows[0].note"]
        )
        guard case let .droppedKeys(_, _, path, keys)? = failure else {
            return XCTFail("expected droppedKeys, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.rows[0]")
        XCTAssertEqual(keys, ["serverAddedThis"], "the allowlisted key must not appear here either")
    }

    /// ⛔ AND IT MUST NOT EXCUSE A DROPPED **VALUE**. The exemption is
    /// conditioned on the fixture's value actually being null, so an allowlist
    /// entry cannot be used — or left lying around after a regeneration — to
    /// hide a field the DTO stopped modelling. Here the listed path carries a
    /// real string and the DTO has no property for it.
    func testAnEntryDoesNotExcuseADroppedKeyWhoseValueIsNotNull() {
        let json = """
        {"rows":[{"id":"a","note":"a real value"}]}
        """
        let failure = gateFailure(
            "populated.json",
            json,
            as: IdOnlyRow.self,
            allowingExplicitNulls: ["$.rows[0].note"]
        )
        guard case let .droppedKeys(_, _, path, keys)? = failure else {
            return XCTFail("expected droppedKeys, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.rows[0]")
        XCTAssertEqual(keys, ["note"])
    }

    /// ⛔ A SIBLING PATH IS NOT COVERED, which is what keeps an entry to one
    /// value in one file rather than to a field across every row.
    func testAnEntryDoesNotCoverTheSameFieldOnAnotherRow() {
        let json = """
        {"rows":[{"id":"a","note":null},{"id":"b","note":null}]}
        """
        let failure = gateFailure(
            "rows.json",
            json,
            as: NullableRow.self,
            allowingExplicitNulls: ["$.rows[0].note"]
        )
        guard case let .explicitNull(_, path)? = failure else {
            return XCTFail("expected explicitNull, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.rows[1].note")
    }

    // MARK: - Permission, not requirement

    /// ⚠️ THE PROPERTY EVERY SHIPPED ENTRY RELIES ON. Every one of them names a
    /// NULLABLE COLUMN, so whether a regenerated row happens to carry a value is
    /// not a contract change — and a gate that demanded the null would fail on
    /// the good news. A listed path holding a real value passes, and the value
    /// still round-trips.
    func testAnAllowlistedPathMayHoldARealValue() throws {
        let json = """
        {"rows":[{"id":"a","note":"now populated"}]}
        """
        let value = try StrictDecodeVerifier.verify(
            name: "populated.json",
            json: Data(json.utf8),
            as: NullableRow.self,
            allowingExplicitNulls: ["$.rows[0].note"]
        )
        XCTAssertEqual(value.rows[0].note, "now populated")
    }

    /// ⚠️ AND A DTO THAT RE-ENCODES THE NULL AS A NULL IS EQUALLY FINE. The
    /// exemption excuses a LOST key; it does not require one. This is the shape
    /// `district-workspace-config.json` takes, where the null sits inside an
    /// opaque ``WireJSON`` blob that carries it through untouched — so the entry
    /// there buys the assertion exemption and nothing else.
    func testAnAllowlistedNullMayAlsoBeReEncodedAsANull() throws {
        let json = """
        {"config":{"action":"knowledge","target":null}}
        """
        let value = try StrictDecodeVerifier.verify(
            name: "opaque.json",
            json: Data(json.utf8),
            as: OpaqueConfig.self,
            allowingExplicitNulls: ["$.config.target"]
        )
        XCTAssertEqual(value.config["target"], .null, "the carrier keeps the null rather than dropping it")
        XCTAssertEqual(value.config["action"]?.stringValue, "knowledge")
    }

    // MARK: - The shipped table is actually consulted

    /// ⛔ THE WIRING, WHICH NOTHING ELSE PROVES DIRECTLY. Every other test here
    /// passes the set explicitly; the fixture entry point instead looks it up BY
    /// FIXTURE NAME. A table that was populated but never read would leave all
    /// allowlisted fixture failing, but a table read under the wrong key would
    /// leave them failing too — and both would be reported as a DTO problem.
    func testTheFixtureNameIsWhatSelectsTheEntry() throws {
        let json = #"{"success":true,"draft":null}"#
        let decoded = try StrictDecodeVerifier.verify(
            name: "district-draft-null.json",
            json: Data(json.utf8),
            as: DraftResponse.self
        )
        XCTAssertNil(decoded.draft)

        // The same bytes under any other name are refused: the entry belongs to
        // that fixture, not to that shape.
        let failure = gateFailure("some-other-fixture.json", json, as: DraftResponse.self)
        guard case let .explicitNull(fixture, path)? = failure else {
            return XCTFail("expected explicitNull, got \(String(describing: failure))")
        }
        XCTAssertEqual(fixture, "some-other-fixture.json")
        XCTAssertEqual(path, "$.draft")
    }

    // MARK: - Helpers

    private let nullableRow = """
    {"rows":[{"id":"a","note":null}]}
    """

    private func gateFailure(
        _ name: String,
        _ json: String,
        as type: (some Codable).Type,
        allowingExplicitNulls allowed: Set<String>? = nil
    ) -> ContractGateFailure? {
        do {
            _ = try StrictDecodeVerifier.verify(
                name: name,
                json: Data(json.utf8),
                as: type,
                allowingExplicitNulls: allowed
            )
            return nil
        } catch let failure as ContractGateFailure {
            return failure
        } catch {
            XCTFail("expected a ContractGateFailure, got \(error)")
            return nil
        }
    }
}

// MARK: - Payload shapes for the tests above

private struct NullableRow: Codable {
    struct Row: Codable {
        let id: String
        let note: String?
    }

    let rows: [Row]
}

/// The same payload with `note` unmodelled — a DTO that drops the field.
private struct IdOnlyRow: Codable {
    struct Row: Codable {
        let id: String
    }

    let rows: [Row]
}

/// A blob carried rather than interpreted, which is how the workspace config's
/// routing rules reach the gate.
private struct OpaqueConfig: Codable {
    let config: WireJSON
}
