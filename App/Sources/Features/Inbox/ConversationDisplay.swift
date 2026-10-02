import DistrictModel
import Foundation

/// The display rules for one Inbox row, derived ONCE. Sibling of ``CallDisplay``,
/// and it exists for the same reason: the other client re-derived these comparisons
/// inline in every screen that showed a message, with the wire constants copied
/// alongside them, and the copies drifted.
///
/// ⚠️ NO `import SwiftUI`, DELIBERATELY, exactly as ``CallDisplay`` does it.
/// Everything here is a pure function of the wire row, so it stays readable and
/// reviewable on a machine that cannot compile SwiftUI. ``Tone`` is named only as a
/// value: it is declared in this same module, so it needs no import and nothing here
/// touches `Color`.
///
/// ⛔ NO TIMESTAMP, DELIBERATELY. `lastMessage.createdAt` is NOT preformatted like
/// ``CallSummary/time``: `district-conversations.json` carries
/// `"2026-08-15T14:20:00.000Z"`, a raw ISO-8601 instant, and
/// ``ConversationLastMessage/createdAt`` says the module owns no date parsing.
/// Printing the raw string puts machine text in front of an operator; parsing it
/// here meets the two Foundation entry points' silent-nil trap around fractional
/// seconds, which cannot be exercised on Linux; and a list ordered by recency gains
/// little from the instant (see the ⛔ on ``MessageSearchDisplay``). So the row
/// carries no time, which is also exactly what the Android Inbox row does. A time,
/// if wanted, belongs on the server (a preformatted label beside the instant, the
/// way the calls route does) or behind the shared ``WireDate`` helper.
struct ConversationDisplay {
    /// The contact's name when the thread resolved to one, the raw counterpart when
    /// it did not. ``ConversationSummary/displayName`` owns that rule.
    let title: String

    /// ⚠️ EMPTY RATHER THAN THE COUNTERPART WHEN THERE IS NO CONTACT, which is the
    /// Android row's choice and `ActivityRow`'s. ``DistrictAvatar`` renders a single
    /// neutral glyph for an empty name; feeding it a counterpart instead produces a
    /// circle containing "+" for a phone thread, which reads as a rendering fault.
    let avatarName: String

    /// ⚠️ Neutral for an unresolved address, so a thread with no Contact row does not
    /// wear the brand accent as if it were a known customer.
    let avatarTone: Tone

    /// The direction glyph and the last message's body, on one line.
    let subtitle: String

    /// Uppercased channel names, and EMPTY for a single-channel thread. See
    /// ``channelLabels(_:)``.
    let channelLabels: [String]

    /// ⛔ nil FOR AN INBOUND LAST MESSAGE, and that is the port of `MessageTone.kt`'s
    /// own scope rather than a simplification: it documents itself as "which tone an
    /// OUTBOUND message's delivery status wears". An inbound message's `status` is
    /// the provider's record of a message arriving, which the operator can neither
    /// act on nor be responsible for, so badging it would be noise on every row.
    let statusLabel: String?

    /// The tone for ``statusLabel``. Meaningless when that is nil.
    let statusTone: Tone
}

extension ConversationDisplay {
    /// Map a wire row to its display rules. The only place these comparisons appear.
    init(_ conversation: ConversationSummary) {
        let contactName = Self.usable(conversation.contactName)
        let last = conversation.lastMessage
        let outbound = last.direction == MessageWire.directionOutbound
        self.init(
            title: conversation.displayName,
            avatarName: contactName ?? "",
            avatarTone: contactName == nil ? .neutral : .district,
            subtitle: Self.subtitle(body: last.body, outbound: outbound),
            channelLabels: Self.channelLabels(conversation.channels),
            statusLabel: outbound ? last.status : nil,
            statusTone: MessageStatusTone.tone(for: last.status)
        )
    }

    /// nil for absent, empty or whitespace-only. ⚠️ The name column is nullable AND
    /// can hold an empty string, so a nil check alone lets a blank title through.
    private static func usable(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// ⚠️ CHANNELS ONLY WHEN THE THREAD ACTUALLY MIXES THEM, ported verbatim from the
    /// Android row. A single-channel thread does not need to be told it is SMS, and a
    /// badge on every row is noise that hides the one badge that matters.
    private static func channelLabels(_ channels: [String]) -> [String] {
        guard channels.count > 1 else { return [] }
        return channels.map { $0.uppercased() }
    }

    /// ⚠️ A ONE-CHARACTER GLYPH, NOT A WORD. The Android row's note argues against a
    /// direction PREFIX because it eats the preview, and a spelled-out "Outbound: "
    /// is exactly that. An arrow costs two columns and answers the question an
    /// operator scans an Inbox for: did we already reply to this one.
    private static func subtitle(body: String, outbound: Bool) -> String {
        "\(outbound ? "↑" : "↓") \(MessagePreview.line(body))"
    }
}

/// One line of a message body, for a row that has to fit it.
///
/// ⛔ A FILE-SCOPE TYPE RATHER THAN A MEMBER OF ``ConversationDisplay``, BECAUSE
/// THAT IS WHAT MAKES IT REACHABLE AT ALL. Swift's `private` on a member is
/// file-private TO THAT DECLARATION AND ITS EXTENSIONS — a sibling type in the
/// same file cannot see it. ``MessageSearchDisplay`` needs exactly this function
/// and re-deriving it would mean re-deriving the Unicode argument below, so it
/// lives here rather than being copied. Same call as ``MessageStatusTone``, which
/// is top-level for the same reason: one mapping, two callers.
///
/// ⚠️ STILL `private` AT FILE SCOPE, so nothing outside this file can reach it.
/// Top-level `private` and `fileprivate` mean the same thing; `private` is written
/// because `fileprivate` on a member is what SwiftFormat's `redundantFileprivate`
/// rewrites, and this is a file boundary rather than a member one.
private enum MessagePreview {
    /// ⛔ FLATTENED AND TRUNCATED HERE, BECAUSE NEITHER CLIENT'S LIST ROW LIMITS ITS
    /// LINES. ``DistrictListRow`` renders the subtitle as a plain `Text` with no
    /// `lineLimit`, and so does the Kotlin one, so a message carrying newlines draws a
    /// row as tall as the message. The row cannot fix it (a `lineLimit` there would be
    /// a design-system change outside this feature), so the string handed to it is
    /// already one line.
    ///
    /// ⛔ EVERY STEP COUNTS IN `Character`s, WHICH ARE GRAPHEME CLUSTERS, AND THE ONE
    /// PLAUSIBLE "OPTIMISATION" HERE CORRUPTS EMOJI. Measured on Linux rather than
    /// reasoned about: truncating the same body at the same index over `utf16` instead
    /// of `Character`s turns a trailing 😊 into **U+FFFD**, and a 🇨🇦, 👍🏽, 👋🏿 or
    /// 👨‍👩‍👧 into U+FFFD as well, while a ☺️ loses its U+FE0F and a 1️⃣ loses its
    /// keycap. `String.count` and `String.prefix(_:)` are already Character-based,
    /// but relying on that is correctness by inheritance from a stdlib default rather
    /// than by saying so: the array below IS the grapheme boundary, and anything
    /// reaching for `utf16`, `unicodeScalars` or a byte count reintroduces exactly the
    /// failure this comment describes.
    ///
    /// ⛔ AND THE TRAILING TRIM IS A `Character` DROP RATHER THAN
    /// `trimmingCharacters(in: .whitespaces)`, WHICH IS SCALAR-BASED. `CharacterSet`
    /// trimming walks unicode scalars, so it would be the one scalar-level operation in
    /// a function whose whole correctness argument is that it never leaves the grapheme
    /// level. Nothing in `.whitespaces` can appear at the end of an emoji cluster, so
    /// it would not be a live bug; it would be a scalar-level tool sitting where the
    /// next reader would reasonably copy it to somewhere it does matter.
    ///
    /// ⚠️ THE ELLIPSIS IS APPENDED ONLY WHEN SOMETHING WAS ACTUALLY CUT. A body of
    /// exactly ``previewLimit`` characters is returned whole, so the reader is never
    /// told that a complete message continues.
    ///
    /// ⚠️ THE FLATTEN SILENTLY DROPS A TRAILING LONE COMBINING SCALAR, and that is
    /// worth knowing because it makes this function's behaviour on ALREADY-DAMAGED
    /// input uneven rather than wrong. A stray U+FE0F, U+200D or skin-tone modifier
    /// arriving after a space forms ONE grapheme cluster WITH that space, the cluster
    /// reports `isWhitespace`, and the split discards both. A stray U+FFFD or a lone
    /// regional indicator has no such preceding base, so it survives into the row.
    /// Neither case is created here: both are the residue of something upstream having
    /// cut a message body on a byte or UTF-16 boundary, and the row is where it first
    /// becomes visible.
    static func line(_ body: String) -> String {
        let flattened = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !flattened.isEmpty else { return missingBody }
        let characters = Array(flattened)
        guard characters.count > previewLimit else { return flattened }
        var kept = Array(characters.prefix(previewLimit))
        while let last = kept.last, last.isWhitespace {
            kept.removeLast()
        }
        return String(kept) + "…"
    }

    /// ⚠️ Copy, not a wire value. A thread whose latest message is an MMS with no text
    /// genuinely has no body, and a blank subtitle reads as a rendering failure.
    private static let missingBody = "No message body"

    /// Roughly two lines at the subtitle's 14pt on the narrowest supported device.
    private static let previewLimit = 140
}

/// The display rules for one SEARCH RESULT, derived once. Sibling of
/// ``ConversationDisplay``, and it lives in this file so the two share
/// ``MessagePreview`` and ``MessageWire`` rather than owning copies.
///
/// ⛔ A HIT IS ONE MESSAGE, NOT A THREAD, AND THAT IS WHY THIS IS A SEPARATE TYPE
/// RATHER THAN A ``ConversationDisplay`` INITIALISER. A conversation row's job is
/// "who is this and what is the latest"; a search row's is "which message matched
/// and when was it said". Coercing a hit into a ``ConversationSummary`` shape
/// would need `canSms`, `canEmail`, `channels` and `unreadCount`, none of which
/// the search route sends, so the coercion could only be done by inventing them.
///
/// ⛔ IT CARRIES A TIMESTAMP AND ``ConversationDisplay`` DELIBERATELY DOES NOT.
/// That is not an inconsistency to tidy away in either direction. A conversation
/// list is ordered by recency and reads top-to-bottom as "newest first", so the
/// instant adds nothing a position does not already say; search results span the
/// workspace's whole history, so WHEN a match was said is half of what makes it
/// identifiable. The objection recorded on ``ConversationDisplay`` was that the
/// two Foundation entry points have a silent-nil trap around fractional seconds
/// that Linux cannot exercise — ``WireDate`` answers exactly that, with both
/// parses and a raw-string fallback, and is reused here rather than copied.
struct MessageSearchDisplay {
    /// The contact's name when the hit resolved to one, the raw counterpart when
    /// it did not. ``MessageSearchHit/displayName`` owns that rule.
    let title: String

    /// The email subject, when there is a usable one.
    ///
    /// ⛔ SHOWN, BECAUSE THE ROUTE MATCHES ON IT. The search route queries `body`
    /// OR `subject`, so a hit can match on the subject alone — and a row showing
    /// only the body would then look like a result the search had no reason to
    /// return. nil on SMS and on an email with a blank subject.
    let subject: String?

    /// The direction glyph and the matched body, flattened to fit a row.
    let body: String

    /// A rendered instant. See the ⛔ on the type.
    let timestamp: String
}

extension MessageSearchDisplay {
    init(_ hit: MessageSearchHit) {
        let outbound = hit.direction == MessageWire.directionOutbound
        self.init(
            title: hit.displayName,
            subject: Self.usable(hit.subject),
            // ⚠️ THE SAME GLYPH CONVENTION AS THE INBOX ROW, deliberately: an
            // operator scanning results is asking the same question there as here,
            // and a second vocabulary for it would have to be learned twice.
            body: "\(outbound ? "↑" : "↓") \(MessagePreview.line(hit.body))",
            timestamp: WireDate.display(hit.createdAt)
        )
    }

    /// nil for absent, empty or whitespace-only, and it returns the TRIMMED value
    /// rather than the raw one.
    ///
    /// ⚠️ A NEAR-TWIN OF ``ConversationDisplay``'s own `usable`, and kept separate
    /// on purpose: that one answers the ORIGINAL string because a contact's name is
    /// shown as stored, while a subject is a header field whose leading space is an
    /// artefact of transport rather than something the sender wrote.
    private static func usable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which ``Tone`` an OUTBOUND message's delivery status wears. Port of Android's
/// `MessageTone.kt`.
///
/// ⛔ THIS IS THE ANSWER THE OPERATOR IS LOOKING FOR AFTER A SEND, so it must not be
/// decorative. A message that failed and a message that was delivered rendering in
/// the same grey is the whole reason the call log's statuses got toned; the same
/// argument applies here and the stakes are higher, because a send costs money and a
/// silent failure means the customer never got the reply.
///
/// ⚠️ FAILS TO ``Tone/neutral`` FOR ANYTHING UNMODELLED. The status column carries
/// whatever the provider reported, and Twilio, Sinch and Postmark do not agree on a
/// vocabulary, so painting an unknown value green would assert a delivery this client
/// cannot confirm.
///
/// ⚠️ LOWERCASED AND TRIMMED BEFORE MATCHING, for the same reason
/// ``Tone/forCallStatus(_:)`` does it: nothing normalises these columns on write.
///
/// ⚠️ A TOP-LEVEL TYPE RATHER THAN A MEMBER OF ``ConversationDisplay`` so the thread
/// screen can use the one mapping rather than porting `MessageTone.kt` a second
/// time. It is deliberately NOT named `MessageTone`: that is the name a straight
/// port would take, and two types of that name in one module is a compile error
/// rather than a merge conflict.
enum MessageStatusTone {
    static func tone(for status: String?) -> Tone {
        let normalised = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if delivered.contains(normalised ?? "") {
            return .success
        }
        if failed.contains(normalised ?? "") {
            return .danger
        }
        if inFlight.contains(normalised ?? "") {
            return .district
        }
        return .neutral
    }

    /// It reached the handset or the mailbox. The only genuinely good outcome.
    private static let delivered: Set<String> = ["delivered", "received", "read"]

    /// ⛔ Terminal failures. `undelivered` is the one that matters most: the provider
    /// ACCEPTED the message and then could not deliver it, so a client treating "sent"
    /// as success would already have told the operator it worked.
    private static let failed: Set<String> = [
        "failed",
        "undelivered",
        "bounced",
        "rejected",
        "spam",
    ]

    /// Accepted by the provider, outcome not yet known. ⚠️ Deliberately NOT success:
    /// "queued" and "sent" are the states a message sits in before it fails.
    private static let inFlight: Set<String> = [
        "queued",
        "accepted",
        "sending",
        "sent",
        "submitted",
    ]
}

/// The wire values these rules compare against.
///
/// ⚠️ DEFINED ONCE, HERE. They are wire values rather than display copy, so they are
/// not localizable and must never be duplicated: separate copies in the call log and
/// the call detail screen on the other client are exactly what let the
/// transfer-failed badge go missing from the log.
private enum MessageWire {
    static let directionOutbound = "outbound"
}
