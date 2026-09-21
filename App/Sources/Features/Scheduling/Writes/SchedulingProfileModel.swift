import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The signed-in member's own scheduler profile, and their picture.
///
/// ⛔ FIVE FIELDS, AND THE FORM OWNS ALL FIVE. `me.patch` is sparse — an absent key
/// is left alone — but the web profile tab sends every one of them on every
/// save because the form holds every one of them. Sending only what was touched
/// would be correct on the wire and wrong in the product: a stale draft beside a
/// value somebody else changed is two answers to one question, and nothing here
/// re-reads between opening the sheet and saving.
///
/// ⛔ THE WIRE FIELD IS `timezone` AND THE COLUMN IS `iana_timezone`. Sending the
/// column name is SILENTLY IGNORED, which leaves every window this member
/// publishes on whatever zone the SSO hand-off inserted. ``SchedulingMeUpdate``
/// spells it correctly; this note is here because the mistake is invisible.
///
/// ⚠️ `me.*` WRITES SPEND THE **MEMBER** BUDGET, 30 an hour, not the workspace's
/// 120. A screen that saved on every keystroke would lock one person out for an
/// hour without touching anyone else, which is why this saves on a button.
///
/// ⚠️ THE AVATAR IS `viewer`-LEVEL AND THE BRANDING IMAGES ARE NOT. A shared
/// bucket would let one person uploading their own picture lock every administrator
/// out of every write for an hour; the two targets deliberately do not share one,
/// and this model owns only the `viewer` one.
@MainActor
@Observable
final class SchedulingProfileModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var avatarState: SchedulingWritesBState = .idle
    private(set) var me: SchedulingMe

    private(set) var name: String
    private(set) var timezone: String
    private(set) var timeFormat: String
    private(set) var weekStart: Int
    private(set) var dateFormat: String
    private(set) var rejected: String?

    private let admin: SchedulingAdminRepository
    private let media: SchedulingAdminMediaRepository
    private let workspaceId: String
    private let onSaved: (SchedulingMe) -> Void

    init(
        admin: SchedulingAdminRepository,
        media: SchedulingAdminMediaRepository,
        workspaceId: String,
        me: SchedulingMe,
        onSaved: @escaping (SchedulingMe) -> Void
    ) {
        self.admin = admin
        self.media = media
        self.workspaceId = workspaceId
        self.me = me
        self.onSaved = onSaved
        name = me.name
        timezone = me.timezone
        timeFormat = me.timeFormat
        weekStart = me.weekStart
        dateFormat = me.dateFormat
    }

    var busy: Bool {
        state.isWorking || avatarState.isWorking
    }

    /// ⛔ THE UPLOAD'S URL IS HELD BESIDE ``me`` RATHER THAN SPLICED INTO IT, AND
    /// THAT IS FORCED BY THE DTO RATHER THAN CHOSEN. ``SchedulingMe`` is all `let`
    /// with no public memberwise initialiser — it is a wire shape, and this module
    /// may not add one — so there is no way to produce a `SchedulingMe` with a new
    /// avatar without a second `me.get`. ⚠️ The override is cleared by every
    /// re-read, so the server's answer always wins in the end.
    private(set) var avatarOverride: String?

    var avatarUrl: String? {
        if let avatarOverride, !avatarOverride.isEmpty {
            return avatarOverride
        }
        guard let url = me.avatarUrl, !url.isEmpty else { return nil }
        return url
    }

    /// ⛔ THE STORED ZONE IS ALWAYS AN OPTION, EVEN IF THE DEVICE DOES NOT KNOW IT.
    /// `timezoneOptionsFor` does the same on the web, and the reason is that a
    /// picker which silently dropped the current value would rewrite it on the
    /// next save — a zone change nobody asked for, applied to every window this
    /// member publishes.
    ///
    /// ⚠️ WIDER THAN THE WEB'S NINE. The web profile tab offers a short shared
    /// list; iOS has the whole IANA database in `TimeZone.knownTimeZoneIdentifiers`
    /// and a searchable picker to put it in, and the wire accepts any string up to
    /// 100 characters. More choice, same contract.
    var timezoneOptions: [String] {
        var options = TimeZone.knownTimeZoneIdentifiers.sorted()
        if !timezone.isEmpty, !options.contains(timezone) {
            options.insert(timezone, at: 0)
        }
        return options
    }

    func editName(_ value: String) {
        name = value
        clearRejection()
    }

    func editTimezone(_ value: String) {
        timezone = value
        clearRejection()
    }

    func editTimeFormat(_ value: String) {
        timeFormat = value
        clearRejection()
    }

    func editWeekStart(_ value: Int) {
        weekStart = value
        clearRejection()
    }

    func editDateFormat(_ value: String) {
        dateFormat = value
        clearRejection()
    }

    /// ⚠️ THE SAME ORDER AND THE SAME SENTENCES AS THE WEB'S. Every one
    /// of these is also enforced by the catalog, so this is a better message rather
    /// than a second validator.
    var validationFailure: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return SchedulingSettingsWriteCopy.nameRequired
        }
        if trimmedName.count > SchedulingSettingsWriteCopy.nameLimit {
            return SchedulingSettingsWriteCopy.nameTooLong
        }
        if timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SchedulingSettingsWriteCopy.timezoneRequired
        }
        if !SchedulingSettingsWriteCopy.timeFormats.contains(where: { $0.value == timeFormat }) {
            return SchedulingSettingsWriteCopy.timeFormatRequired
        }
        if !SchedulingSettingsWriteCopy.weekStarts.contains(where: { $0.value == weekStart }) {
            return SchedulingSettingsWriteCopy.weekStartRequired
        }
        if !SchedulingSettingsWriteCopy.dateFormats.contains(where: { $0.value == dateFormat }) {
            return SchedulingSettingsWriteCopy.dateFormatRequired
        }
        return nil
    }

    func save() async {
        guard !busy else { return }
        if let failure = validationFailure {
            rejected = failure
            return
        }
        var update = SchedulingMeUpdate()
        update.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update.timezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        update.timeFormat = timeFormat
        update.weekStart = weekStart
        update.dateFormat = dateFormat
        state = .working
        do {
            try await adopt(admin.updateMe(workspaceId: workspaceId, update))
            state = .done(SchedulingSettingsWriteCopy.profileDone)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ THE UPLOAD IS IMMEDIATE AND CLOSING THE SHEET DOES NOT UNDO IT. Same as
    /// the web, and the copy says so — a picture that vanished because somebody
    /// tapped Remove and then Cancel is the surprise that warning exists for.
    func uploadAvatar(bytes: Data, mimeType: String) async {
        guard !busy else { return }
        let file = SchedulingWritesBImage.file(bytes: bytes, mimeType: mimeType, target: .avatar)
        if let rejection = SchedulingWritesBImage.rejection(for: file) {
            avatarState = .failed(FailureText(message: rejection, action: .none))
            return
        }
        avatarState = .working
        do {
            let result = try await media.upload(workspaceId: workspaceId, target: .avatar, file: file)
            // ⛔ `""` IS REACHABLE AND MEANS "UPLOADED, ADDRESS UNREADABLE". Treat
            // it as "re-read", never as a URL to load.
            if let url = result.avatarUrl, !url.isEmpty {
                avatarOverride = url
            } else {
                await reread()
            }
            avatarState = .done(SchedulingSettingsWriteCopy.imageUploaded(SchedulingSettingsWriteCopy.avatarLabel))
        } catch {
            avatarState = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ THE PICKER GAVE BACK NOTHING READABLE, WHICH IS A THIRD ANSWER — not a
    /// rejected type and not a rejected size. It spends no request, so it is
    /// reported on the avatar's own state rather than thrown.
    func reportUnreadableAvatar() {
        avatarState = .failed(FailureText(
            message: SchedulingSettingsWriteCopy.imageUnreadable,
            action: .none
        ))
    }

    /// ⚠️ ANSWERS NOTHING, so the avatar URL this model is holding is stale the
    /// moment it returns and `me.get` is the only way to learn the new one.
    func deleteAvatar() async {
        guard !busy else { return }
        avatarState = .working
        do {
            _ = try await admin.deleteAvatar(workspaceId: workspaceId)
            await reread()
            avatarState = .done(SchedulingSettingsWriteCopy.imageRemoved(SchedulingSettingsWriteCopy.avatarLabel))
        } catch {
            avatarState = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ A FAILED RE-READ AFTER A WRITE THAT LANDED LEAVES THE OLD ROW ALONE. The
    /// picture IS changed; only this copy is out of date, and reporting the read's
    /// failure over the write's success would invite the operator to do it twice.
    private func reread() async {
        guard let fresh = try? await admin.me(workspaceId: workspaceId) else { return }
        adopt(fresh)
    }

    private func adopt(_ fresh: SchedulingMe) {
        me = fresh
        avatarOverride = nil
        onSaved(fresh)
    }

    private func clearRejection() {
        rejected = nil
        if case .failed = state {
            state = .idle
        }
    }
}
