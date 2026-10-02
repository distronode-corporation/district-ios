import SwiftUI

/// The signed-in member's own scheduler preferences, and their picture.
struct SchedulingProfileSheet: View {
    @Bindable var model: SchedulingProfileModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingSettingsWriteCopy.profileTitle,
            subtitle: nil,
            cancelLabel: SchedulingTeamWriteCopy.close,
            confirmLabel: SchedulingSettingsWriteCopy.profileSave,
            confirmIdentifier: A11yID.SchedulingWritesB.profileSave,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                fields
                avatar
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.save() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.profileSheet)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            SettingsField(
                label: SchedulingSettingsWriteCopy.nameLabel,
                text: Binding(get: { model.name }, set: { model.editName($0) }),
                enabled: !model.busy
            )
            .accessibilityIdentifier(A11yID.SchedulingWritesB.profileName)
            timezonePicker
            choice(
                SchedulingSettingsWriteCopy.timeFormatLabel,
                SchedulingSettingsWriteCopy.timeFormats,
                model.timeFormat
            ) { model.editTimeFormat($0) }
            weekStartPicker
            choice(
                SchedulingSettingsWriteCopy.dateFormatLabel,
                SchedulingSettingsWriteCopy.dateFormats,
                model.dateFormat
            ) { model.editDateFormat($0) }
            SchedulingWriteRejection(message: model.rejected)
        }
    }

    /// ⚠️ A `Picker` HERE AND ROWS ELSEWHERE. The zone list is the whole IANA
    /// database; a row per entry would be several hundred buttons, which is the one
    /// case where a menu is the kinder control.
    private var timezonePicker: some View {
        Picker(
            SchedulingSettingsWriteCopy.timezoneLabel,
            selection: Binding(get: { model.timezone }, set: { model.editTimezone($0) })
        ) {
            ForEach(model.timezoneOptions, id: \.self) { zone in
                Text(zone).tag(zone)
            }
        }
        .disabled(model.busy)
    }

    private var weekStartPicker: some View {
        Picker(
            SchedulingSettingsWriteCopy.weekStartLabel,
            selection: Binding(get: { model.weekStart }, set: { model.editWeekStart($0) })
        ) {
            ForEach(SchedulingSettingsWriteCopy.weekStarts, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .disabled(model.busy)
    }

    /// ⛔ THE TAG IS THE WIRE VALUE, NEVER THE LABEL. `12-hour (2:30 pm)` is not
    /// something the catalog's `z.enum` accepts, and the two are one keystroke
    /// apart in a `ForEach`.
    private func choice(
        _ label: String,
        _ options: [(value: String, label: String)],
        _ selected: String,
        _ onSelect: @escaping (String) -> Void
    ) -> some View {
        Picker(label, selection: Binding(get: { selected }, set: { onSelect($0) })) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .disabled(model.busy)
    }

    private var avatar: some View {
        SchedulingWritesBImageRow(
            label: SchedulingSettingsWriteCopy.avatarLabel,
            publishedUrl: model.avatarUrl,
            state: model.avatarState,
            pickIdentifier: A11yID.SchedulingWritesB.profileAvatarPick,
            removeIdentifier: A11yID.SchedulingWritesB.profileAvatarRemove,
            onPicked: { bytes, mimeType in
                Task { await model.uploadAvatar(bytes: bytes, mimeType: mimeType) }
            },
            onRemove: { Task { await model.deleteAvatar() } },
            onUnreadable: { model.reportUnreadableAvatar() }
        )
    }
}

/// The seven `notify_*` preferences, as two labelled groups.
///
/// ⚠️ THE GROUPS ARE LOAD-BEARING RATHER THAN DECORATION. "Booking cancelled" and
/// "Someone cancelled with you" are the same event seen from two sides, and
/// without the headings a reader cannot tell which of the two they are turning off.
struct SchedulingNotificationsSheet: View {
    @Bindable var model: SchedulingNotificationsModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingSettingsWriteCopy.notificationsTitle,
            subtitle: nil,
            cancelLabel: SchedulingTeamWriteCopy.close,
            confirmLabel: SchedulingSettingsWriteCopy.notificationsSave,
            confirmIdentifier: A11yID.SchedulingWritesB.notificationsSave,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                SettingsCard(eyebrow: SchedulingSettingsWriteCopy.attendeeGroup) {
                    VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                        toggle(SchedulingSettingsWriteCopy.notifyConfirmation, model.confirmation) {
                            model.editConfirmation($0)
                        }
                        toggle(SchedulingSettingsWriteCopy.notifyCancellation, model.cancellation) {
                            model.editCancellation($0)
                        }
                        toggle(SchedulingSettingsWriteCopy.notifyReschedule, model.reschedule) {
                            model.editReschedule($0)
                        }
                        toggle(SchedulingSettingsWriteCopy.notifyReminder, model.reminder) {
                            model.editReminder($0)
                        }
                    }
                }
                SettingsCard(eyebrow: SchedulingSettingsWriteCopy.hostGroup) {
                    VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                        toggle(SchedulingSettingsWriteCopy.notifyHostBooking, model.hostBooking) {
                            model.editHostBooking($0)
                        }
                        toggle(SchedulingSettingsWriteCopy.notifyHostCancel, model.hostCancel) {
                            model.editHostCancel($0)
                        }
                        toggle(SchedulingSettingsWriteCopy.notifyHostReschedule, model.hostReschedule) {
                            model.editHostReschedule($0)
                        }
                    }
                }
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.save() }
        }
    }

    private func toggle(
        _ label: String,
        _ value: Bool,
        _ onChange: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(label, isOn: Binding(get: { value }, set: { onChange($0) }))
            .disabled(model.busy)
    }
}
