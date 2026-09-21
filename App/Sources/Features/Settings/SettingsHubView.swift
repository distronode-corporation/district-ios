import DistrictModel
import SwiftUI

/// The workspace settings hub: which section to open. Ported from Android's
/// `WorkspaceSettingsScreen.kt`, whose header decisions are carried over rather than
/// re-derived.
///
/// ⛔ IT HOLDS NO STATE AND MAKES NO REQUEST. Each section loads its own
/// configuration when it opens, so a hub-level read would be a second copy of the
/// same row going stale between screens — and on this surface a stale copy is the
/// input to a wholesale-replace save.
///
/// ⛔ EVERY ROW IS GATED BY PRESENCE, NOT BY ENABLEMENT, AND THE GATE IS
/// ``RouteGate`` RATHER THAN A RULE RE-DERIVED HERE. A disabled row that 403s on tap
/// is worse than no row, and a second copy of "who may open what" is how the two
/// copies come to disagree. ``RouteGate/gate(for:role:)`` already knows that the four
/// config-backed sections are hidden from a viewer (their read excludes one, because
/// the payload carries staff transfer numbers and the operator's own prompt) while
/// knowledge, messaging and members are merely `partial` (their reads admit a viewer
/// and their screens gate their own controls).
///
/// ⛔ A VIEWER REACHES THIS SCREEN AND GETS TWO ROWS OUT OF EIGHT. That is the whole
/// point of the gate above rather than a degenerate case of it: `workspace/knowledge`,
/// `workspace/knowledge-mode` and `workspace/messaging` all admit a viewer by design,
/// so hiding the hub in front of them would hide screens a viewer is entitled to. The
/// four config-backed rows and the members row stay hidden, which
/// is what Android admits and not one row more. The two screens they DO reach gate
/// their own controls — the reads admit a viewer and every write on both refuses one —
/// so "the row was drawn" never means "the button will work".
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once; SwiftUI
/// resolves that by TYPE, so a second registration here would be a runtime coin toss
/// rather than a compile error.
struct SettingsHubView: View {
    let workspaceId: String
    let role: WorkspaceRole?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                rows
                footnote
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.hubTitle)
        // ⛔ `.contain` FIRST, or every row below inherits this identifier. See
        // SignInView's note on inheritance.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Settings.hubRoot)
    }

    // MARK: - Rows

    /// ⛔ THE ORDER MIRRORS THE WEB CONSOLE'S TABS. An operator who has used the
    /// dashboard should find the same thing in the same place; a phone that
    /// reordered them by how often they are opened would be optimising the wrong
    /// number.
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Self.entries, id: \.section) { entry in
                if isVisible(entry.section) {
                    link(entry)
                    if entry.section != Self.entries.last?.section {
                        DistrictRowDivider()
                    }
                }
            }
        }
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }

    private func link(_ entry: SettingsHubEntry) -> some View {
        NavigationLink(value: destination(entry.section)) {
            DistrictListRow(title: entry.title, subtitle: entry.subtitle, trailing: { chevron })
        }
        .buttonStyle(.plain)
    }

    private var chevron: some View {
        // ⚠️ DECORATION. The row is a `NavigationLink`, so VoiceOver already
        // announces it as a button and says it opens something; a chevron on top of
        // that is "chevron dot right" read after every entry on the screen.
        Image(systemName: "chevron.right")
            .font(DistrictType.label)
            .foregroundStyle(colors.mutedForeground)
            .accessibilityHidden(true)
    }

    /// ⛔ SAYS WHY THE LIST STOPS WHERE IT DOES, AND IT SAYS TWO DIFFERENT THINGS.
    /// For a mutator the missing sections are the ones with no native screen; for a
    /// viewer they are the ones whose reads refuse them, and "edit it on the web"
    /// would be false because they cannot edit it there either.
    private var footnote: some View {
        Text(WorkspaceRole.allowsMutation(role) ? SettingsCopy.moreOnWeb : SettingsCopy.viewerNote)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Gating and destinations

    /// ⛔ ASKS ``RouteGate`` RATHER THAN ANSWERING ITSELF. See the ⛔ on the type.
    private func isVisible(_ section: SettingsSection) -> Bool {
        let route = Route.workspaceSettings(workspaceId: workspaceId, role: role, section: section)
        if case .hidden = RouteGate.gate(for: route, role: role) {
            return false
        }
        return true
    }

    /// ⛔ SCHEDULING IS THE ONE ROW WHOSE DESTINATION IS NOT A SETTINGS SECTION, AND
    /// THE SPLIT IS DELIBERATE. ``SchedulingHubView`` already exists, already resolves
    /// `canManage` from the server's own status route, and already words its own
    /// refusals; a `Route.workspaceSettings(section: .scheduling)` destination would
    /// be a second copy of that screen with a role-derived gate the server has
    /// explicitly told us not to re-derive.
    ///
    /// ⚠️ ITS VISIBILITY STILL COMES FROM THE SETTINGS-SECTION GATE ABOVE, which is
    /// `.partial` rather than hidden: every read behind it admits a viewer. See the ⛔ in
    /// ``RouteGate/settingsGate(for:)``.
    private func destination(_ section: SettingsSection) -> Route {
        guard section == .scheduling else {
            return .workspaceSettings(workspaceId: workspaceId, role: role, section: section)
        }
        return .scheduling(workspaceId: workspaceId, role: role, section: .hub)
    }

    /// ⚠️ `hub` IS ABSENT FROM THIS LIST because it is this screen. Every other case
    /// of ``SettingsSection`` appears exactly once, so a section added to that enum
    /// is a row that is missing here rather than one that silently cannot be reached
    /// — the compiler will not catch it, but the list is short enough to read.
    private static let entries: [SettingsHubEntry] = [
        SettingsHubEntry(.persona, SettingsCopy.personaTitle, SettingsCopy.personaSubtitle),
        SettingsHubEntry(.capabilities, SettingsCopy.capabilitiesTitle, SettingsCopy.capabilitiesSubtitle),
        SettingsHubEntry(.calls, SettingsCopy.callsTitle, SettingsCopy.callsSubtitle),
        SettingsHubEntry(.directory, SettingsCopy.directoryTitle, SettingsCopy.directorySubtitle),
        SettingsHubEntry(.routing, SettingsCopy.routingTitle, SettingsCopy.routingSubtitle),
        SettingsHubEntry(.knowledge, SettingsCopy.knowledgeTitle, SettingsCopy.knowledgeSubtitle),
        SettingsHubEntry(.messaging, SettingsCopy.messagingTitle, SettingsCopy.messagingSubtitle),
        SettingsHubEntry(.members, SettingsCopy.membersTitle, SettingsCopy.membersSubtitle),
        SettingsHubEntry(.scheduling, SettingsCopy.schedulingTitle, SettingsCopy.schedulingSubtitle),
    ]
}

/// One row of the hub.
///
/// ⚠️ A VALUE RATHER THAN A CLOSURE PER ROW, so the list above reads as a table and
/// so ``SettingsHubView/isVisible(_:)`` can be applied uniformly rather than
/// remembered per call site.
struct SettingsHubEntry {
    let section: SettingsSection
    let title: String
    let subtitle: String

    init(_ section: SettingsSection, _ title: String, _ subtitle: String) {
        self.section = section
        self.title = title
        self.subtitle = subtitle
    }
}
