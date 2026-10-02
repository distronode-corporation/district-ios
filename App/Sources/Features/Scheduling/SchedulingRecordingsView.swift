import AVKit
import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// Recordings of booked meetings, and who agreed to be recorded.
///
/// ⛔ THE ONE SCREEN ON THIS SURFACE WHOSE ROLE IS LOAD-BEARING, AND THE ASYMMETRY IS THE
/// SERVER'S. `recordings.list` is `viewer`-level and the DOWNLOAD beside it is
/// `agency`/`client`: a viewer may see that a recording exists and may not take a copy of
/// a customer conversation away. So the rows are drawn for everybody and the download
/// affordance is HIDDEN rather than disabled for a viewer — a greyed button would tell
/// them a copy is available and that they are shut out of it, which is a disclosure the
/// row need not make.
///
/// ⛔ AND THE CONTROL IS ALSO GATED ON `hasFile`. A recording with no object answers a
/// **404 with a JSON body** rather than a redirect, so it falls through the redirect check
/// into the ordinary status mapping and arrives as a generic unknown failure — which reads
/// as a broken app rather than as a recording that was never stored.
@MainActor
@Observable
final class SchedulingRecordingsModel {
    private(set) var state: SchedulingSectionState<[SchedulingRecording]> = .loading
    private(set) var storage: SchedulingStorageSettings?
    private(set) var timezone = "UTC"

    /// The consent rows for whichever recording is open, keyed by its id.
    ///
    /// ⚠️ READ ON DEMAND RATHER THAN PER ROW. One consent read per recording on entry
    /// would be a request per row for evidence almost nobody opens; the web does the same.
    private(set) var consents: [String: SchedulingSectionState<[SchedulingRecordingConsent]>] = [:]

    /// The recordings whose playable URL is being minted right now.
    ///
    /// ⚠️ PER ID, SO A SECOND PRESS ON THE SAME ROW IS DROPPED rather than minting a
    /// second presigned URL and stacking a second player, while another row stays
    /// pressable.
    private(set) var minting: Set<String> = []

    /// Why the last Play on a row did nothing, keyed by recording id.
    ///
    /// ⛔ A FAILED MINT IS SAID ON THE ROW. Storage switched off or a dropped connection
    /// used to leave the button doing nothing at all, which reads as a broken app.
    private(set) var playFailures: [String: FailureText] = [:]

    private let repository: SchedulingAdminRepository
    private let media: SchedulingAdminMediaRepository
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
        media: SchedulingAdminMediaRepository,
        workspaceId: String
    ) {
        self.repository = repository
        self.media = media
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(
            repository: container.schedulingAdmin,
            media: container.schedulingAdminMedia,
            workspaceId: workspaceId
        )
    }

    /// ⚠️ THE THREE READS ARE INDEPENDENT, SO THEY ARE SENT TOGETHER, and applied in
    /// this order so the list never draws before the zone and the storage notice it is
    /// rendered with.
    func load() async {
        state = .loading
        consents = [:]
        playFailures = [:]
        async let profile = try? repository.me(workspaceId: workspaceId)
        // ⚠️ THE STORAGE READ IS OPTIONAL. It only decides whether the "no storage" notice
        // is drawn; failing the screen over it would hide recordings that already exist.
        async let storageAnswer = try? repository.storageSettings(workspaceId: workspaceId)
        async let listed = repository.recordings(workspaceId: workspaceId)
        if let me = await profile {
            timezone = me.displayTimezone
        }
        storage = await storageAnswer
        do {
            state = try await .ready(listed)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    func loadConsents(for recordingId: String) async {
        consents[recordingId] = .loading
        do {
            consents[recordingId] = try await .ready(repository.recordingConsents(
                workspaceId: workspaceId,
                recordingId: recordingId
            ))
        } catch {
            consents[recordingId] = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// The presigned URL for one recording, minted per press.
    ///
    /// ⛔ THE URL IS ANSWERED AND NEVER STORED. It is a presigned object address with a
    /// lifetime of its own; keeping it on the model would leave a live capability in
    /// memory long after the sheet closed and would make a second press cheap to serve
    /// from a value that may already have expired. Same rule as the hub's hand-off.
    ///
    /// ⚠️ nil MEANS "nothing to play": either a press is already minting this id, or the
    /// mint failed and the reason is in ``playFailures``.
    func downloadURL(for recordingId: String) async -> URL? {
        guard !minting.contains(recordingId) else { return nil }
        minting.insert(recordingId)
        defer { minting.remove(recordingId) }
        playFailures[recordingId] = nil
        do {
            let raw = try await media.recordingDownloadURL(
                workspaceId: workspaceId,
                recordingId: recordingId
            )
            if let url = URL(string: raw) {
                return url
            }
            playFailures[recordingId] = FailureText(message: SchedulingCopy.recordingPlayFailed, action: .none)
        } catch {
            playFailures[recordingId] = Self.playFailure(error)
        }
        return nil
    }

    /// The shared scheduling mapping, except where it would say "That did not save".
    ///
    /// ⚠️ PLAY IS A READ, SO THE CATCH-ALL SENTENCE IS THE PLAYBACK ONE. Every specific
    /// refusal (offline, unavailable, forbidden, not ready) keeps its shared sentence and
    /// offer; only the `unknown` wording, which describes a write, is replaced.
    static func playFailure(_ error: any Error) -> FailureText {
        let text = SchedulingFailureCopy.text(forAny: error)
        guard text.message == SchedulingFailureCopy.unknown else { return text }
        return FailureText(message: SchedulingCopy.recordingPlayFailed, action: text.action)
    }

    /// ⛔ STORAGE OFF IS A PRODUCT STATE, NOT A FAULT, and it changes what the screen can
    /// offer: nothing can be downloaded and nothing new will be recorded. Existing rows
    /// are still listed, because they exist.
    var storageMissing: Bool {
        storage?.recordingsStorageReady == false
    }

    struct Row: Identifiable {
        let id: String
        let when: String
        let who: String
        let duration: String
        let file: String
        let state: SchedulingStatusLabel
        let canDownload: Bool
    }

    /// - Parameter mayDownload: the ROLE's answer, computed once by the view.
    func rows(mayDownload: Bool) -> [Row] {
        guard let items = state.value else { return [] }
        return items.map { item in
            Row(
                id: item.id,
                when: SchedulingRecordingFormat.recordedWhen(
                    createdAt: item.createdAt,
                    timezone: timezone
                ) ?? SchedulingCopy.unknownTime,
                who: SchedulingRecordingFormat.recordingWho(item),
                duration: SchedulingRecordingFormat.recordingDuration(item.durationS),
                file: SchedulingRecordingFormat.fileLabel(item.hasFile),
                state: SchedulingRecordingFormat.recordingState(item.status),
                // ⛔ THREE CONDITIONS, ALL REQUIRED. The role clears the server's bar, the
                // file has to exist or the request 404s, and storage has to be on or the
                // object cannot be served at all.
                canDownload: mayDownload && item.hasFile == true && !storageMissing
            )
        }
    }

    // MARK: - Writes

    // ⛔ `recordings.delete` AND `recordings.deleteAll` ARE THE TWO WRITES AND THE SECOND
    // IS THE MOST DESTRUCTIVE OPERATION ON THIS ENTIRE SURFACE. It removes every recording
    // the tenancy holds; it needs a typed confirmation rather than a tap, and it must READ
    // ``SchedulingRecordingsDeleted/failed`` and say so — a partial failure is a 200, and
    // "all deleted" over a non-zero `failed` is the worst available wrong answer on a
    // screen whose whole purpose is data removal.
}

struct SchedulingRecordingsView: View {
    @State private var model: SchedulingRecordingsModel
    @State private var consentFor: String?
    @State private var playing: SchedulingRecordingPlayback?

    /// ⛔ THE ROLE IS READ HERE AND NOWHERE ELSE ON THIS SURFACE. See the ⛔ on
    /// ``SchedulingRecordingsModel``.
    private let role: WorkspaceRole?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.role = role
        self.workspaceId = workspaceId
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingRecordingsModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ `allowsMutation` FAILS CLOSED ON A ROLE THAT DID NOT PARSE, which is the correct
    /// direction for a control that takes a customer conversation off the platform.
    private var mayDownload: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    /// ⛔ THE SAME BAR AS THE DOWNLOAD AND NOT THE SAME QUESTION, WHICH IS WHY IT IS
    /// SPELLED OUT RATHER THAN REUSED. `recordings.delete` and `recordings.deleteAll`
    /// are `client`-level like the download, but they are NOT gated on `hasFile` or on
    /// storage: a row whose object was never stored still has a database record, a
    /// transcript and meeting notes, and removing it is exactly what somebody clearing
    /// a tenancy is asking for.
    private var mayDelete: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.recordings),
            identifier: A11yID.Scheduling.recordingsRoot,
            onRefresh: { await model.load() },
            content: {
                notices
                content
            }
        )
        .task { await model.load() }
        .sheet(item: $playing) { target in
            // ⚠️ `AVPlayer` RATHER THAN A SHARE SHEET. A recording is a media object and
            // playing it in place is what an operator almost always wants; a share sheet
            // would offer to copy a customer conversation into any app on the device,
            // which is a wider action than the one the button names.
            VideoPlayer(player: AVPlayer(url: target.url))
                .ignoresSafeArea()
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(SchedulingCopy.timesIn(model.timezone))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if model.storageMissing {
                Text(SchedulingCopy.recordingsNoStorage)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: SchedulingCopy.loadingRecordings)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        case .ready:
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        let rows = model.rows(mayDownload: mayDownload)
        if rows.isEmpty {
            SchedulingEmptyState(
                title: SchedulingCopy.recordingsEmptyTitle,
                message: SchedulingCopy.recordingsEmptyBody
            )
        } else {
            deleteAll
            ForEach(rows) { row in
                SchedulingCard(eyebrow: row.when) {
                    SchedulingReadOnlyRow(label: SchedulingCopy.recordingWith, value: row.who)
                    SchedulingReadOnlyRow(
                        label: SchedulingCopy.recordingDuration,
                        value: row.duration
                    )
                    SchedulingReadOnlyRow(label: SchedulingCopy.recordingFile, value: row.file)
                    SchedulingReadOnlyRow(
                        label: SchedulingCopy.recordingState,
                        value: row.state.label
                    )
                    actions(row)
                    if let failure = model.playFailures[row.id] {
                        Text(failure.message)
                            .font(DistrictType.bodySmall)
                            .foregroundStyle(colors.destructive)
                    }
                    consent(row)
                }
            }
        }
    }

    private func actions(_ row: SchedulingRecordingsModel.Row) -> some View {
        HStack(spacing: DistrictSpacing.row) {
            // ⛔ ABSENT, NOT DISABLED, FOR A VIEWER. See the ⛔ on the model.
            if row.canDownload {
                Button(SchedulingCopy.recordingPlay) { play(row.id) }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.minting.contains(row.id))
                    .accessibilityIdentifier(A11yID.Scheduling.recordingDownload(row.id))
            }
            Button(SchedulingCopy.recordingConsent) { openConsent(row.id) }
                .buttonStyle(.districtGhost)
            if mayDelete {
                SchedulingRecordingDeleteEntry(
                    admin: admin,
                    workspaceId: workspaceId,
                    recordingId: row.id,
                    onDeleted: reload
                )
            }
        }
        .accessibilityIdentifier(A11yID.Scheduling.recordingRow(row.id))
    }

    /// ⛔ RENDERED IN PLACE RATHER THAN IN A MODAL, AND IT SAYS EXACTLY WHAT THE ROWS SAY.
    /// These are the evidence for a two-party-consent jurisdiction: `pending` is a real and
    /// common state — the guest left before the prompt resolved — and is never "granted by
    /// default". See the ⛔ on ``SchedulingRecordingFormat/consentDecision(_:)``.
    @ViewBuilder
    private func consent(_ row: SchedulingRecordingsModel.Row) -> some View {
        if consentFor == row.id {
            switch model.consents[row.id] {
            case .loading, .none:
                SkeletonBlock(height: 32)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.consentEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.identity) { entry in
                        SchedulingReadOnlyRow(
                            label: SchedulingRecordingFormat.consentWho(entry),
                            value: SchedulingRecordingFormat.consentDecision(entry.decision).label
                        )
                    }
                }
            }
        }
    }

    /// ⛔ ABSENT WHEN THERE IS NOTHING TO DELETE, AND THAT IS NOT COSMETIC. The bulk
    /// delete is the most destructive control on this surface; offering it over an
    /// empty list would put it on screen in the one state where pressing it can only
    /// be a mistake.
    @ViewBuilder
    private var deleteAll: some View {
        if mayDelete {
            SchedulingRecordingDeleteAllButton(
                admin: admin,
                workspaceId: workspaceId,
                onDeleted: reload
            )
        }
    }

    private func openConsent(_ id: String) {
        consentFor = consentFor == id ? nil : id
        guard consentFor == id, model.consents[id] == nil else { return }
        Task { await model.loadConsents(for: id) }
    }

    private func play(_ id: String) {
        Task {
            guard let url = await model.downloadURL(for: id) else { return }
            playing = SchedulingRecordingPlayback(url: url)
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}

/// One press of Play, carried to the player sheet.
///
/// ⛔ THE `id` IS A FRESH UUID AND NEVER THE URL, for the reason ``SchedulingHandOff``
/// states: identity has to change on every press so a second attempt re-presents rather
/// than being deduplicated against a presigned address that may already have expired — and
/// a URL used as an identity is a capability SwiftUI keeps a copy of.
struct SchedulingRecordingPlayback: Identifiable {
    let id = UUID()
    let url: URL
}
