import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// API keys, connected apps and webhooks.
///
/// ⛔ NOTHING ON THIS SCREEN EVER SHOWS A SECRET, AND THE READS CANNOT. `apiKeys.list`
/// carries no key material and `webhooks.list` carries no signing secret — both are minted
/// once, on create, and the web holds each in a modal that drops it from state when it
/// closes. ⚠️ The value a create answers must not be logged, must not be persisted and
/// must not be interpolated into a copyable snippet.
@MainActor
@Observable
final class SchedulingDeveloperModel {
    private(set) var tab = SchedulingDeveloperFormat.tabIds[0]

    private(set) var keys: SchedulingSectionState<[SchedulingAPIKey]>?
    private(set) var apps: SchedulingSectionState<[SchedulingOAuthConnection]>?
    private(set) var webhooks: SchedulingSectionState<[SchedulingWebhook]>?

    /// Deliveries for whichever webhook is open. ⚠️ Read on demand, like the consent rows.
    private(set) var deliveries: [String: SchedulingSectionState<[SchedulingWebhookDelivery]>] = [:]

    private(set) var timezone = "UTC"
    private(set) var publicHost: String?

    private let repository: SchedulingAdminRepository
    private let scheduling: SchedulingRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(
        repository: SchedulingAdminRepository,
        scheduling: SchedulingRepository,
        workspaceId: String
    ) {
        self.repository = repository
        self.scheduling = scheduling
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(
            repository: container.schedulingAdmin,
            scheduling: container.scheduling,
            workspaceId: workspaceId
        )
    }

    /// ⚠️ THE CONTEXT LOADS ONCE FOR THE SCREEN and the tabs load on demand. The timezone
    /// captions three of the four tables and the host builds the MCP address.
    func loadContext() async {
        if let me = try? await repository.me(workspaceId: workspaceId) {
            timezone = me.timezone.isEmpty ? "UTC" : me.timezone
        }
        if case let .success(status) = await scheduling.status(workspaceId: workspaceId) {
            publicHost = status.tenant?.publicHost
        }
        await loadCurrentTab()
    }

    func selectTab(_ next: String) async {
        tab = next
        await loadCurrentTab()
    }

    func loadCurrentTab() async {
        switch tab {
        case "keys" where keys == nil: await loadKeys()
        case "apps" where apps == nil: await loadApps()
        case "webhooks" where webhooks == nil: await loadWebhooks()
        default: break
        }
    }

    func reload() async {
        switch tab {
        case "keys": keys = nil
        case "apps": apps = nil
        default:
            webhooks = nil
            deliveries = [:]
        }
        await loadCurrentTab()
    }

    private func loadKeys() async {
        keys = .loading
        do {
            keys = try await .ready(repository.apiKeys(workspaceId: workspaceId))
        } catch {
            keys = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadApps() async {
        apps = .loading
        do {
            apps = try await .ready(repository.oauthConnections(workspaceId: workspaceId))
        } catch {
            apps = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadWebhooks() async {
        webhooks = .loading
        do {
            webhooks = try await .ready(repository.webhooks(workspaceId: workspaceId))
        } catch {
            webhooks = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⛔ `webhooks.deliveries` IS `viewer`-LEVEL, WHICH IS WHY THIS READ IS OFFERED TO
    /// EVERYBODY WHILE THE EDIT AND DELETE BESIDE IT ARE NOT. The web makes the same
    /// split: "Deliveries" is always present in the actions menu and the other two are
    /// manager-only.
    func loadDeliveries(for webhookId: String) async {
        deliveries[webhookId] = .loading
        do {
            deliveries[webhookId] = try await .ready(repository.webhookDeliveries(
                workspaceId: workspaceId,
                webhookId: webhookId
            ))
        } catch {
            deliveries[webhookId] = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    var mcpUrl: String {
        SchedulingDeveloperFormat.mcpUrl(publicHost: publicHost ?? "")
    }

    // MARK: - Writes

    // ⛔ `apiKeys.create` AND `webhooks.create` EACH ANSWER A SECRET EXACTLY ONCE, and
    // that response is the only place it will ever exist. It must be presented, copyable,
    // and then dropped — never stored on this model, never written to a log, never put
    // into the Claude Desktop snippet (which carries
    // ``SchedulingDeveloperFormat/mcpKeyPlaceholder`` for that reason).
    //
    // ⛔ AND `webhooks.create` HAS A FIELD-SELECTION TRAP: `fields: nil` means the FORK's
    // default set, not "none", and that default is not the list the console offers — it
    // omits `event_type_name`, `host_name` and `host_email`. A webhook created with nil
    // therefore arrives missing values the form never offered to remove. Send the list
    // explicitly. ⚠️ `SchedulingDeveloperFormat.isPersonalDataField(_:)` is what lets
    // the form mark the six that carry a person's details off the platform.
}

struct SchedulingDeveloperView: View {
    @State private var model: SchedulingDeveloperModel
    @State private var openWebhook: String?

    /// ⛔ THE THREE DESTRUCTIVE MODELS ARE OWNED BY THE SCREEN AND BUILT IN `init`,
    /// NOT PER ROW. Each carries the row it is asking about, and each row's button
    /// presents its dialog only while it is that row (see
    /// ``SchedulingWriteConfirmationsC``); a per-row model would have no one place that
    /// knows a prompt is already up. ⚠️ Each takes `onChanged` from the read model, which is
    /// what re-reads the tab behind the prompt — without it a revoked key stays on screen.
    @State private var keyRevoke: SchedulingAPIKeyRevokeModel
    @State private var appRevoke: SchedulingOAuthConnectionRevokeModel
    @State private var webhookDelete: SchedulingWebhookDeleteModel

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let role: WorkspaceRole?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        let admin = container.schedulingAdmin
        self.admin = admin
        let model = SchedulingDeveloperModel(container: container, workspaceId: workspaceId)
        _model = State(initialValue: model)
        let refresh: () -> Void = { Task { await model.reload() } }
        _keyRevoke = State(initialValue: SchedulingAPIKeyRevokeModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: refresh
        ))
        _appRevoke = State(initialValue: SchedulingOAuthConnectionRevokeModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: refresh
        ))
        _webhookDelete = State(initialValue: SchedulingWebhookDeleteModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: refresh
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ `webhooks.deliveries` IS `viewer`-LEVEL AND EVERY OTHER WRITE ON THIS SCREEN
    /// IS `client`-LEVEL, which is the split the web makes too: "Deliveries" is always
    /// there and the create, revoke, edit and delete beside it are not.
    private var canManage: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.developer),
            identifier: A11yID.Scheduling.developerRoot,
            onRefresh: { await model.reload() },
            content: {
                Text(SchedulingCopy.timesIn(model.timezone))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                tabs
                content
            }
        )
        .task { await model.loadContext() }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DistrictSpacing.tight) {
                ForEach(
                    Array(SchedulingDeveloperFormat.tabIds.enumerated()),
                    id: \.offset
                ) { index, id in
                    Button(SchedulingDeveloperFormat.tabLabels[index]) {
                        Task { await model.selectTab(id) }
                    }
                    .buttonStyle(DistrictButtonStyle(
                        variant: model.tab == id ? .primary : .secondary
                    ))
                    .accessibilityIdentifier(A11yID.Scheduling.developerTab(id))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case "keys": keysTab
        case "apps": appsTab
        default: webhooksTab
        }
    }
}

/// The three tabs.
///
/// ⛔ AN `extension` IN THIS FILE RATHER THAN A FILE OF ITS OWN, AND THE PAIR OF CEILINGS
/// IS WHY. `swiftlint --strict` errors at `type_body_length` 300, which the view's body
/// crosses with the writes wired in — and `private` is FILE-scoped, so a second file
/// makes every member these read inaccessible. The split point is the tab switch.
extension SchedulingDeveloperView {
    private var keysTab: some View {
        SchedulingCard(eyebrow: SchedulingCopy.keysEyebrow) {
            Text(SchedulingCopy.keysSubtitle)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            switch model.keys {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.keysEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.id) { key in
                        keyRow(key)
                    }
                }
                if let failure = keyRevoke.failure {
                    SchedulingWriteFailureLineC(failure: failure, onDismiss: keyRevoke.dismissFailure)
                }
                if canManage {
                    SchedulingAPIKeyCreateButton(
                        admin: admin,
                        workspaceId: workspaceId,
                        onChanged: reload
                    )
                }
            }
        }
    }

    private func keyRow(_ key: SchedulingAPIKey) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingReadOnlyRow(
                label: key.name,
                // ⚠️ "Never" RATHER THAN THE EM DASH. The absent marker is per
                // column on purpose; a key that has never been used is a
                // different statement from a missing value.
                value: SchedulingCopy.keyValue(
                    created: SchedulingDeveloperFormat.stamp(
                        key.createdAt,
                        timezone: model.timezone
                    ),
                    lastUsed: SchedulingDeveloperFormat.stamp(
                        key.lastUsedAt,
                        timezone: model.timezone,
                        absent: SchedulingCopy.never
                    )
                )
            )
            if canManage {
                SchedulingAPIKeyRevokeButton(model: keyRevoke, key: key)
            }
        }
    }

    @ViewBuilder
    private var appsTab: some View {
        SchedulingCard(eyebrow: SchedulingCopy.mcpEyebrow) {
            // ⛔ THE HEADER VALUE IS THE PLACEHOLDER AND NEVER A REAL KEY. See the ⛔ on
            // ``SchedulingDeveloperFormat/mcpKeyPlaceholder``.
            if model.mcpUrl.isEmpty {
                Text(SchedulingCopy.mcpNoHost)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            } else {
                SchedulingReadOnlyRow(label: SchedulingCopy.mcpUrlLabel, value: model.mcpUrl)
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.mcpAuthLabel,
                    value: "Bearer \(SchedulingDeveloperFormat.mcpKeyPlaceholder)"
                )
            }
            Text(SchedulingCopy.mcpNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
        SchedulingCard(eyebrow: SchedulingCopy.appsEyebrow) {
            Text(SchedulingCopy.appsSubtitle)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            switch model.apps {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.appsEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.id) { app in
                        appRow(app)
                    }
                }
                if let failure = appRevoke.failure {
                    SchedulingWriteFailureLineC(failure: failure, onDismiss: appRevoke.dismissFailure)
                }
            }
        }
    }

    private func appRow(_ app: SchedulingOAuthConnection) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingReadOnlyRow(
                label: app.clientName,
                value: SchedulingDeveloperFormat.stamp(
                    app.lastUsedAt,
                    timezone: model.timezone,
                    absent: SchedulingCopy.never
                )
            )
            if canManage {
                SchedulingOAuthConnectionRevokeButton(model: appRevoke, connection: app)
            }
        }
    }

    private var webhooksTab: some View {
        SchedulingCard(eyebrow: SchedulingCopy.webhooksEyebrow) {
            Text(SchedulingCopy.webhooksSubtitle)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            switch model.webhooks {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.webhooksEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.id) { hook in
                        webhookRow(hook)
                    }
                }
                if let failure = webhookDelete.failure {
                    SchedulingWriteFailureLineC(
                        failure: failure,
                        onDismiss: webhookDelete.dismissFailure
                    )
                }
                if canManage {
                    SchedulingWebhookCreateButton(
                        admin: admin,
                        workspaceId: workspaceId,
                        onChanged: reload
                    )
                }
            }
        }
    }

    private func webhookRow(_ hook: SchedulingWebhook) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingReadOnlyRow(
                label: hook.url,
                value: SchedulingCopy.onOff(hook.isActive != false)
            )
            Text(hook.events.joined(separator: ", "))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(SchedulingCopy.deliveries) { openDeliveries(hook.id) }
                .buttonStyle(.districtGhost)
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingDeveloperWrites.webhookDeliveries, hook.id)
                )
            if canManage {
                SchedulingWebhookRowActions(
                    admin: admin,
                    workspaceId: workspaceId,
                    webhook: hook,
                    deleteModel: webhookDelete,
                    onChanged: reload
                )
            }
            deliveries(hook.id)
        }
    }

    @ViewBuilder
    private func deliveries(_ id: String) -> some View {
        if openWebhook == id {
            switch model.deliveries[id] {
            case .loading, .none:
                SkeletonBlock(height: 32)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.deliveriesEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.id) { delivery in
                        SchedulingReadOnlyRow(
                            label: SchedulingDeveloperFormat.stamp(
                                delivery.lastAttemptedAt,
                                timezone: model.timezone,
                                absent: SchedulingCopy.notTriedYet
                            ),
                            value: SchedulingDeveloperFormat.deliveryOutcome(
                                status: delivery.status,
                                responseStatus: delivery.responseStatus
                            ).label
                        )
                        .accessibilityIdentifier(
                            A11yID.SchedulingDeveloperWrites.delivery(delivery.id)
                        )
                    }
                }
            }
        }
    }

    private func openDeliveries(_ id: String) {
        openWebhook = openWebhook == id ? nil : id
        guard openWebhook == id, model.deliveries[id] == nil else { return }
        Task { await model.loadDeliveries(for: id) }
    }

    private func reload() {
        Task { await model.reload() }
    }
}
