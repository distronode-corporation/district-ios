import DistrictModel
import Foundation

/// One person, as the team screen sees them: their District membership and their
/// scheduler account, joined.
///
/// ⛔ THE JOIN IS ON THE EMAIL ADDRESS AND THERE IS NOTHING ELSE TO JOIN ON. District
/// membership and the scheduler's user table are separate systems with separate ids; the
/// address is the only value both hold. ⚠️ It is compared case-INSENSITIVELY, because one
/// side is whatever the customer typed into an invite and the other is whatever they
/// typed into the scheduler.
public struct SchedulingMemberRow: Equatable, Sendable {
    /// Whether the scheduler has an account for this person, and what state it is in.
    public enum State: String, Equatable, Sendable {
        /// A live scheduler account: bookable.
        case host
        /// In the workspace, with no scheduler account yet.
        case absent
        /// A scheduler account that has been soft-deleted.
        case archived
    }

    /// ⚠️ THE LOWER-CASED EMAIL. It is the join key and the row identity; the displayed
    /// address is ``email``, which keeps whichever source's casing produced the row.
    public let key: String
    public let email: String
    public let name: String
    /// ⛔ nil MEANS "NO DISTRICT ROW", WHICH IS A PERSON WHO HAS LEFT THE WORKSPACE AND
    /// STILL HAS A SCHEDULER ACCOUNT. It is not "role unknown" and it is not "viewer"; it
    /// is what ``strandedHosts(_:)`` looks for.
    public let districtRole: String?
    public let state: State
    public let schedulerUserId: String?
}

/// The District member rows the team screen joins against.
///
/// ⚠️ A LOCAL SHAPE RATHER THAN A `Workspace` DTO, because the screen reads
/// `workspace/members` (a different route from everything else on this surface) and needs
/// exactly two of its fields. Naming them here keeps the join testable without the
/// membership payload.
public struct SchedulingDistrictMember: Equatable, Sendable {
    public let email: String
    public let role: String?

    public init(email: String, role: String?) {
        self.email = email
        self.role = role
    }
}

/// The team screen's read half, ported from `team-format.ts`.
public enum SchedulingTeamFormat {
    static let districtRoleLabels = [
        "agency": "Agency",
        "client": "Client",
        "viewer": "Viewer",
    ]

    /// The local part of an address, or the whole thing when there is none.
    ///
    /// ⚠️ `@example.com` HAS AN EMPTY LOCAL PART AND FALLS BACK TO THE FULL STRING. An
    /// empty name cell reads as data that failed to load; the address is at least true.
    public static func nameFromEmail(_ email: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everything before the first `@`, or the whole string when there is none.
        let local = trimmed.prefix { $0 != "@" }
        return local.isEmpty ? trimmed : String(local)
    }

    /// District's members and the scheduler's users, as one list.
    ///
    /// ⛔ DISTRICT'S ORDER FIRST, THEN SCHEDULER-ONLY ROWS. The second pass is what
    /// surfaces somebody who has left the workspace but still holds bookings — the
    /// stranded host the screen warns about — and dropping it would hide exactly the
    /// person an operator needs to deal with.
    ///
    /// ⚠️ A DUPLICATE ADDRESS IS SKIPPED AFTER THE FIRST, and the scheduler-side lookup
    /// keeps the LAST user for a duplicated address. Both are the source's behaviour; a
    /// scheduler with two accounts on one address is a fork-side anomaly this screen
    /// reports rather than resolves.
    ///
    /// ⚠️ THE SCHEDULER'S NAME WINS OVER THE DERIVED ONE ONLY WHEN IT IS NON-BLANK,
    /// which is the JavaScript `||` and not a `??`: a scheduler account whose name is
    /// whitespace falls back to the address's local part rather than rendering blank.
    public static func joinMembers(
        district: [SchedulingDistrictMember],
        scheduler: [SchedulingUser]
    ) -> [SchedulingMemberRow] {
        var byEmail: [String: SchedulingUser] = [:]
        for user in scheduler {
            byEmail[normalize(user.email)] = user
        }

        var rows: [SchedulingMemberRow] = []
        var seen: Set<String> = []

        for member in district {
            let key = normalize(member.email)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let user = byEmail[key]
            rows.append(SchedulingMemberRow(
                key: key,
                email: member.email,
                name: preferredName(user?.name, fallbackEmail: member.email),
                districtRole: member.role,
                state: state(for: user),
                schedulerUserId: user?.id
            ))
        }

        for user in scheduler {
            let key = normalize(user.email)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(SchedulingMemberRow(
                key: key,
                email: user.email,
                name: preferredName(user.name, fallbackEmail: user.email),
                districtRole: nil,
                state: user.archived ? .archived : .host,
                schedulerUserId: user.id
            ))
        }

        return rows
    }

    /// Host / Archived / Not set up yet.
    public static func memberStateLabel(_ state: SchedulingMemberRow.State) -> SchedulingStatusLabel {
        switch state {
        case .host: SchedulingStatusLabel(label: "Host", kind: .success)
        case .archived: SchedulingStatusLabel(label: "Archived", kind: .stopped)
        case .absent: SchedulingStatusLabel(label: "Not set up yet", kind: .info)
        }
    }

    /// Agency / Client / Viewer, or a sentence for somebody who has left.
    ///
    /// ⚠️ AN UNKNOWN ROLE IS ECHOED **AS IT CAME**, not as the normalised form the lookup
    /// used. The operator should see the value the server actually sent, casing included,
    /// because that is what they would have to quote in a support request.
    public static func districtRoleLabel(_ role: String?) -> String {
        guard let role else { return "Removed from the workspace" }
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return districtRoleLabels[normalized] ?? role
    }

    /// Whether this person's bookings have to be dealt with before their account can go.
    public static func needsBookingResolution(_ row: SchedulingMemberRow) -> Bool {
        guard row.schedulerUserId != nil else { return false }
        return row.districtRole == nil || row.state == .archived
    }

    /// People who have left the workspace and still hold a live scheduler account.
    public static func strandedHosts(_ rows: [SchedulingMemberRow]) -> [SchedulingMemberRow] {
        rows.filter { $0.districtRole == nil && $0.state == .host }
    }

    /// The warning sentence, or empty when there is nothing to warn about.
    ///
    /// ⛔ FOUR CLAUSES MOVE WITH THE COUNT: `is`/`are`, `holds`/`hold`, and `account`
    /// twice. A single pluralised noun is not enough here, which is why the two sentences
    /// are written out rather than assembled.
    ///
    /// ⚠️ NO OXFORD COMMA: two names read "A and B", three read "A, B and C".
    public static func strandedNotice(_ rows: [SchedulingMemberRow]) -> String {
        let names = rows.map(\.name)
        guard let last = names.last else { return "" }
        if names.count == 1 {
            return "\(last) is no longer in this workspace but still holds upcoming bookings, "
                + "so the scheduler kept their account open. Reassign or cancel those bookings, "
                + "then archive the account."
        }
        let who = "\(names.dropLast().joined(separator: ", ")) and \(last)"
        return "\(who) are no longer in this workspace but still hold upcoming bookings, "
            + "so the scheduler kept their accounts open. Reassign or cancel those bookings, "
            + "then archive the accounts."
    }

    /// How many people are on a team.
    ///
    /// ⚠️ A `memberCount` OF ZERO IS HONOURED. The source uses `??` rather than `||`
    /// precisely so a server-reported zero is not mistaken for an absent count and
    /// replaced by the length of an inlined array that may itself be nil.
    public static func teamMemberCount(_ team: SchedulingTeam) -> Int {
        team.memberCount ?? team.members?.count ?? 0
    }

    /// ⚠️ NOTHING IN THIS READ STAGE CALLS IT. The archive refusals are the write stage's,
    /// and they are ported here rather than later because they are chosen from the HTTP
    /// STATUS rather than from any text the fork sends — that mapping is the knowledge
    /// worth capturing while the source is open, and it is the kind that is guessed wrong
    /// when it is rebuilt from a memory of the screen.
    public static func archiveRefusalSentence(status: Int, fallback: String) -> String {
        switch status {
        case 409:
            "They still have upcoming bookings. Reassign or cancel those first, "
                + "then archive the account."
        case 403:
            "You cannot archive that account. Only the workspace owner can archive "
                + "another administrator."
        case 400:
            "That account cannot be archived. The workspace owner has to be transferred "
                + "first, and an account that is already archived stays archived."
        case 404:
            "The booking system no longer has that account."
        default:
            fallback
        }
    }

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func state(for user: SchedulingUser?) -> SchedulingMemberRow.State {
        guard let user else { return .absent }
        return user.archived ? .archived : .host
    }

    static func preferredName(_ schedulerName: String?, fallbackEmail: String) -> String {
        let trimmed = schedulerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nameFromEmail(fallbackEmail) : trimmed
    }
}
