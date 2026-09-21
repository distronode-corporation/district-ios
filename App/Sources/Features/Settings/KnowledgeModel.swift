import DistrictData
import DistrictModel
import Foundation
import Observation

/// The document list's own load state.
///
/// ⚠️ SEPARATE FROM ``SettingsConfigState`` BECAUSE IT IS A DIFFERENT READ WITH A
/// DIFFERENT PAYLOAD. Reusing the config state would imply this screen hydrates from
/// `workspace/config`, which excludes a viewer — the opposite of this route — and the
/// whole point of that type is that it gates a wholesale-replace save. Nothing here
/// is one.
enum KnowledgeListState {
    case loading
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND MUST NOT RENDER AS A FAILURE. It is a
    /// workspace that has uploaded nothing, which is where every workspace starts.
    case ready([KnowledgeDocument])
    case failed(FailureText)
}

/// The knowledge screen's state machine. Ported from Android's `KnowledgeViewModel`.
///
/// ⛔ THE CREATE IS THE ONLY CALL IN THIS APP THAT SPENDS MODEL BUDGET ON THE
/// OPERATOR'S BEHALF, and the size of the spend is set by what they pasted: the route
/// chunks the content and embeds every chunk in ONE request. So there is no auto-retry
/// here, no re-send on a session change, and the button is disabled for the whole
/// round trip — a second tap on a slow network would pay twice for a duplicate
/// document. The 20/min-per-workspace limiter is Redis-backed and FAIL-OPEN, so it is
/// not a backstop for that.
///
/// ⛔ THE ROLE GATE IS A UX AFFORDANCE AND NEVER A SECURITY BOUNDARY, and it matters
/// here because a viewer genuinely reaches this screen: both reads admit one and all
/// the writes exclude one. ``canWrite`` is re-checked at every write's call site
/// rather than trusting that a control was not drawn — a state flag is not a call
/// site, and the server's `requireWorkspaceRole` is the actual boundary.
///
/// ⚠️ THE TWO READS RUN CONCURRENTLY AND FAIL INDEPENDENTLY. A workspace whose mode
/// read fails still gets its document list; the mode selector is withheld rather than
/// the screen failing, because a selector seeded from a guess is how a data-residency
/// setting gets changed by accident.
///
/// ⚠️ THE DELETE IS ABSENT BECAUSE ``KnowledgeRepository`` HAS NO METHOD FOR IT.
/// `deleteDocument` is in `UntypedEndpoints`; its fixture is gated and nothing decodes
/// it. Worth knowing before assuming this screen lost a button:
/// the route also answers `{success:true}` when nothing matched, so a client that gets
/// one has to re-read the list rather than drop the row.
@MainActor
@Observable
final class KnowledgeModel {
    private(set) var list: KnowledgeListState = .loading

    /// The stored mode, or nil when the mode read has not landed.
    ///
    /// ⚠️ NIL IS NOT `internal`. The route's own sanitiser defaults an unreadable
    /// STORED value to `internal`, but a FAILED READ is a different thing and must not
    /// render as a chosen mode — that would show "your questions stay in region" for a
    /// workspace that chose otherwise.
    private(set) var mode: String?

    /// ⛔ True when the mode READ failed. The selector is withheld; the document list
    /// still shows.
    private(set) var modeUnavailable = false

    private(set) var modeSave: SettingsSaveState = .idle
    private(set) var addSave: SettingsSaveState = .idle
    private(set) var addRejected = false

    /// ⚠️ WRITTEN THROUGH ``editTitle(_:)`` AND ``editContent(_:)`` RATHER THAN BOUND
    /// DIRECTLY, and not only so a keystroke can clear the rejection notice: `didSet`
    /// on a stored property of an `@Observable` type is not expressible, because the
    /// macro rewrites it into a computed property and Swift does not allow observers
    /// on one. Same shape ``DialerModel`` uses.
    private(set) var draftTitle = ""

    private(set) var draftContent = ""

    /// ⛔ False for `viewer` and for a role that did not parse. See the ⛔ on the type.
    let canWrite: Bool

    private let knowledge: KnowledgeRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        knowledge = container.knowledge
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    var documents: [KnowledgeDocument] {
        guard case let .ready(rows) = list else { return [] }
        return rows
    }

    private var busy: Bool {
        addSave.isSaving || modeSave.isSaving
    }

    /// ⛔ TITLE AND CONTENT ARE BOTH REQUIRED, WHICH IS THE ROUTE'S OWN RULE rather
    /// than a client invention: it answers 400 "Missing title or content" for a blank
    /// either. Checked here so an operator is not charged a round trip to be told.
    var canAdd: Bool {
        canWrite && !busy && !trimmed(draftTitle).isEmpty && !trimmed(draftContent).isEmpty
    }

    /// ⛔ GATED ON A SUCCESSFUL MODE READ AND ON THE ROLE. A viewer sees which mode is
    /// stored (the read admits them) and cannot select another; and nobody changes a
    /// mode this client never read, because that is an edit made against an unknown
    /// value.
    var canChangeMode: Bool {
        canWrite && !busy && !modeUnavailable && mode != nil
    }

    /// ⛔ THE ONE OPTION THAT SENDS THIS WORKSPACE'S QUESTIONS TO A THIRD PARTY, which
    /// is why the screen confirms it rather than treating it as a toggle.
    func isResidencyChange(to next: KnowledgeMode) -> Bool {
        next == .linked && mode != KnowledgeMode.linked.rawValue
    }

    /// ⚠️ A KEYSTROKE RETIRES THE REJECTION NOTICE. Leaving "a title and some text are
    /// both needed" up while someone is typing the title is a complaint about state
    /// that no longer exists.
    func editTitle(_ value: String) {
        draftTitle = value
        addRejected = false
    }

    func editContent(_ value: String) {
        draftContent = value
        addRejected = false
    }

    /// ⚠️ BOTH READS, CONCURRENTLY. Idempotent GETs, so replaying this is safe.
    ///
    /// ⛔ IT RETIRES THE BANNERS, AND ONLY ON A SUCCESSFUL DOCUMENT READ. Without that, a
    /// red upload refusal would survive a full reload and sit beside whatever the next
    /// write said. The success guard is the same one the persona and capability forms
    /// put on their drafts: on a failed read the banner may be the only record of what
    /// the last write did. ⚠️ Gated on the DOCUMENT read, not the mode read: they fail independently by
    /// design, and a mode read that failed says nothing about an upload that succeeded.
    func load() async {
        list = .loading
        async let documents = knowledge.documents(workspaceId: workspaceId)
        async let storedMode = knowledge.mode(workspaceId: workspaceId)
        await apply(documents: documents, mode: storedMode)
        guard case .ready = list else { return }
        addSave = .idle
        modeSave = .idle
        addRejected = false
    }

    /// Upload a document.
    ///
    /// ⛔ BILLABLE, AND NOT IDEMPOTENT. The guard is not defensive: ``busy`` covers the
    /// whole round trip precisely so a second tap cannot buy a second embedding run
    /// over the same text. ⛔ And nothing retries it: a request that timed out may well
    /// have embedded and persisted.
    func addDocument() async {
        guard canWrite, !busy else { return }
        guard canAdd else {
            addRejected = true
            return
        }
        addSave = .saving
        let result = await knowledge.addDocument(
            workspaceId: workspaceId,
            title: trimmed(draftTitle),
            // ⚠️ NOT RESHAPED BEYOND THE ENDS. The chunker owns what the text becomes;
            // changing it here would embed something other than what was shown.
            content: trimmed(draftContent)
        )
        switch result {
        case .success:
            draftTitle = ""
            draftContent = ""
            addSave = .saved
            // ⚠️ THE LIST IS RE-READ RATHER THAN APPENDED TO. The echoed row is one
            // field short of a list row (`sourceUrl` is not in the create's `select`),
            // so appending it would show a document with no source until the next full
            // read.
            await reloadDocuments()
        case let .failure(error):
            // ⚠️ THE DRAFT SURVIVES. Losing a pasted document because the upload failed
            // would be two losses for one fault, and this one was paid for.
            addSave = .failed(FailureText.from(error))
        }
    }

    /// Choose where answers come from.
    ///
    /// ⛔ THE SERVER'S ECHO IS ADOPTED, NEVER THE REQUESTED VALUE. The route re-reads
    /// through its own total sanitiser before answering, so what comes back is what a
    /// later read will see. This is the one write on the settings surface that needs no
    /// separate re-read.
    func setMode(_ next: KnowledgeMode) async {
        guard canChangeMode, next.rawValue != mode else { return }
        modeSave = .saving
        switch await knowledge.setMode(workspaceId: workspaceId, mode: next) {
        case let .success(stored):
            mode = stored
            modeSave = .saved
        case let .failure(error):
            modeSave = .failed(FailureText.from(error))
        }
    }

    /// ⚠️ Retires both banners without a re-read.
    func dismissNotices() {
        guard !busy else { return }
        addSave = .idle
        modeSave = .idle
        addRejected = false
    }

    // MARK: - Internals

    /// ⛔ TWO INDEPENDENT OUTCOMES. A failed mode read sets ``modeUnavailable`` and
    /// leaves the documents alone; a failed document read leaves whatever the mode read
    /// said. Neither failure may present as the other, because "we could not read the
    /// mode" and "the mode is internal" are different claims about where a customer's
    /// questions go.
    private func apply(
        documents: Result<[KnowledgeDocument], ApiError>,
        mode storedMode: Result<String, ApiError>
    ) {
        switch documents {
        case let .success(rows):
            list = .ready(rows)
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
        switch storedMode {
        case let .success(value):
            mode = value
            modeUnavailable = false
        case .failure:
            mode = nil
            modeUnavailable = true
        }
    }

    /// ⚠️ THE LIST ONLY. A write must not re-read the MODE and quietly overwrite a save
    /// banner with a state nobody asked about.
    private func reloadDocuments() async {
        switch await knowledge.documents(workspaceId: workspaceId) {
        case let .success(rows):
            list = .ready(rows)
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
