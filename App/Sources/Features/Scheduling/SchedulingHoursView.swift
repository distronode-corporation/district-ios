import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// The weekly hours you are bookable, and the dates you are not.
///
/// ⛔ THE WEEK GRID IS READ-ONLY AND EVERY DAY IS DRAWN, INCLUDING THE EMPTY ONES. The web
/// renders seven labelled fields whatever is in them, and a grid that hid unbookable days
/// would make "I am not bookable on Wednesday" indistinguishable from "Wednesday did not
/// load" — which on a screen whose whole job is availability is the one confusion worth
/// spending seven rows to avoid.
@MainActor
@Observable
final class SchedulingHoursModel {
    private(set) var week: SchedulingSectionState<[[SchedulingHoursRange]]> = .loading
    private(set) var overrides: SchedulingSectionState<[SchedulingOverrideRow]> = .loading

    /// ⚠️ THE SUMMARY IS COMPUTED FROM THE RULES THE SAME WAY THE REGISTER COMPUTES IT, so
    /// the two screens cannot disagree about a sentence an operator sees on both.
    private(set) var summary: String?
    private(set) var timezone = "UTC"

    private let repository: SchedulingAdminRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(repository: SchedulingAdminRepository, workspaceId: String) {
        self.repository = repository
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(repository: container.schedulingAdmin, workspaceId: workspaceId)
    }

    func load() async {
        week = .loading
        overrides = .loading
        // ⚠️ THE PROFILE FIRST, BECAUSE THE OVERRIDE FILTER NEEDS "today" IN THE
        // OPERATOR'S ZONE. Asking in the device's zone drops a day off that has not
        // started yet for anybody east of it.
        await loadTimezone()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadRules() }
            group.addTask { await self.loadOverrides() }
        }
    }

    /// ⛔ A FAILED PROFILE READ IS DELIBERATELY SILENT, WHICH THE WEB ALSO DOES. The zone
    /// only decides which day "today" is and how the header is captioned; failing the
    /// screen over it would hide a correct week because a caption could not be written.
    private func loadTimezone() async {
        guard let me = try? await repository.me(workspaceId: workspaceId) else { return }
        timezone = me.displayTimezone
    }

    private func loadRules() async {
        do {
            let rules = try await repository.availabilityRules(workspaceId: workspaceId)
            summary = SchedulingOverviewSummary.summarizeWorkingHours(rules)
            week = .ready(SchedulingHoursFormat.weekFromRules(rules))
        } catch {
            week = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadOverrides() async {
        do {
            let rows = try await repository.availabilityOverrides(workspaceId: workspaceId)
            overrides = .ready(SchedulingHoursFormat.upcomingOverrides(
                rows,
                today: SchedulingHoursFormat.todayInZone(timezone)
            ))
        } catch {
            overrides = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    // MARK: - Writes

    // ⛔ THE EDITOR IS FOUR OPERATIONS AND A DIFF, AND THE DIFF IS THE DANGEROUS PART.
    // The web editor computes creates, patches and DELETES by comparing the edited
    // week against the rules it loaded; a diff taken against a week this model never
    // filled would delete every rule it did not see. ⚠️ ``week`` is a
    // `SchedulingSectionState` precisely so a form cannot open on `.failed` or
    // `.loading` — the same guard the workspace-settings surface needed for its three
    // wholesale-replace saves.
    //
    // ⚠️ THE PORT DELIBERATELY LEFT `dayErrors`, `diffWeek`, `copyToWeekdays`,
    // `overrideDraftError` and `overrideCreateParams` IN THE WEB. Each validates or
    // encodes an edit and each carries its own error sentence; bringing them over now
    // would be unreachable copy in front of a coverage gate. ``SchedulingHoursRange``
    // already carries the `ruleId` the diff keys on, so nothing here changes shape.
}

struct SchedulingHoursView: View {
    @State private var model: SchedulingHoursModel

    private let workspaceId: String
    private let role: WorkspaceRole?
    private let admin: SchedulingAdminRepository

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingHoursModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.hours),
            identifier: A11yID.Scheduling.hoursRoot,
            onRefresh: { await model.load() },
            content: {
                writes
                weekCard
                overridesCard
            }
        )
        .task { await model.load() }
    }

    /// ⛔ `client`-LEVEL, BOTH OF THEM. Every `availability.*` write is on the
    /// client side of ``SchedulingAdminOp/minRole``; a viewer reads the week and the
    /// overrides and is offered no editor, rather than a disabled one.
    ///
    /// ⚠️ THE BAR IS DRAWN WHATEVER THE TWO READS CAME TO, unlike the event type
    /// detail's. Both sheets re-read for themselves — the week editor's diff is
    /// taken against ITS OWN load, never against this screen's — so a failed read
    /// here says nothing about whether the editor can open.
    @ViewBuilder
    private var writes: some View {
        if WorkspaceRole.allowsMutation(role) {
            SchedulingHoursWriteBar(
                admin: admin,
                workspaceId: workspaceId,
                today: SchedulingHoursFormat.todayInZone(model.timezone),
                onChanged: reload
            )
        }
    }

    private var weekCard: some View {
        SchedulingCard(eyebrow: SchedulingCopy.sectionTitle(.hours)) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(model.summary ?? SchedulingCopy.hoursNoneAtAll)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                Text(SchedulingCopy.timesIn(model.timezone))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            switch model.week {
            case .loading:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(week):
                days(week)
            }
        }
    }

    /// ⛔ ALL SEVEN DAYS, MONDAY FIRST, WHATEVER IS IN THEM. See the ⛔ on
    /// ``SchedulingHoursModel``.
    private func days(_ week: [[SchedulingHoursRange]]) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            ForEach(Array(week.enumerated()), id: \.offset) { index, ranges in
                SchedulingReadOnlyRow(
                    label: SchedulingHoursFormat.weekDayNames[index],
                    value: SchedulingCopy.dayHours(ranges)
                )
            }
        }
    }

    private var overridesCard: some View {
        SchedulingCard(eyebrow: SchedulingCopy.overridesEyebrow) {
            Text(SchedulingCopy.overridesSubtitle)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            switch model.overrides {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.overridesEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.key) { row in
                        SchedulingReadOnlyRow(
                            label: SchedulingHoursFormat.formatOverrideDates(
                                start: row.start,
                                end: row.end
                            ),
                            value: SchedulingHoursFormat.overrideHours(row)
                        )
                    }
                }
            }
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}
