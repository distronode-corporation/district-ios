import Foundation

/// The booking page's address, derived from the name nobody was asked to type.
///
/// ⛔ THE OPERATOR NEVER ENTERS A SLUG, ON EITHER CLIENT, AND THAT IS A PRODUCT
/// DECISION WORTH NOT REDISCOVERING. It is the last segment of a public URL and
/// `eventTypes.patch` cannot change it (the schema's `slug` is the ADDRESS of the
/// row, so a different one patches a row that does not exist) — so a field for it
/// would be one typo away from a permanent one.
///
/// ⛔ PORTED ARM FOR ARM FROM THE WEB'S `slugFromName` / `uniqueSlug`,
/// INCLUDING THE ORDER OF THE LAST TWO STEPS. The trailing
/// hyphen is trimmed, then the string is cut to 200, then trimmed AGAIN — because
/// the cut can land in the middle of a run and put a hyphen back on the end, which
/// the fork refuses. Dropping the second trim looks like a tidy-up and is a 400 on
/// exactly the long names nobody tests with.
///
/// ⚠️ NFKD AND NOT NFD. `String.decomposedStringWithCanonicalMapping` is NFD;
/// JavaScript's `normalize("NFKD")` is the COMPATIBILITY decomposition, which also
/// folds ligatures and full-width forms. Using the canonical one here would give
/// the two clients different slugs for the same name, silently, for exactly the
/// inputs that are hardest to notice.
enum SchedulingEventTypeSlug {
    /// What an empty result becomes. The fork requires at least one character.
    static let fallback = "event-type"

    static func fromName(_ name: String) -> String {
        let folded = name.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x0300 ... 0x036F).contains($0.value) }
        let lowered = String(String.UnicodeScalarView(folded)).lowercased()

        var slug = ""
        var pendingHyphen = false
        for character in lowered {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingHyphen, !slug.isEmpty {
                    slug.append("-")
                }
                pendingHyphen = false
                slug.append(character)
            } else {
                pendingHyphen = true
            }
        }
        slug = String(slug.prefix(200))
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? fallback : slug
    }

    /// A slug no existing row is using.
    ///
    /// ⛔ THE LIST IS WHAT THIS CLIENT HAS READ, WHICH IS NOT THE SAME AS WHAT THE
    /// TENANCY HOLDS. Another member can create `phone-consultation` between the
    /// read and the save, and the fork's own uniqueness check is what settles it —
    /// this only stops the obvious collision with a row already on screen, and a
    /// caller must still be able to survive the refusal.
    ///
    /// ⚠️ THE `-2 … -999` WALK IS THE WEB'S, and so is the escape hatch after it: a
    /// millisecond timestamp, which is ugly and always available. `now` is a
    /// parameter so a test can reach the escape hatch without waiting for 998 rows.
    static func unique(from name: String, taken: [String], now: Date = Date()) -> String {
        let base = fromName(name)
        let used = Set(taken)
        guard used.contains(base) else { return base }
        for suffix in 2 ... 999 {
            let candidate = "\(base)-\(suffix)"
            if !used.contains(candidate) {
                return candidate
            }
        }
        return "\(base)-\(Int(now.timeIntervalSince1970 * 1000))"
    }
}
