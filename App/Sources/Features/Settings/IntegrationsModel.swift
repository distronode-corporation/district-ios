import DistrictData
import DistrictModel
import Observation

/// A calendar provider the receptionist can book through, in the web's display order.
///
/// ⛔ THE NAMES ARE THE PROVIDERS' PRODUCT NAMES AND ARE THE SAME IN BOTH LOCALES, so they
/// are not in the catalog: translating one would name a product that does not exist. The
/// web keeps them identically in both locales for the same reason
/// (`capabilitiesI18n` `calendarProviderNames`).
enum IntegrationsCalendarProvider: String, CaseIterable {
    case google
    case microsoft

    /// The `provider` the connections read stores for this calendar.
    var connectionProvider: String {
        switch self {
        case .google: "google-calendar"
        case .microsoft: "microsoft-calendar"
        }
    }

    var name: String {
        switch self {
        case .google: "Google Calendar"
        case .microsoft: "Microsoft Outlook Calendar"
        }
    }
}

/// One connection's state, as the web reads it.
///
/// ⛔ ANY OTHER STORED VALUE, AND A MISSING ROW, READ AS `absent`. That is the web's own
/// rule (`normalizeCalendarStatus` in `AgentCapabilitiesForm`), so the two clients can never
/// disagree about whether a calendar is connected.
enum IntegrationsCalendarStatus: Equatable {
    case active
    case error
    case revoked
    case absent

    init(wire: String?) {
        switch wire {
        case "active": self = .active
        case "error": self = .error
        case "revoked": self = .revoked
        default: self = .absent
        }
    }

    var label: String {
        switch self {
        case .active: SettingsCopy.integrationsStatusActive
        case .error: SettingsCopy.integrationsStatusError
        case .revoked: SettingsCopy.integrationsStatusRevoked
        case .absent: SettingsCopy.integrationsStatusAbsent
        }
    }
}

struct IntegrationsCalendarRow: Equatable {
    let provider: IntegrationsCalendarProvider
    let status: IntegrationsCalendarStatus
    /// Whether the receptionist books into this calendar.
    let isActiveProvider: Bool
}

/// The Integrations screen's one read: which calendars the receptionist works through.
///
/// ⛔ READ-ONLY, AND THAT IS THE CONTRACT RATHER THAN A SHORTCUT. Connecting a calendar is a
/// provider's consent screen (Google through the web's sign-in, Microsoft through a route
/// that refuses any session but a browser's), and disconnecting has no mobile contract
/// yet, so every change goes through the web's page in a sheet and this screen re-reads
/// when the sheet closes.
@MainActor
@Observable
final class IntegrationsModel {
    enum State {
        case loading
        case ready([IntegrationsCalendarRow])
        case failed(FailureText)
    }

    private(set) var state: State = .loading

    private let repository: SetupWizardRepository
    private let workspaceId: String

    /// ⚠️ THE REPOSITORY IS THE TEST SEAM, as on ``SchedulingCalendarModel``: a test drives
    /// a real repository over a stub transport.
    init(repository: SetupWizardRepository, workspaceId: String) {
        self.repository = repository
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(repository: SetupWizardRepository(client: container.api), workspaceId: workspaceId)
    }

    func load() async {
        state = .loading
        switch await repository.connections(workspaceId: workspaceId) {
        case let .success(response):
            state = .ready(Self.rows(from: response))
        case let .failure(error):
            state = .failed(FailureText.from(error))
        }
    }

    /// ⚠️ BOTH PROVIDERS, ALWAYS, IN THE WEB'S ORDER, so a workspace with nothing connected
    /// shows two "Not connected" rows rather than an empty card. The `azure-ad` row is the
    /// sign-in identity, not a calendar, and is not drawn.
    ///
    /// ⚠️ A VIEWER'S ANSWER CARRIES NO `calendar` BLOCK (`district-connections-viewer.json`),
    /// so no row is marked active for one; the statuses alone are still true.
    static func rows(from response: ConnectionsResponse) -> [IntegrationsCalendarRow] {
        IntegrationsCalendarProvider.allCases.map { provider in
            let stored = response.connections.first { $0.provider == provider.connectionProvider }
            let status = IntegrationsCalendarStatus(wire: stored?.status)
            return IntegrationsCalendarRow(
                provider: provider,
                status: status,
                isActiveProvider: status == .active && response.calendar?.activeProvider == provider.rawValue
            )
        }
    }
}
