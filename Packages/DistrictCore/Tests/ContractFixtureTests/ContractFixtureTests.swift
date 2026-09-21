import ContractGateSupport
import Foundation
import XCTest

/// The iOS half of the two-sided contract gate — the third consumer of the
/// fixtures the server generates and the Kotlin client already checks.
///
/// ⛔ EVERY FIXTURE IN THE CORPUS IS WIRED IN FROM DAY ONE, not as DTOs land.
/// A suite that only knew about the endpoints already ported could not tell a
/// new endpoint from an endpoint nobody got to, and the burn-down would be
/// invisible. Instead every file on disk must appear in exactly one of two
/// lists — `ImplementedFixtures` or `ContractManifest.unimplemented` — and the
/// suite prints a counted summary of both on every run.
final class ContractFixtureTests: XCTestCase {
    // MARK: - The guard that stops this suite verifying nothing

    /// ⛔ THE ONE TEST THAT MUST NEVER BE WEAKENED. Everything else here is
    /// conditional on there being fixtures to check; if the directory is missing
    /// or empty, every other assertion in this file becomes trivially true and a
    /// green CI run would mean the opposite of what it appears to.
    ///
    /// The failure is realistic rather than theoretical: the fixtures live
    /// outside this package, so a moved directory, an ignore rule that swallows
    /// `*.json` or a partial checkout each leave the gate with nothing to read.
    func testContractsDirectoryIsPopulated() throws {
        let names = try ContractFixtures.allFixtureNames()
        XCTAssertFalse(names.isEmpty, "unreachable — allFixtureNames() throws rather than returning []")
        print("contract fixtures: \(names.count) found in \(ContractFixtures.directory.path)")
    }

    /// ⛔ AN EXACT COUNT, NOT A FLOOR. A floor passes against a path that
    /// resolved to some other directory, and never notices a fixture the server
    /// team added and nobody wired in. This is the assertion that makes a new
    /// endpoint's arrival visible to the iOS client at all.
    func testFixtureCountMatchesTheManifest() throws {
        let names = try ContractFixtures.allFixtureNames()
        XCTAssertEqual(
            names.count,
            ContractManifest.expectedFixtureCount,
            """
            fixture count changed: \(names.count) on disk, \
            \(ContractManifest.expectedFixtureCount) in ContractManifest.
              If fixtures were ADDED, bump ContractManifest.expectedFixtureCount and add
              each new name to ContractManifest.unimplemented in the same commit.
              If this is a partial or stale checkout, fix the checkout — do not move
              the number to match it.
              on disk: \(names.joined(separator: ", "))
            """
        )
    }

    // MARK: - Every fixture is accounted for, in exactly one list

    /// Nothing on disk may be silently unverified, and nothing may be verified
    /// twice under two different claims.
    func testEveryFixtureIsEitherImplementedOrExplicitlySkipped() throws {
        let onDisk = try Set(ContractFixtures.allFixtureNames())
        let implemented = ImplementedFixtures.names
        let skipped = ContractManifest.unimplemented

        let unaccounted = onDisk.subtracting(implemented).subtracting(skipped).sorted()
        XCTAssertTrue(
            unaccounted.isEmpty,
            """
            \(unaccounted.count) fixture(s) are in neither list and are therefore
            verified by nothing: \(unaccounted.joined(separator: ", "))
              Add a DTO and an ImplementedFixtures entry, or add the name to
              ContractManifest.unimplemented so the debt is at least counted.
            """
        )

        let overlap = implemented.intersection(skipped).sorted()
        XCTAssertTrue(
            overlap.isEmpty,
            """
            \(overlap.count) fixture(s) are BOTH implemented and skip-listed:
            \(overlap.joined(separator: ", "))
              The skip-list entry is stale. Remove it, or the summary this suite
              prints is overstating the remaining work.
            """
        )
    }

    /// ⛔ A SKIP-LIST ENTRY FOR A FIXTURE THAT DOES NOT EXIST IS A FAILURE, NOT A
    /// HARMLESS LEFTOVER. It means the corpus moved under us — a rename, a
    /// deletion, or this list drifting behind the generator — and a list that is
    /// allowed to name ghosts stops being evidence of anything.
    func testSkipListHasNoStaleEntries() throws {
        let onDisk = try Set(ContractFixtures.allFixtureNames())
        let ghosts = ContractManifest.unimplemented.subtracting(onDisk).sorted()
        XCTAssertTrue(
            ghosts.isEmpty,
            """
            \(ghosts.count) skip-listed fixture(s) do not exist on disk:
            \(ghosts.joined(separator: ", "))
              They were renamed or deleted. Update ContractManifest.unimplemented
              and ContractManifest.expectedFixtureCount together.
            """
        )
    }

    /// The mirror of the above: a fixture claimed as implemented must exist.
    func testImplementedFixturesAllExist() throws {
        let onDisk = try Set(ContractFixtures.allFixtureNames())
        let ghosts = ImplementedFixtures.names.subtracting(onDisk).sorted()
        XCTAssertTrue(
            ghosts.isEmpty,
            "implemented fixtures missing from disk: \(ghosts.joined(separator: ", "))"
        )
        XCTAssertEqual(
            ImplementedFixtures.names.count,
            ImplementedFixtures.all.count,
            "ImplementedFixtures lists the same fixture twice"
        )
    }

    // MARK: - The gate itself

    /// Runs every implemented fixture through `StrictDecodeVerifier` and prints
    /// the counted summary.
    ///
    /// ⚠️ COLLECTS ALL FAILURES RATHER THAN STOPPING AT THE FIRST. One fixture
    /// regenerating with a renamed field usually breaks several DTOs at once,
    /// and a run that reports one of them costs a full CI cycle per fixture to
    /// work through.
    func testEveryImplementedFixturePassesTheStrictGate() throws {
        var failures: [String] = []
        for fixture in ImplementedFixtures.all.sorted(by: { $0.name < $1.name }) {
            do {
                try fixture.run()
            } catch {
                failures.append(String(describing: error))
            }
        }

        let implemented = ImplementedFixtures.all.count
        let skipped = ContractManifest.unimplemented.count
        let total = try ContractFixtures.allFixtureNames().count
        print("""
        ── contract gate summary ──────────────────────────────────────────────
          implemented : \(implemented)
          skipped     : \(skipped)
          total       : \(total)  (manifest expects \(ContractManifest.expectedFixtureCount))
          fixtures    : \(ContractFixtures.directory.path)
        ───────────────────────────────────────────────────────────────────────
        """)

        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) fixture(s) failed the strict gate:\n\n"
                + failures.joined(separator: "\n\n")
        )
    }

    /// ⛔ THE ALLOWLIST IS COUNTED, AND CHANGING IT IS A CONSCIOUS EDIT TO A TEST
    /// RATHER THAN A QUIET LINE IN A CONSTANT. It is the single sanctioned
    /// escape from the no-nulls invariant the whole gate rests on, and the
    /// cheapest wrong move under time pressure is a blanket entry rather than a
    /// modelled field. The numbers below are exact because an assertion that has
    /// stopped being true is worse than none.
    func testExplicitNullAllowlistIsExactlyWhatWasDecided() {
        let table = StrictDecodeVerifier.allowedExplicitNulls
        XCTAssertEqual(
            Set(table.keys),
            ContractManifest.fixturesWithAllowedNulls,
            """
            allowedExplicitNulls names a different set of fixtures than the manifest
            records. Adding an entry is allowed and is a DECISION: update
            ContractManifest.fixturesWithAllowedNulls in the same commit, and say in
            the entry's comment which nullable column it describes and why the server
            sends the key rather than omitting it.
            """
        )
        XCTAssertEqual(
            table.values.reduce(0) { $0 + $1.count },
            ContractManifest.expectedAllowedNullPaths,
            "the number of allowlisted paths changed"
        )
    }

    /// ⛔ AN ENTRY MUST BE AN EXACT PATH, AND THERE IS NO PATTERN LANGUAGE TO
    /// WRITE A WIDER ONE WITH. The verifier matches by set membership, so a
    /// `*` or a `[]` in an entry does not widen it — it simply never matches,
    /// which would leave a fixture failing for a reason nobody would look for.
    /// This is the check that says so out loud.
    func testEveryAllowlistedPathIsAnExactPath() {
        for (fixture, paths) in StrictDecodeVerifier.allowedExplicitNulls {
            for path in paths {
                XCTAssertTrue(path.hasPrefix(JSONPathPrefix.root), "\(fixture): \(path) is not rooted at $")
                XCTAssertFalse(path.contains("*"), "\(fixture): \(path) looks like a wildcard, which never matches")
                XCTAssertFalse(path.contains("[]"), "\(fixture): \(path) has an empty index")
            }
        }
    }

    /// ⛔ AN ALLOWLIST ENTRY FOR A SKIP-LISTED FIXTURE IS DEAD CODE THAT READS AS
    /// A DECISION. Nothing decodes that fixture, so the entry exempts nothing
    /// and the next reader has to work out whether it was ever exercised.
    func testEveryAllowlistedFixtureIsActuallyGated() {
        let unreachable = Set(StrictDecodeVerifier.allowedExplicitNulls.keys)
            .subtracting(ImplementedFixtures.names)
            .sorted()
        XCTAssertTrue(
            unreachable.isEmpty,
            """
            \(unreachable.count) fixture(s) have an explicit-null allowlist entry but are
            not gated by any DTO: \(unreachable.joined(separator: ", "))
              Either wire the fixture into ImplementedFixtures, or delete the entry.
            """
        )
    }
}

/// The one literal `JSONPath.root` uses, restated here because that type lives
/// in `ContractGateSupport` as an internal detail of the walk.
private enum JSONPathPrefix {
    static let root = "$"
}
