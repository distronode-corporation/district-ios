import DistrictModel
import SwiftUI

/// Integrations: the accounts the receptionist works through, in the web page's order
/// (`/studio/integrations`): the calendars, then District Desk and what the receptionist may
/// learn about a business caller.
///
/// ⛔ THE CALENDARS ARE READ HERE AND CHANGED ON THE WEB'S PAGE, IN A SHEET. Connecting one
/// is the provider's consent screen: Google's goes through the web's sign-in, and the
/// Microsoft connect route refuses any session but a browser's (a native bearer must not be
/// able to attach a sign-in identity to itself). Disconnecting has no mobile contract yet.
/// So one button opens the page and the screen re-reads when the sheet closes.
///
/// ⛔ THE BUTTON OPENS AN IN-APP SAFARI SHEET, NEVER `openURL`, because `/dashboard/district/*`
/// is a path this app claims and the system would route it straight back here. See
/// ``FinishSetupCard``.
///
/// ⚠️ DESK AND ENRICHMENT ARE LINKS TO THE SCREENS THAT ALREADY OWN THEM, NOT COPIES. The
/// enrichment consent is saved by the Skills screen's own panel and the desk's settings by
/// the desk's; a second form here would be a second baseline for the same row. A viewer
/// sees neither, because both destinations exclude one.
///
/// ⚠️ THE SENDING DOMAIN AND THE MEDIA LIBRARY ARE NOT HERE: neither route has a mobile
/// contract, so the screen says they are not available rather than guessing at a shape.
struct IntegrationsView: View {
    @State private var model: IntegrationsModel
    @State private var handOff: AppLinkHandOff?

    private let baseURL: URL
    private let workspaceId: String
    private let role: WorkspaceRole?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: IntegrationsModel(container: container, workspaceId: workspaceId))
        baseURL = container.baseURL
        self.workspaceId = workspaceId
        self.role = role
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var canChange: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                if !canChange {
                    note(SettingsCopy.integrationsViewerNote)
                }
                calendars
                if canChange {
                    services
                }
                note(SettingsCopy.integrationsNotHere)
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        // ⛔ `.contain` FIRST, or the identifier is inherited by every control inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Integrations.root)
        .navigationTitle(SettingsCopy.integrationsTitle)
        .task {
            await model.load()
        }
        .sheet(item: $handOff, onDismiss: reload) { handOff in
            SafariView(url: handOff.url)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Calendars

    @ViewBuilder
    private var calendars: some View {
        switch model.state {
        case .loading:
            SettingsSkeleton()
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        case let .ready(rows):
            SettingsCard(eyebrow: SettingsCopy.integrationsCalendarsEyebrow) {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.provider) { row in
                        calendarRow(row)
                        if row.provider != rows.last?.provider {
                            DistrictRowDivider()
                        }
                    }
                }
                if canChange {
                    note(SettingsCopy.integrationsCalendarsNote)
                    openPageButton
                }
            }
        }
    }

    /// ⚠️ NOT A ``DistrictListRow``: that row truncates its title to one line and carries its
    /// own inset, so inside a card "Microsoft Outlook Calendar" lost its last word beside a
    /// long badge ("Reconnection needed") and the rows sat further in than the note below.
    private func calendarRow(_ row: IntegrationsCalendarRow) -> some View {
        HStack(alignment: .center, spacing: DistrictSpacing.tight) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(row.provider.name)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if row.isActiveProvider {
                    Text(SettingsCopy.integrationsActiveProvider)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                }
            }
            Spacer(minLength: DistrictSpacing.tight)
            DistrictBadge(text: row.status.label, tone: tone(row.status))
        }
        .padding(.vertical, DistrictSpacing.row)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Integrations.calendar(row.provider.rawValue))
    }

    /// ⚠️ THE WEB'S MAPPING (`CALENDAR_STATUS_TYPE`): the words carry the meaning and the
    /// tone only picks the colour, so a monochrome display loses nothing.
    private func tone(_ status: IntegrationsCalendarStatus) -> Tone {
        switch status {
        case .active: .success
        case .error: .warning
        case .revoked: .danger
        case .absent: .neutral
        }
    }

    @ViewBuilder
    private var openPageButton: some View {
        if let url = Self.destination(baseURL: baseURL) {
            Button(SettingsCopy.integrationsOpenPage) {
                handOff = AppLinkHandOff(url: url)
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(A11yID.Integrations.openPage)
        }
    }

    // MARK: - Connected services

    private var services: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            DistrictEyebrow(text: SettingsCopy.integrationsServicesEyebrow)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                link(
                    to: .desk(workspaceId: workspaceId, role: role),
                    title: DeskCopy.title,
                    subtitle: SettingsCopy.integrationsDeskSubtitle,
                    id: A11yID.Integrations.desk
                )
                DistrictRowDivider()
                link(
                    to: .workspaceSettings(workspaceId: workspaceId, role: role, section: .capabilities),
                    title: SettingsCopy.integrationsEnrichmentTitle,
                    subtitle: SettingsCopy.integrationsEnrichmentSubtitle,
                    id: A11yID.Integrations.enrichment
                )
            }
            .districtCardSurface()
        }
    }

    private func link(to route: Route, title: String, subtitle: String, id: String) -> some View {
        NavigationLink(value: route) {
            DistrictListRow(title: title, subtitle: subtitle, trailing: {
                // ⚠️ DECORATION, as on the settings hub: the link already says it opens something.
                Image(systemName: "chevron.right")
                    .font(DistrictType.label)
                    .foregroundStyle(colors.mutedForeground)
                    .accessibilityHidden(true)
            })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func reload() {
        Task { await model.load() }
    }

    /// The web's Integrations page on the host this build talks to.
    ///
    /// ⚠️ DERIVED FROM THE CONTAINER'S BASE URL, never a literal, so a staging build opens
    /// staging; the same rule as ``FinishSetupCard/destination(baseURL:)``.
    static func destination(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        // ⛔ HTTPS ONLY: `SFSafariViewController` traps on any other scheme.
        guard components.scheme == "https" else { return nil }
        components.path = AppLinkResolver.pathPrefix + "/studio/integrations"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
