import Foundation

/// The team, membership and offboarding sentences.
///
/// ⛔ PORTED FROM THE WEB TEAM PAGE AND ITS FORMAT HELPERS. See the namespace note on
/// ``SchedulingBookingWriteCopy`` for why this is its own enum rather than an
/// extension.
enum SchedulingTeamWriteCopy {
    // MARK: - Teams

    static let teamsHint = "A team rotates bookings through its hosts, in routing-priority order."
    static let cancel = "Cancel"
    /// ⚠️ THE EDIT SHEET'S WAY OUT IS "Done", NOT "Cancel", BECAUSE ITS WRITES HAVE
    /// ALREADY LANDED. Every control on it saves on its own button; calling the
    /// dismissal "Cancel" would promise an undo that does not exist. The web's team
    /// modal says "Done" for the same reason.
    static let close = "Done"
    static let createTitle = "New team"
    static let nameLabel = "Name"
    static let namePlaceholder = "Front desk"
    static let create = "Create team"
    static let createDone = "Team created"
    /// ⚠️ THE ONE CLIENT-SIDE RULE, AND IT IS THE WEB'S: trimmed, non-empty.
    static let nameRequired = "Give the team a name."
    /// ⚠️ The catalog's own ceiling (`z.string().min(1).max(200)`), mirrored so the
    /// button is honest rather than to re-validate the server.
    static let nameTooLong = "That name is longer than 200 characters."
    static let rename = "Save name"
    static let renameDone = "Team renamed"

    /// ⛔ THE SLUG IS NOT EDITABLE HERE, AND THAT IS THE WEB'S DECISION CARRIED
    /// OVER RATHER THAN AN UNFINISHED FORM. `teams.patch` accepts a slug, and the
    /// fork routes public team booking pages BY slug — so re-slugging breaks every
    /// link already handed out. The web team page sends `{id, name}` only; offering
    /// the field on a phone would make the destructive half of that op one tap
    /// further from an operator than it is on a desk.
    static let slugReadOnlyHint = "The booking-page address cannot be changed here."

    static let deleteTitle = "Delete this team?"
    static let deleteBody = "Event types that route to this team stop rotating through it."
    static let deleteKeep = "Keep team"
    static let deleteConfirm = "Delete team"
    static let deleteDone = "Team deleted"

    static func deleteTitle(_ name: String) -> String {
        name.isEmpty ? deleteTitle : "Delete \(name)?"
    }

    // MARK: - Members

    /// ⚠️ THE WORD ON THE CONTROL THAT OPENS THE MEMBER EDITOR. The sheet itself is
    /// titled with the TEAM's name, so the button has to say what it leads to
    /// rather than repeat the row it sits on.
    static let membersButton = "Hosts"
    static let membersHint = "A lower routing priority is offered a booking first."
    static let membersEmpty = "No hosts yet. Nothing routes through this team until one is added."
    static let addLabel = "Host"
    static let addPlaceholder = "Choose a host"
    static let addNone = "Every host is already in this team."
    static let add = "Add member"
    static let addRequired = "Choose a host to add."
    static let addDone = "Host added to the team"

    static let priorityLabel = "Routing priority"
    static let savePriority = "Save priority"
    static let priorityDone = "Routing priority saved"
    /// ⚠️ REFUSES AN EMPTY FIELD AND A DECIMAL RATHER THAN COERCING EITHER, which
    /// is the web's `parsePriority` rule. `Int("")` is nil in Swift and
    /// `Number("")` is 0 in JavaScript, so the web needs an explicit empty check
    /// where this does not — the SENTENCE is what has to match.
    static let priorityInvalid = "A routing priority is a whole number, zero or more."

    static let remove = "Remove"
    /// ⛔ A CONFIRMATION THE WEB DOES NOT HAVE, AND THE DIVERGENCE IS DELIBERATE.
    /// The web team page removes a member on one click. A row on a phone is a thumb
    /// target beside a priority field the same thumb edits, and the recovery is not
    /// free: re-adding restores membership but NOT the routing priority, which
    /// `teams.members.add` does not carry from this form. One tap of ceremony buys
    /// back a value the undo would lose.
    static let removeTitle = "Remove this host?"
    static let removeBody = "Bookings stop routing to them through this team. Their routing priority is not kept."
    static let removeKeep = "Keep them"
    static let removeDone = "Host removed from the team"

    // MARK: - Archiving a scheduler user

    static let archive = "Archive account"
    static let archiveTitle = "Archive this account?"
    /// ⚠️ SAYS WHAT A SOFT DELETE ACTUALLY DOES. The row and its links survive; the
    /// member cannot sign in, is skipped in routing, and their event types are
    /// deactivated. "Delete" would be the wrong word and the wrong expectation.
    static let archiveBody = "They can no longer sign in, they are skipped in routing, "
        + "and their event types stop taking bookings. The account is kept."
    /// ⚠️ NAMES THE PERSON. An
    /// operator cannot check a decision against an id, and this one closes
    /// somebody's access.
    static func archiveTitle(_ name: String) -> String {
        name.isEmpty ? archiveTitle : "Archive \(name)'s account?"
    }

    static let archiveKeep = "Keep account"
    static let archiveConfirm = "Archive account"
    static let archiveDone = "Scheduler account closed"

    static func archiveDone(_ name: String) -> String {
        name.isEmpty ? archiveDone : "\(name)'s scheduler account is closed"
    }

    /// ⛔ THE ARCHIVE IS BLOCKED UNTIL THE UPCOMING-BOOKING COUNT HAS BEEN READ AND
    /// IS ZERO, WHICH IS THE WEB'S `canArchive` AND NOT A CAUTION OF OUR OWN. The
    /// fork refuses with a 409 while the user still hosts anything, so offering the
    /// button before the read has landed offers a refusal.
    static let archiveBlocked = "Reassign or cancel their upcoming bookings first."
    static let archiveCounting = "Checking their upcoming bookings…"

    /// ⛔ ENUMERATES BECAUSE THIS CLIENT CANNOT TELL THE FOUR REFUSALS APART. The
    /// fork answers 409 (still hosting bookings), 403 (not the owner), 400 (is the
    /// workspace owner, or already archived) and 404 (gone), and every one of them
    /// arrives as ``SchedulingAdminError/unknown`` — the status is collapsed by
    /// `error(forStatus:code:)` before a screen sees it. The web writes
    /// four sentences because the browser still holds the number. Naming one of
    /// them here would be a guess presented as a fact; naming all of them is true.
    static let archiveRefused = "That account could not be archived. It may still hold upcoming bookings, "
        + "it may be the workspace owner, or it may be archived already."

    /// The standing banner for people who have left the workspace and still hold
    /// bookings. ⚠️ Singular and plural are SEPARATE SENTENCES on the web
    /// rather than one with a pluralised noun, because "accounts open" and "account
    /// open" both move.
    static func stranded(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let subject = list(names)
        if names.count == 1 {
            return "\(subject) is no longer in this workspace but still holds upcoming bookings, "
                + "so the scheduler kept their account open. "
                + "Reassign or cancel those bookings, then archive the account."
        }
        return "\(subject) are no longer in this workspace but still hold upcoming bookings, "
            + "so the scheduler kept their accounts open. "
            + "Reassign or cancel those bookings, then archive the accounts."
    }

    static let strandedTitle = "Someone who has left still has bookings"

    /// ⚠️ "a, b and c" — the Oxford comma is absent on purpose, matching the web's
    /// own join so the two surfaces read identically.
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        let head = names.dropLast().joined(separator: ", ")
        return "\(head) and \(names[names.count - 1])"
    }
}
