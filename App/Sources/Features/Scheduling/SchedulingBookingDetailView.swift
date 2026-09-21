import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// One booking: what the booker answered, what the meeting produced.
///
/// ⛔ THREE READS, AND TWO OF THEM CAN BE REFUSED FOR A REASON THAT IS NOT A FAULT. Notes
/// and transcripts live behind recording storage, which is not enabled in every region;
/// that refusal arrives as a **424** and means "this region does not store recordings",
/// not "something broke". ``SchedulingBookingFormat/mediaUnavailableSentence(status:fallback:)``
/// is what says so, and the generic sentence would send an operator hunting for an outage.
///
/// ⚠️ THE 424 CANNOT BE SEEN FROM `SchedulingAdminError`, WHICH HAS NO STATUS. It arrives
/// as ``SchedulingAdminFailureCode/unknown``, so the screen cannot distinguish it from a
/// genuine contract failure and says the softer of the two sentences for both. That is a
/// deliberate trade recorded rather than hidden: on a surface where storage-off is the
/// common case and a shape mismatch is the rare one, naming the common cause is the more
/// useful wrong answer, and neither offers a retry.
@MainActor
@Observable
final class SchedulingBookingDetailModel {
    private(set) var answers: SchedulingSectionState<[SchedulingBookingAnswer]> = .loading
    private(set) var notes: SchedulingSectionState<SchedulingBookingNotes> = .loading
    private(set) var transcript: SchedulingSectionState<SchedulingBookingTranscript> = .loading

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
        notes = .loading
        transcript = .loading
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadAnswers() }
            group.addTask { await self.loadNotes() }
            group.addTask { await self.loadTranscript() }
        }
    }

    private func loadAnswers() async {
        do {
            answers = try await .ready(repository.bookingAnswers(
                workspaceId: workspaceId,
                bookingId: bookingId
            ))
        } catch {
            answers = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadNotes() async {
        do {
            notes = try await .ready(repository.bookingNotes(
                workspaceId: workspaceId,
                bookingId: bookingId
            ))
        } catch {
            notes = .failed(Self.mediaFailure(for: error))
        }
    }

    private func loadTranscript() async {
        do {
            transcript = try await .ready(repository.bookingTranscript(
                workspaceId: workspaceId,
                bookingId: bookingId
            ))
        } catch {
            transcript = .failed(Self.mediaFailure(for: error))
        }
    }

    /// ⛔ THE `unknown` CODE IS RE-WORDED FOR MEDIA AND NOTHING ELSE IS TOUCHED. A refusal
    /// this surface classified as unavailable, forbidden or not-ready keeps its own
    /// sentence, because each of those is a true and different statement; only the generic
    /// "That did not save. Try again." is replaced, and it is replaced because on THESE
    /// two reads its most likely cause is a region with no recording storage. See the ⚠️
    /// on this type for why the status itself is not visible.
    private static func mediaFailure(for error: any Error) -> FailureText {
        let text = SchedulingFailureCopy.text(forAny: error)
        guard text.message == SchedulingFailureCopy.unknown else { return text }
        return FailureText(message: SchedulingCopy.mediaUnavailable, action: .none)
    }

    /// The notes, as blocks.
    ///
    /// ⛔ PARSED WITH THE **BOOKING** PARSER, NOT THE RECORDING ONE. The two are not
    /// interchangeable: this one strips inline markup and distinguishes ordered lists, and
    /// the recordings screen's does neither. Using the wrong one here would render
    /// `**bold**` with its asterisks, which is what the browser does on the OTHER screen.
    var noteBlocks: [SchedulingNotesBlock] {
        guard let content = notes.value?.content, !content.isEmpty else { return [] }
        return SchedulingMarkdown.bookingBlocks(content)
    }

    // MARK: - Writes

    // ⛔ `bookings.notes.regenerate` IS THE ONE WRITE ON THIS SCREEN AND IT IS NOT CHEAP.
    // It re-runs a model over the transcript, so it must be a deliberate press with a
    // disabled state — and `client`-level, which a viewer does not clear. ⚠️ The cancel,
    // reschedule and reassign actions belong on the LIST beside each row rather than
    // here; see the ⛔ on ``SchedulingBookingsModel``.
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
                notes
                transcript
            }
        )
        .task { await model.load() }
    }

    /// The two writes this screen can address by id alone.
    ///
    /// ⛔ THE RESCHEDULE AND THE REASSIGN ARE NOT HERE, AND IT IS A MISSING READ
    /// RATHER THAN A DECISION ABOUT PLACEMENT. `bookings.reschedule` needs the event
    /// type's SLUG to ask for slots and `bookings.reassign` needs the current host to
    /// leave out of the candidates; neither is carried by the three ops this screen
    /// makes, and there is no op that fetches ONE booking. Both live on the list,
    /// where `bookings.list` has already answered them — see
    /// ``SchedulingBookingWriteBar``.
    ///
    /// ⚠️ `client`-LEVEL, BOTH. A viewer reads the answers, the notes and the
    /// transcript and is offered neither control.
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
                SchedulingBookingNotesEntry(
                    admin: admin,
                    workspaceId: workspaceId,
                    bookingId: model.bookingId,
                    onQueued: reload
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

    private var notes: some View {
        SchedulingCard(eyebrow: SchedulingCopy.notesEyebrow) {
            switch model.notes {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            case let .ready(value):
                if !value.exists || model.noteBlocks.isEmpty {
                    Text(SchedulingCopy.noNotes)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    SchedulingNotesBlocks(blocks: model.noteBlocks)
                }
            }
        }
    }

    private var transcript: some View {
        SchedulingCard(eyebrow: SchedulingCopy.transcriptEyebrow) {
            switch model.transcript {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            case let .ready(value):
                if let text = value.text, value.exists, !text.isEmpty {
                    // ⛔ PLAIN `Text`, NEVER AN ATTRIBUTED OR MARKDOWN RENDER. A
                    // transcript is a customer's own words, which is untrusted input; the
                    // safety here comes from the SINK, and `Text` draws a string and can
                    // be talked into nothing else. See the ⛔ on ``SchedulingNotesBlock``.
                    Text(text)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(SchedulingCopy.noTranscript)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                }
            }
        }
    }
}

/// Notes blocks, rendered as text.
///
/// ⛔ SHARED BY THE BOOKING DETAIL AND THE RECORDINGS SCREEN EVEN THOUGH THEY PARSE WITH
/// DIFFERENT PARSERS. The block SHAPE is common and the rendering is the same; what
/// differs is how the markdown became blocks, which is each screen's own decision. Sharing
/// the renderer is safe precisely because it takes blocks rather than a string.
struct SchedulingNotesBlocks: View {
    let blocks: [SchedulingNotesBlock]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    Text(text)
                        .font(DistrictType.titleSmall)
                        .foregroundStyle(colors.foreground)
                case let .paragraph(text):
                    Text(text)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.foreground)
                case let .list(items, ordered):
                    VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            // ⚠️ THE MARKER IS REBUILT RATHER THAN CARRIED. An ordered
                            // list numbers from one regardless of what the source wrote,
                            // which is what a renderer does; the source's own numbers were
                            // consumed by the parser.
                            Text(ordered ? "\(index + 1). \(item)" : "• \(item)")
                                .font(DistrictType.bodySmall)
                                .foregroundStyle(colors.foreground)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
