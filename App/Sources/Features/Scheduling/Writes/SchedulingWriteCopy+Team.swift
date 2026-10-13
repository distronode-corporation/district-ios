import DistrictL10n
import Foundation

/// The team, membership and offboarding sentences.
///
/// ⛔ PORTED FROM THE WEB TEAM PAGE AND ITS FORMAT HELPERS. See the namespace note on
/// ``SchedulingBookingWriteCopy`` for why this is its own enum rather than an
/// extension.
enum SchedulingTeamWriteCopy {
    // MARK: - Teams

    static func deleteTitle(_ name: String) -> String {
        name.isEmpty ? deleteTitle : deleteTitleNamed(name)
    }

    // MARK: - Archiving a scheduler user

    /// ⚠️ NAMES THE PERSON. An
    /// operator cannot check a decision against an id, and this one closes
    /// somebody's access.
    static func archiveTitle(_ name: String) -> String {
        name.isEmpty ? archiveTitle : archiveTitleNamed(name)
    }

    static func archiveDone(_ name: String) -> String {
        name.isEmpty ? archiveDone : archiveDoneNamed(name)
    }

    /// The standing banner for people who have left the workspace and still hold
    /// bookings. ⚠️ Singular and plural are SEPARATE SENTENCES on the web
    /// rather than one with a pluralised noun, because "accounts open" and "account
    /// open" both move.
    static func stranded(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        // "a, b and c": the Oxford comma is absent on purpose, matching the web's own join.
        let subject = L10nFormat.list(names)
        return names.count == 1 ? strandedOne(subject) : strandedMany(subject)
    }
}
