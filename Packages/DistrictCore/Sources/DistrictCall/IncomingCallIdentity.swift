import DistrictModel
import Foundation

/// Who is calling, read out of the workspace's own record of the call.
///
/// ⛔ THE RING PUSH CARRIES IDENTIFIERS ONLY AND THAT IS NOT BEING CHANGED.
/// `actions/ring-app` states it at the fan-out: no LiveKit token, no caller
/// number, no name, because a push is readable by the operating system and by
/// any notification-listener app. Putting the number in the payload is the
/// obvious fix and it is the wrong one: it would hand every caller's line to
/// software that never authenticated as this workspace. So the identity is
/// FETCHED instead, and this type is what the fetched row resolves to. The fetch
/// itself is in the App target, on `IncomingCallIdentity.lookUp`, because it
/// needs a repository and a bearer; everything below is a pure function of one
/// ``DistrictModel/CallSummary`` and nothing else.
///
/// ⛔ IT LIVES ON THE LINUX-TESTED TIER FOR THAT REASON. In `App/Sources` the two
/// sentinel rules below (the ones that decide what this client reports to the
/// operating system as a phone number) would have no test lane able to reach
/// them at all. There is no UIKit, no CallKit and no SwiftUI in any of it.
///
/// ⛔ EVERY FAILURE IS AN ABSENCE RATHER THAN AN ERROR, AND THE PLACEHOLDER RING
/// IS THE CORRECT OUTCOME. There is no retry, no error state and nothing
/// user-visible: a call that rings saying "Incoming call" is exactly what this
/// client did before this type existed, and it is still a working phone call.
///
/// ⛔ NOTHING HERE IS LOGGED. A caller's number is the most sensitive thing this
/// screen will ever hold, and a log line outlives the call.
public struct IncomingCallIdentity: Equatable, Sendable {
    /// The caller's own number, E.164 from telephony, or nil when the row
    /// carried none.
    ///
    /// ⛔ ``DistrictModel/CallSummary/from`` AND NOTHING ELSE, BECAUSE THIS
    /// BECOMES A `CXHandle(type: .phoneNumber, …)`.
    /// ``DistrictModel/CallSummary/number`` reads like the obvious source and is
    /// not one: the server builds it as `number: displayName || c.from ||
    /// "Unknown"`, so that column is a DISPLAY STRING holding a PERSON'S NAME
    /// whenever a contact resolved and the literal "Unknown" when nothing did.
    /// Either of those in a phone-number handle writes a string nobody can dial
    /// into the system's own call log, on every device, forever. That is the
    /// exact outcome the App target's CallKit bridge refuses to produce, and it
    /// would leave a future Call Directory extension, which can only name a
    /// NUMBER, with nothing it can name.
    public let handle: String?

    /// The person, as the workspace's own Contact table knows them.
    ///
    /// ⚠️ ``DistrictModel/CallSummary/callerName`` IS THE LITERAL "Unknown" WHEN
    /// NOBODY RESOLVED, not nil and not empty: the server writes
    /// `displayName || "Unknown"`. Passing that through would put the word
    /// Unknown on the ring screen and into Recents as though it were somebody's
    /// name, so it is treated as the absence it is.
    public let name: String?

    /// Whether there is anything worth telling CallKit at all.
    public var isKnown: Bool {
        handle != nil || name != nil
    }

    /// The one line a screen shows: the person when we have one, else the
    /// number.
    ///
    /// ⚠️ NEVER A THIRD STRING. A screen that invented "Unknown caller" here
    /// would be saying more than the workspace actually knows.
    public var displayLine: String? {
        name ?? handle
    }
}

public extension IncomingCallIdentity {
    /// What the server writes when nothing resolved.
    ///
    /// ⚠️ ITS OWN CONSTANT BECAUSE IT IS A WIRE VALUE BEING RECOGNISED, not copy
    /// being shown. `toCallSummaries` emits it for both fields; see the ⚠️ on
    /// ``name``.
    static let unresolvedName = "Unknown"

    /// The whole mapping, with no network in it.
    ///
    /// ⚠️ IT MAY ANSWER AN IDENTITY THAT KNOWS NOTHING, and the caller is what
    /// decides that is not worth reporting. A row with no number and no resolved
    /// contact is a legitimate row; ``isKnown`` is how it says so.
    static func resolve(from summary: CallSummary) -> IncomingCallIdentity {
        IncomingCallIdentity(handle: dialable(summary.from), name: person(summary.callerName))
    }

    /// ⛔ BLANK COUNTS AS ABSENT, the rule `CallsRepository` already applies to
    /// this same column: a handle made of whitespace is a handle nobody can dial
    /// and a blank entry in the system call log.
    ///
    /// ⚠️ THE "Unknown" SENTINEL IS NOT REJECTED HERE, ON PURPOSE. It is what the
    /// server writes into ``DistrictModel/CallSummary/number`` and
    /// ``DistrictModel/CallSummary/callerName``, never into
    /// ``DistrictModel/CallSummary/from``, which is the raw telephony value or
    /// null. Filtering it out of a number column would be guarding against a case
    /// the wire does not produce while implying the column is display text.
    private static func dialable(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ⚠️ THE SENTINEL IS REJECTED HERE RATHER THAN AT THE SCREEN, so every
    /// surface that reads ``name`` gets the same answer.
    private static func person(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != unresolvedName else { return nil }
        return trimmed
    }
}
