import DistrictData
import DistrictModel
import SwiftUI

/// The four editors behind the settings screen's four tabs.
///
/// ⛔ EACH BUTTON TAKES THE VALUE ITS TAB READ, AND THAT IS WHAT KEEPS A FORM OFF A
/// FAILED READ. `settings.branding.patch` and `me.patch` both send every field they
/// were given, so a form rendered from nothing and then saved does not save nothing
/// — it blanks a customer-facing page or a host's timezone. The read screen renders
/// these only from `.ready`, which is why the payload is a parameter rather than
/// something the model fetches for itself.
///
/// ⛔ AND THE ROLE RULE DIFFERS BETWEEN THEM, WHICH IS THE TRAP ON THIS SCREEN.
/// Branding and the booking assistant are `client`-level; `me.patch` and
/// `me.avatar.delete` are `viewer`-level, because they touch only the caller's OWN
/// profile — a viewer who cannot set their own timezone is offered every booking
/// window in the wrong hours. The gate is therefore applied by the SCREEN, per tab,
/// and never by this file.
extension SchedulingWriteCopy {
    static let brandingEdit = "Edit booking page"
    static let automationEdit = "Edit booking assistant"
    static let profileEdit = "Edit profile"
    static let notificationsEdit = "Edit notifications"
}

/// The booking page: business name, logo, banner, legal links and fallback locale.
struct SchedulingBrandingEditButton: View {
    let admin: SchedulingAdminRepository
    let media: SchedulingAdminMediaRepository
    let workspaceId: String
    let branding: SchedulingBranding
    let onSaved: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingBrandingModel>?

    var body: some View {
        Button(SchedulingWriteCopy.brandingEdit) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.brandingEdit)
        .sheet(item: $editing) { entry in
            SchedulingBrandingSheet(model: entry.model) { editing = nil }
        }
    }

    /// ⚠️ THE MEDIA REPOSITORY TRAVELS WITH THE ADMIN ONE BECAUSE THE LOGO AND THE
    /// BANNER ARE NOT CATALOG OPS. They are multipart uploads on their own route
    /// (see ``SchedulingAdminMediaRepository``), so a sheet that could edit the
    /// business name and not replace the logo would be half the web's form.
    private func makeModel() -> SchedulingBrandingModel {
        SchedulingBrandingModel(
            admin: admin,
            media: media,
            workspaceId: workspaceId,
            branding: branding,
            onSaved: { _ in onSaved() }
        )
    }
}

/// The booking assistant, in one sheet.
///
/// ⚠️ ONE OP BEHIND THE FORM, matching the tab that reads it: the model sends nothing
/// when nothing changed.
struct SchedulingAutomationEditButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let llm: SchedulingLLMSettings
    let onSaved: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingAutomationModel>?

    var body: some View {
        Button(SchedulingWriteCopy.automationEdit) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.automationEdit)
        .sheet(item: $editing) { entry in
            SchedulingAutomationSheet(model: entry.model) { editing = nil }
        }
    }

    private func makeModel() -> SchedulingAutomationModel {
        SchedulingAutomationModel(
            admin: admin,
            workspaceId: workspaceId,
            llm: llm,
            onSaved: onSaved
        )
    }
}

/// The caller's own scheduler profile, and their avatar.
struct SchedulingProfileEditButton: View {
    let admin: SchedulingAdminRepository
    let media: SchedulingAdminMediaRepository
    let workspaceId: String
    let me: SchedulingMe
    let onSaved: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingProfileModel>?

    var body: some View {
        Button(SchedulingWriteCopy.profileEdit) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.profileEdit)
        .sheet(item: $editing) { entry in
            SchedulingProfileSheet(model: entry.model) { editing = nil }
        }
    }

    private func makeModel() -> SchedulingProfileModel {
        SchedulingProfileModel(
            admin: admin,
            media: media,
            workspaceId: workspaceId,
            me: me,
            onSaved: { _ in onSaved() }
        )
    }
}

/// The seven email switches, which are the same `me.patch` the profile sheet spends.
///
/// ⚠️ A SEPARATE SHEET THOUGH IT IS ONE OP, because it is a separate TAB: the web
/// splits them the same way, and a form carrying a timezone picker beside seven
/// notification toggles is two decisions in one dialog.
struct SchedulingNotificationsEditButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let me: SchedulingMe
    let onSaved: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingNotificationsModel>?

    var body: some View {
        Button(SchedulingWriteCopy.notificationsEdit) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.notificationsEdit)
        .sheet(item: $editing) { entry in
            SchedulingNotificationsSheet(model: entry.model) { editing = nil }
        }
    }

    private func makeModel() -> SchedulingNotificationsModel {
        SchedulingNotificationsModel(
            admin: admin,
            workspaceId: workspaceId,
            me: me,
            onSaved: { _ in onSaved() }
        )
    }
}
