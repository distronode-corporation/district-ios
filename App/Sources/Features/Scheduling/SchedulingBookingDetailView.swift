import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// One booking: what the booker answered.
///
/// ⚠️ ONE READ SINCE 2026-10-03. The screen also read the meeting's notes and
/// transcript (`bookings.notes`, `bookings.transcript`) and offered to regenerate the
/// notes; the server retired all three with meeting recording, so they are gone here.
@MainActor
@Observable
final class SchedulingBookingDetailModel {
    private(set) var answers: SchedulingSectionState<[SchedulingBookingAnswer]> = .loading

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    let bookingId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(repository: SchedulingAdminRepository, workspaceId: String, bookingId: String) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.bookingId = bookingId
    }

    convenience init(container: AppContainer, workspaceId: String, bookingId: String) {
        self.init(
            repository: container.schedulingAdmin,
            workspaceId: workspaceId,
            bookingId: bookingId
        )
    }

    func load() async {
        answers = .loading
        do {
            answers = try await .ready(repository.bookingAnswers(
                workspaceId: workspaceId,
                bookingId: bookingId
            ))
        } catch {
            answers = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    // MARK: - Writes

    // ⚠️ The cancel is the one write on this screen. The reschedule and reassign
    // actions belong on the LIST beside each row rather than here; see the ⛔ on
    // ``SchedulingBookingsModel``.
}

struct SchedulingBookingDetailView: View {
    @State private var model: SchedulingBookingDetailModel

    private let workspaceId: String
    private let role: WorkspaceRole?
    private let admin: SchedulingAdminRepository

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, bookingId: String) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingBookingDetailModel(
            container: container,
            workspaceId: workspaceId,
            bookingId: bookingId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.booking(id: model.bookingId)),
            identifier: A11yID.Scheduling.bookingDetailRoot,
            onRefresh: { await model.load() },
            content: {
                writes
                answers
            }
        )
        .task { await model.load() }
    }

    /// The one write this screen can address by id alone.
    ///
    /// ⛔ THE RESCHEDULE AND THE REASSIGN ARE NOT HERE, AND IT IS A MISSING READ
    /// RATHER THAN A DECISION ABOUT PLACEMENT. `bookings.reschedule` needs the event
    /// type's SLUG to ask for slots and `bookings.reassign` needs the current host to
    /// leave out of the candidates; neither is carried by the op this screen makes,
    /// and there is no op that fetches ONE booking. Both live on the list, where
    /// `bookings.list` has already answered them — see
    /// ``SchedulingBookingWriteBar``.
    ///
    /// ⚠️ `client`-LEVEL. A viewer reads the answers and is offered no control.
    @ViewBuilder
    private var writes: some View {
        if WorkspaceRole.allowsMutation(role) {
            SchedulingCard(eyebrow: SchedulingWriteCopy.manage) {
                SchedulingBookingCancelButton(
                    admin: admin,
                    workspaceId: workspaceId,
                    bookingId: model.bookingId,
                    onChanged: reload
                )
            }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private var answers: some View {
        SchedulingCard(eyebrow: SchedulingCopy.answersEyebrow) {
            switch model.answers {
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
                    ForEach(rows, id: \.questionId) { answer in
                        // ⚠️ AN EM DASH FOR A BLANK ANSWER, matching the web. An empty
                        // value beside a label reads as a rendering fault.
                        SchedulingReadOnlyRow(
                            label: answer.label,
                            value: answer.value.isEmpty ? "—" : answer.value
                        )
                    }
                }
            }
        }
    }
}
