import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// One event type, read three ways: the row itself, its hosts, and its questions.
///
/// ⛔ AN INSPECTOR, NOT AN EDITOR, AND THE DISTINCTION IS THE STAGE RATHER THAN THE
/// SURFACE. `eventTypes.patch`, `eventTypes.hosts.put` and the three
/// `eventTypes.questions.*` operations all exist and are all `client`-level; none of them
/// is called here. The screen says what the event type IS so that the write stage has
/// somewhere to put the form, and so an operator can answer "how long is the intro call"
/// without leaving the app.
///
/// ⚠️ THREE INDEPENDENT READS, THREE INDEPENDENT FAILURES. The hosts and questions reads
/// are separate ops from the event type itself, so one of them failing must not hide the
/// row that did load — the same rule the overview register states, for the same reason.
@MainActor
@Observable
final class SchedulingEventTypeModel {
    private(set) var eventType: SchedulingSectionState<SchedulingEventType> = .loading
    private(set) var hosts: SchedulingSectionState<[SchedulingHost]> = .loading
    private(set) var questions: SchedulingSectionState<[SchedulingQuestion]> = .loading

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    let slug: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(repository: SchedulingAdminRepository, workspaceId: String, slug: String) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.slug = slug
    }

    convenience init(container: AppContainer, workspaceId: String, slug: String) {
        self.init(
            repository: container.schedulingAdmin,
            workspaceId: workspaceId,
            slug: slug
        )
    }

    func load() async {
        eventType = .loading
        hosts = .loading
        questions = .loading
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadEventType() }
            group.addTask { await self.loadHosts() }
            group.addTask { await self.loadQuestions() }
        }
    }

    private func loadEventType() async {
        do {
            eventType = try await .ready(repository.eventType(workspaceId: workspaceId, slug: slug))
        } catch {
            eventType = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadHosts() async {
        do {
            hosts = try await .ready(repository.eventTypeHosts(workspaceId: workspaceId, slug: slug))
        } catch {
            hosts = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadQuestions() async {
        do {
            questions = try await .ready(
                repository.eventTypeQuestions(workspaceId: workspaceId, slug: slug)
            )
        } catch {
            questions = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// The facts worth stating, as `label: value` pairs.
    ///
    /// ⚠️ BUILT AS A LIST RATHER THAN WRITTEN OUT IN THE VIEW, so that a field whose value
    /// is absent can be DROPPED rather than rendered as "Not set" beside eight real ones.
    /// The web shows every column because a table has to; a phone does not.
    var facts: [(label: String, value: String)] {
        guard let item = eventType.value else { return [] }
        var rows: [(String, String)] = [
            (SchedulingCopy.factDuration, SchedulingBookingFormat.minutesLabel(item.durationMinutes)),
        ]
        if let interval = item.slotIntervalMinutes {
            rows.append((SchedulingCopy.factInterval, SchedulingBookingFormat.minutesLabel(interval)))
        }
        rows.append((SchedulingCopy.factLocation, SchedulingCopy.locationLabel(item.locationType)))
        if let value = item.locationValue, !value.isEmpty {
            rows.append((SchedulingCopy.factLocationValue, value))
        }
        if let notice = item.minNoticeMinutes {
            rows.append((SchedulingCopy.factNotice, SchedulingBookingFormat.minutesLabel(notice)))
        }
        if let days = item.maxFutureDays {
            rows.append((SchedulingCopy.factHorizon, SchedulingCopy.daysLabel(days)))
        }
        if let before = item.bufferBeforeMinutes, before > 0 {
            rows.append((SchedulingCopy.factBufferBefore, SchedulingBookingFormat.minutesLabel(before)))
        }
        if let after = item.bufferAfterMinutes, after > 0 {
            rows.append((SchedulingCopy.factBufferAfter, SchedulingBookingFormat.minutesLabel(after)))
        }
        rows.append((SchedulingCopy.factState, SchedulingEventTypesModel.stateLabel(item).label))
        return rows.map { (label: $0.0, value: $0.1) }
    }

    // MARK: - Writes

    // ⛔ FOUR WRITE FAMILIES BELONG ON THIS SCREEN AND NONE IS WIRED: `eventTypes.patch`
    // (every field above), `eventTypes.hosts.put` (a WHOLESALE REPLACE of the host list —
    // it must be built from a list this screen has actually loaded, or it deletes the
    // hosts it never saw), the three `eventTypes.questions.*` operations, and
    // `eventTypes.testEmail`.
    //
    // ⛔ THE HOSTS PUT IS THE DANGEROUS ONE AND THE SEAM IS DELIBERATE: ``hosts`` is a
    // `SchedulingSectionState`, so a form cannot be rendered from a FAILED read — which
    // is exactly the shape `SettingsLoadFailureView` exists for on the workspace-settings
    // surface, where three saves replace their stored value wholesale. Do not let an
    // editor open on `.failed` or `.loading`.
}

struct SchedulingEventTypeView: View {
    @State private var model: SchedulingEventTypeModel

    private let workspaceId: String
    private let role: WorkspaceRole?
    private let admin: SchedulingAdminRepository

    @Environment(\.colorScheme) private var colorScheme

    /// ⚠️ THE POP AFTER A DELETE. The route addresses this screen BY SLUG, so once
    /// the row is gone there is nothing here to re-read — staying would show a
    /// refusal the operator caused on purpose.
    @Environment(\.dismiss) private var dismiss

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, slug: String) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingEventTypeModel(
            container: container,
            workspaceId: workspaceId,
            slug: slug
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: title,
            identifier: A11yID.Scheduling.eventTypeDetailRoot,
            onRefresh: { await model.load() },
            content: {
                details
                writes
                hosts
                questions
            }
        )
        .task { await model.load() }
    }

    /// ⚠️ THE EVENT TYPE'S OWN NAME ONCE IT LOADS, AND ITS SLUG BEFORE THAT. The slug is
    /// what the route carried, so it is the one true thing available on first render; a
    /// generic "Event type" would tell somebody who tapped a row nothing about which one
    /// they are looking at while it loads.
    private var title: String {
        model.eventType.value?.name ?? model.slug
    }

    /// ⛔ BUILT FROM THE LOADED ROW AND FROM NOTHING ELSE. `eventTypes.hosts.put` is
    /// a wholesale replace, so an editor opened over a `.failed` or `.loading` read
    /// would save a list it never saw — the trap the read model's own header names.
    /// `value` is nil in both those states, so the bar is simply absent.
    ///
    /// ⚠️ `client`-LEVEL, ALL FOUR. The form, the state actions, the hosts and the
    /// questions are the same bar as the web's, and a viewer gets the inspector
    /// without them.
    @ViewBuilder
    private var writes: some View {
        if WorkspaceRole.allowsMutation(role), let item = model.eventType.value {
            SchedulingEventTypeWriteBar(
                admin: admin,
                workspaceId: workspaceId,
                eventType: item,
                onChanged: reload,
                onDeleted: { dismiss() }
            )
        }
    }

    private var details: some View {
        SchedulingCard(eyebrow: SchedulingCopy.eventTypeDetailsEyebrow) {
            switch model.eventType {
            case .loading:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(item):
                VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(DistrictType.bodySmall)
                            .foregroundStyle(colors.mutedForeground)
                    }
                    ForEach(model.facts, id: \.label) { fact in
                        SchedulingReadOnlyRow(label: fact.label, value: fact.value)
                    }
                }
            }
        }
    }

    private var hosts: some View {
        SchedulingCard(eyebrow: SchedulingCopy.eventTypeHostsEyebrow) {
            switch model.hosts {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.eventTypeNoHosts)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.userId) { host in
                        SchedulingReadOnlyRow(
                            label: host.name.isEmpty ? host.email : host.name,
                            value: SchedulingCopy.hostValue(role: host.role, archived: host.archived)
                        )
                    }
                }
            }
        }
    }

    private var questions: some View {
        SchedulingCard(eyebrow: SchedulingCopy.eventTypeQuestionsEyebrow) {
            switch model.questions {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.eventTypeNoQuestions)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    // ⚠️ SORTED BY `position`, WHICH IS THE ORDER THE BOOKER SEES. The op
                    // does not promise one, and a questionnaire read out of order is a
                    // different form.
                    ForEach(rows.sorted { $0.position < $1.position }, id: \.id) { question in
                        SchedulingReadOnlyRow(
                            label: question.label,
                            value: SchedulingCopy.questionValue(
                                type: question.type,
                                required: question.required
                            )
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
