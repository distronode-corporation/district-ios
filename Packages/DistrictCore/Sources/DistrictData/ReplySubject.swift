import Foundation

/// The subject line an email reply goes out with.
///
/// ⛔ IT EXISTS BECAUSE THE SERVER SUBSTITUTES A LITERAL WHEN THE CLIENT SENDS
/// NOTHING. `messages/send` is
/// `const emailSubject = (typeof subject === "string" && subject.trim()) || "Message from District"`,
/// and this client never sent one — so every email an operator had ever replied
/// with was titled "Message from District". Two costs, and the second is the
/// worse one: the customer's mail client threads on the subject, so the reply
/// arrived detached from the message it answered, and every reply the workspace
/// ever sent collapsed into a single conversation in the customer's inbox.
///
/// ⛔ AND IT NEVER INVENTS ONE. A thread with no email in it has no subject to
/// answer, and a manufactured line ("Your enquiry", the workspace's name, the
/// date) would be this client asserting a topic nobody chose — a smaller version
/// of exactly the bug above. When nothing can be derived this returns nil and the
/// operator writes the subject themselves; the composer refuses to send an email
/// without one rather than letting the server's literal through.
///
/// ⚠️ A FILE OF ITS OWN IN `DistrictData` RATHER THAN IN THE APP TARGET. It is a
/// pure function over ``ThreadEvent``, so on this side of the seam it is covered
/// by tests that run on Linux; in `App/` nothing could test it at all.
public enum ReplySubject {
    /// What a reply prefixes an answered subject with.
    ///
    /// ⚠️ ASCII `Re:` AND A SPACE, WHICH IS THE FORM EVERY MAIL CLIENT PARSES.
    /// It is deliberately not localised: the wire carries no locale for the
    /// customer, and a localised prefix would break the recipient's own threading
    /// rather than merely reading oddly.
    public static let prefix = "Re: "

    /// The subject to answer this thread's newest email with, or nil when the
    /// thread has never carried one.
    ///
    /// ⛔ NEWEST FIRST, WHICH IS WHY THE EVENTS ARE WALKED BACKWARDS.
    /// ``ThreadPage/events`` is oldest-first (both server versions sort ascending
    /// and the app must not re-sort), so the LAST subject-bearing row is the
    /// conversation the operator is looking at. Taking the first would answer a
    /// thread's opening email months after it was superseded.
    ///
    /// ⚠️ AN ALREADY-PREFIXED SUBJECT IS RETURNED UNCHANGED, so a long exchange
    /// does not accumulate `Re: Re: Re:`. The test is case-insensitive because the
    /// prefix arrives from whatever wrote it — a customer's mail client, not this
    /// app.
    ///
    /// ⚠️ A BLANK SUBJECT IS NOT A SUBJECT. The column is nullable AND can hold an
    /// empty string, and `Re: ` alone is worse than nothing, so the walk skips
    /// past it to an older row that has one.
    public static func reply(to events: [ThreadEvent]) -> String? {
        for event in events.reversed() {
            let subject = (event.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }
            guard !subject.lowercased().hasPrefix("re:") else { return subject }
            return prefix + subject
        }
        return nil
    }
}
