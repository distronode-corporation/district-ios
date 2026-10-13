@testable import DistrictAI
import Foundation
import XCTest

/// The App Store Review Guideline 3.1.1 anti-steering gate for every sentence this app
/// says.
///
/// ⛔ 3.1.1 FORBIDS THE SIGNPOST, NOT ONLY THE BUTTON. Prose is not the safe half of the
/// rule: a sentence telling a customer that plan changes happen "on the web dashboard at
/// distronode.com" steers them to an outside purchase just as surely as a link would, and
/// it does it in the one form no reviewer needs to tap to find. Every user-visible string
/// states the LIMITATION and names no destination.
///
/// ⛔ A SCAN RATHER THAN EQUALITY ASSERTIONS, BECAUSE THE RISK IS THE NEXT STRING. Pinning
/// today's strings proves nothing about tomorrow's, and a screen written in a hurry
/// reaches for "you can do that on the website" by reflex. So this reads the SOURCE of every file under
/// `App/Sources/Features` and `App/Sources/Navigation`, pulls out the string literals, and
/// fails on any that names the web, a browser, a dashboard, a console or distronode.com.
///
/// ⛔ AND THE CATALOG, BECAUSE MOST OF THE SENTENCES LIVE THERE NOW. The `*Copy` enums are
/// generated from `l10n/ios.toml`, so a walk of the Swift alone would pass every string the
/// generator writes. Each entry's English AND French are scanned, scoped by its `screen`
/// field the way the walk is scoped by directory, and allowed by KEY, with the French
/// allowances listed apart from the English ones.
/// The three direct assertions at the bottom are a second, independent hold on the
/// sentences a reviewer is most likely to read first.
///
/// ⚠️ DOC COMMENTS ARE SKIPPED ON PURPOSE, AND THIS FILE IS THE PROOF THAT THEY MUST BE.
/// The reasoning above cannot be written without the words it forbids, and the same is
/// true of every ⛔ that records why a string says what it says. A line whose first
/// non-space characters are `//` is not shown to anyone, so it is not scanned.
///
/// ⛔ THREE EXCEPTIONS ARE DELIBERATE AND ARE NOT LOOPHOLES:
///   - `Features/Account/AccountView.swift` — the account-deletion row says "Opens in your
///     browser" and opens a distronode.com page. Guideline 5.1.1(v) REQUIRES
///     an account-deletion path, the web page is that path, and telling a person the tap
///     leaves the app is honesty about what the control does rather than steering toward a
///     purchase. Pinned to Android and to both store listings.
///   - `Features/Scheduling/**` and the catalog's `scheduling` screens: a hand-off into OUR OWN product. Nothing there
/// names a
///     place today; the exemption keeps this gate out of that feature's way rather than
///     blessing anything.
///   - `Features/Dialer/DialerCopy.swift`'s emergency line, which hands the caller to the
///     Phone app. Not listed below because "Phone app" is not one of the forbidden words;
///     it is named here so nobody removes it thinking this gate wants it gone.
///
/// ⚠️ THE REMAINING ALLOWANCES ARE FIELD LABELS AND ONE SIGN-IN DISCLOSURE, none of which
/// tell anyone where to go instead: a contact's own website, the A2P form's website field,
/// the customer's browser loading a logo we host, and the sign-in button saying what it is
/// about to open. Each is listed by its exact text, and ``testTheAllowlistHasNoStaleEntry``
/// fails if one stops occurring, so the list cannot quietly grow slack.
final class StoreCopyTests: XCTestCase {
    // MARK: - The contract

    /// ⚠️ MATCHED CASE-INSENSITIVELY AND AS SUBSTRINGS. "web dashboard" is redundant with
    /// "dashboard" and is kept so the failure message names the phrase a reader will
    /// recognise; `first(where:)` reports whichever matches first in this order.
    private static let forbiddenWords = [
        "web dashboard",
        "web console",
        "distronode.com",
        "on the web",
        "website",
        "dashboard",
        "browser",
        "distronode.ca",
    ]

    /// The same contract in French, matched the same way (lower-cased, as substrings).
    /// « site Web », « sur le Web », « navigateur » and « tableau de bord » are the
    /// glossary's store-steering words on Apple; « Aperçu » is Overview here.
    private static let forbiddenWordsFr = [
        "site web",
        "sur le web",
        "navigateur",
        "tableau de bord",
        "distronode.com",
        "distronode.ca",
    ]

    /// ⛔ THE SECOND CONTRACT: NOTHING INVITES A PERSON TO MAKE AN ACCOUNT. Guideline 3.1.1
    /// covers "account registration" for a service sold outside the app. Accounts here
    /// exist only by a workspace administrator's invitation, so an offer to sign up is both
    /// untrue and the thing the guideline names.
    ///
    /// ⚠️ PHRASES, NOT THE BARE WORD "register". The Numbers screens legitimately talk
    /// about REGULATORY registrations ("This registers a brand and a campaign on your
    /// carrier account"), and "join" is how a person enters a room. Each phrase below is
    /// one that only ever means "make an account".
    private static let registrationPhrases = [
        "sign up",
        "sign-up",
        "signup",
        "create an account",
        "create account",
        "create your account",
        "create a new account",
        "open an account",
        "register an account",
        "register for an account",
        "get started",
        "free trial",
        "start a trial",
        "start your trial",
    ]

    /// ⚠️ PHRASES, AS IN ENGLISH. « Inscription » alone also names the regulatory filings
    /// on the Numbers screens, so only wording that can only mean "make an account" is here.
    private static let registrationPhrasesFr = [
        "s'inscrire",
        "inscrivez-vous",
        "créer un compte",
        "créez un compte",
        "créez votre compte",
        "ouvrir un compte",
        "ouvrez un compte",
        "essai gratuit",
        "période d'essai",
        "commencer l'essai",
        "commencez votre essai",
    ]

    /// Directories the gate does not walk, relative to `App/Sources`.
    private static let exemptDirectories = [
        "Features/Scheduling",
    ]

    /// Exact literals permitted, keyed by path relative to `App/Sources`. Empty since every
    /// allowed sentence moved into the catalog (``allowedEntries``); kept so a literal that
    /// must stay in Swift has a place that the stale-entry test also polices.
    private static let allowedLiterals: [String: [String]] = [:]

    /// Catalog screens the gate does not scan: a `screen` equal to one of these or below it.
    private static let exemptScreens = [
        "scheduling",
    ]

    /// Catalog entries permitted, by key, with the exact English allowed.
    private static let allowedEntries: [String: String] = [
        "desk.logo_help": "Shown at the top of the thread page your customers open, in place of the name "
            + "above. PNG, JPEG or WebP, up to 512 KB. It is hosted publicly so their browser can load it, "
            + "and anyone with a thread link can see it.",
        "marketplace.a2p_website_label": "Website (optional)",
        "account.request_deletion_account_its": "Request deletion of your account and its data. Opens in your browser.",
        "contacts.website": "Website",
        "sign_in.opens_browser_sign_securely": "Opens your browser to sign in securely.",
    ]

    /// French permitted, by key, with the exact French allowed. ⛔ A FRENCH SENTENCE MAY
    /// NEVER ADD A DESTINATION ITS ENGLISH DOES NOT HAVE, so an English allowance does not
    /// carry over: each French one is reviewed and listed on its own.
    private static let allowedEntriesFr: [String: String] = [:]

    // MARK: - The gate

    func testNoUserVisibleStringNamesSomewhereElseToGo() throws {
        let result = try scan()

        // ⛔ A SCAN THAT FINDS NOTHING PASSES EVERY ASSERTION BELOW. If `#filePath` ever
        // stops resolving to a real checkout, or a sandbox refuses the read, this is the
        // line that says so instead of a green run that proved nothing.
        XCTAssertGreaterThan(result.filesScanned, 150, "the scan reached almost nothing, so it proved nothing")
        XCTAssertGreaterThan(
            result.entriesScanned,
            500,
            "the catalog scan reached almost nothing, so it proved nothing"
        )

        XCTAssertEqual(
            result.offences,
            [],
            "these strings tell a customer where to go instead, which is what Guideline 3.1.1 forbids"
        )
    }

    /// ⛔ NO ALLOWLIST FOR THIS ONE. There is no screen on which inviting a person to
    /// make an account is correct, so a hit is always a string to reword.
    func testNoUserVisibleStringInvitesAccountRegistration() throws {
        let result = try scan()

        XCTAssertGreaterThan(result.filesScanned, 150, "the scan reached almost nothing, so it proved nothing")
        XCTAssertGreaterThan(
            result.entriesScanned,
            500,
            "the catalog scan reached almost nothing, so it proved nothing"
        )
        XCTAssertEqual(
            result.registrationOffences,
            [],
            "these strings invite a person to make an account, which Guideline 3.1.1 forbids"
        )
    }

    /// ⛔ SHRINK-ONLY. An allowance whose string has been reworded or deleted is slack
    /// nobody chose, and the next string that happens to match it inherits a pass.
    func testTheAllowlistHasNoStaleEntry() throws {
        let result = try scan()
        let declared = Set(Self.allowedLiterals.flatMap { file, literals in
            literals.map { "\(file): \($0)" }
        })
        .union(Self.allowedEntries.map { "\($0.key): \($0.value)" })
        .union(Self.allowedEntriesFr.map { "\($0.key) (fr): \($0.value)" })

        XCTAssertEqual(
            declared.subtracting(result.allowancesUsed).sorted(),
            [],
            "these allowances no longer match any string; delete them in the commit that reworded them"
        )
    }

    /// ⛔ THE FRENCH HALF HAS TO BE SEEN TO FIRE. The catalog holds no French until the
    /// translation wave, so the real scan exercises only English; this runs the same scan
    /// over a two-entry catalog whose French steers and invites, and whose English does not.
    func testTheFrenchScanCatchesWhatTheEnglishDoesNotSay() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-copy-\(UUID().uuidString).toml")
        let catalog = [
            "[meta]",
            "catalog = \"probe\"",
            "",
            "[probe.steer]",
            "en = \"Plan changes are not available in this app.\"",
            "fr = \"Modifiez votre forfait dans le tableau de bord.\"",
            "screen = \"billing\"",
            "",
            "[probe.invite]",
            "en = \"Ask your administrator for an invitation.\"",
            "fr = \"Inscrivez-vous pour un essai gratuit.\"",
            "screen = \"sign_in\"",
            "",
        ].joined(separator: "\n")
        try catalog.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        var result = ScanResult(filesScanned: 0, offences: [], allowancesUsed: [], registrationOffences: [])
        try scanCatalog(into: &result, file: file)

        XCTAssertEqual(result.entriesScanned, 2)
        XCTAssertEqual(
            result.offences,
            ["probe.steer (fr) names \"tableau de bord\" in \"Modifiez votre forfait dans le tableau de bord.\""]
        )
        XCTAssertEqual(
            result.registrationOffences,
            ["probe.invite (fr) says \"inscrivez-vous\" in \"Inscrivez-vous pour un essai gratuit.\""]
        )
    }

    // MARK: - The sentences a reviewer reads first

    /// ⚠️ INDEPENDENT OF THE SCAN ON PURPOSE. These three carry the guideline's whole
    /// weight, and they still hold if the source walk above is ever unable to run.
    func testTheBillingCaptionStatesTheLimitAndNamesNowhere() {
        XCTAssertEqual(
            BillingCopy.readOnly,
            "Plan changes, payment methods and cancellations are not available in this app. "
                + "This screen is read-only."
        )
    }

    func testThePurchaseBoundaryStatesTheLimitAndNamesNowhere() {
        XCTAssertEqual(
            MarketplaceCopy.purchaseElsewhere,
            "New numbers cannot be purchased in this app. "
                + "Everything else about a number, including its paperwork and releasing it, is here."
        )
    }

    /// ⛔ THE PRICE STAYS. Dropping "$25 per month" to shorten the sentence would remove
    /// the disclosure that makes a one-way door one an operator can weigh; only the
    /// destination was the 3.1.1 problem.
    func testTheTrunkSentenceKeepsItsPriceAndLosesItsDestination() {
        XCTAssertTrue(MarketplaceCopy.sipOneWay.contains("$25 per month"))
        XCTAssertFalse(MarketplaceCopy.sipOneWay.lowercased().contains("dashboard"))
    }

    // MARK: - The walk

    private struct ScanResult {
        var filesScanned: Int
        var entriesScanned = 0
        var offences: [String]
        var allowancesUsed: Set<String>
        var registrationOffences: [String]
    }

    private func scan() throws -> ScanResult {
        // ⚠️ `"(?:[^"\\]|\\.)*"` — a literal, allowing escaped characters inside it. Built
        // with `try` rather than `try?` so a broken pattern fails loudly instead of
        // returning no matches, which would read exactly like a clean tree.
        let pattern = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        var result = ScanResult(filesScanned: 0, offences: [], allowancesUsed: [], registrationOffences: [])

        for file in Self.scannedFiles() {
            let relative = Self.relativePath(of: file)
            let allowed = Self.allowedLiterals[relative] ?? []
            result.filesScanned += 1

            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                for literal in Self.stringLiterals(in: line, pattern: pattern) {
                    let lowered = literal.lowercased()
                    if let phrase = Self.registrationPhrases.first(where: { lowered.contains($0) }) {
                        let offence = "\(relative):\(index + 1) says \"\(phrase)\" in \"\(literal)\""
                        result.registrationOffences.append(offence)
                    }
                    guard let word = Self.forbiddenWords.first(where: { lowered.contains($0) }) else { continue }
                    guard !allowed.contains(literal) else {
                        result.allowancesUsed.insert("\(relative): \(literal)")
                        continue
                    }
                    result.offences.append("\(relative):\(index + 1) names \"\(word)\" in \"\(literal)\"")
                }
            }
        }

        try scanCatalog(into: &result)
        result.offences.sort()
        result.registrationOffences.sort()
        return result
    }

    /// The catalog half of the walk: every entry's English, checked by the same two rules.
    private func scanCatalog(into result: inout ScanResult, file: URL = StoreCopyTests.catalogFile) throws {
        for entry in try CatalogScan.entries(of: file) {
            let exempt = Self.exemptScreens.contains { entry.screen == $0 || entry.screen.hasPrefix("\($0).") }
            guard !exempt else { continue }
            result.entriesScanned += 1
            for text in entry.english {
                check(text, key: entry.key, label: entry.key, french: false, into: &result)
            }
            for text in entry.french {
                check(text, key: entry.key, label: "\(entry.key) (fr)", french: true, into: &result)
            }
        }
    }

    /// One catalog string against one language's two rules.
    private func check(_ text: String, key: String, label: String, french: Bool, into result: inout ScanResult) {
        let lowered = text.lowercased()
        let phrases = french ? Self.registrationPhrasesFr : Self.registrationPhrases
        if let phrase = phrases.first(where: { lowered.contains($0) }) {
            result.registrationOffences.append("\(label) says \"\(phrase)\" in \"\(text)\"")
        }
        let words = french ? Self.forbiddenWordsFr : Self.forbiddenWords
        guard let word = words.first(where: { lowered.contains($0) }) else { return }
        let allowed = french ? Self.allowedEntriesFr[key] : Self.allowedEntries[key]
        guard allowed != text else {
            result.allowancesUsed.insert("\(label): \(text)")
            return
        }
        result.offences.append("\(label) names \"\(word)\" in \"\(text)\"")
    }

    /// `l10n/ios.toml`, two levels above `App/Sources`.
    private static var catalogFile: URL {
        sourcesRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("l10n/ios.toml")
    }

    /// ⚠️ `#filePath` RESOLVES ON THE MACHINE THAT COMPILED THIS, which is the checkout the
    /// test was built from, so the walk reads the same tree the build read.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func scannedFiles() -> [URL] {
        ["Features", "Navigation"].flatMap { scope -> [URL] in
            let root = sourcesRoot.appendingPathComponent(scope)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return []
            }
            return walker
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .filter { url in
                    let relative = relativePath(of: url)
                    return !exemptDirectories.contains { relative.hasPrefix("\($0)/") }
                }
        }
    }

    private static func relativePath(of file: URL) -> String {
        let prefix = sourcesRoot.path + "/"
        guard file.path.hasPrefix(prefix) else { return file.path }
        return String(file.path.dropFirst(prefix.count))
    }

    /// ⛔ A LINE WHOSE FIRST NON-SPACE CHARACTERS ARE `//` IS SKIPPED WHOLE, which covers
    /// `///` doc comments and the `//` file headers this codebase uses for them.
    private static func stringLiterals(in line: String, pattern: NSRegularExpression) -> [String] {
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return pattern.matches(in: line, range: range).compactMap { match in
            guard let matched = Range(match.range, in: line) else { return nil }
            return String(line[matched].dropFirst().dropLast())
        }
    }
}
