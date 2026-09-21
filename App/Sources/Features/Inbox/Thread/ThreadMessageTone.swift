import Foundation

/// Which ``Tone`` an OUTBOUND message's delivery status wears.
///
/// ⛔ A FILE OF ITS OWN, AND THE REASON IS THE `file_length` GATE RATHER THAN A
/// JUDGEMENT ABOUT WHERE IT BELONGS. `ThreadView.swift` runs up against the 500 lines
/// `swiftlint --strict` allows, and this enum is the largest piece of the thread
/// screen with no SwiftUI in it at all — so it is the one that stands alone.
///
/// ⛔ THIS IS THE ANSWER THE OPERATOR IS LOOKING FOR AFTER A SEND, so it must not be
/// decorative. A message that failed and one that was delivered rendering in the same
/// grey is the whole reason the call log's statuses got toned, and the stakes are
/// higher here: a send costs money, and a silent failure means the customer never got
/// the reply.
///
/// ⚠️ FAILS TO ``Tone/neutral`` FOR ANYTHING UNMODELLED. The status column carries
/// whatever the provider reported, and Twilio, Telnyx and Postmark do not agree on a
/// vocabulary, so painting an unknown value green would assert a delivery this client
/// cannot confirm.
///
/// ⚠️ LOWERCASED AND TRIMMED BEFORE MATCHING, for the same reason
/// ``Tone/forCallStatus(_:)`` does it: nothing normalises these columns on write.
enum ThreadMessageTone {
    static func tone(for status: String) -> Tone {
        let normalised = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if delivered.contains(normalised) {
            return .success
        }
        // ⛔ `undelivered` IS THE ONE THAT MATTERS MOST: the provider ACCEPTED the
        // message and then could not deliver it, so a client treating `sent` as
        // success has already told the operator it worked.
        if terminalBad.contains(normalised) {
            return .danger
        }
        // ⚠️ DELIBERATELY NOT SUCCESS. `queued` and `sent` are the states a message
        // sits in before it fails.
        if inFlight.contains(normalised) {
            return .district
        }
        return .neutral
    }

    private static let delivered: Set<String> = ["delivered", "received", "read"]
    private static let terminalBad: Set<String> = ["failed", "undelivered", "bounced", "rejected", "spam"]
    private static let inFlight: Set<String> = ["queued", "accepted", "sending", "sent", "submitted"]
}
