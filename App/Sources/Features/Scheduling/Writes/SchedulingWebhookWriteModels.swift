import DistrictData
import DistrictModel
import Foundation
import Observation

/// A webhook's signing secret, held only for as long as its sheet is on screen.
///
/// ⛔ SHOWN ONCE AND NOT KEPT. `webhooks.create` returns `secret` and nothing else
/// ever does — the list does not carry it and there is no rotate op — so a customer
/// who loses it cannot verify a delivery signature and has to delete the
/// subscription and make another. Same discipline as `SchedulingAPIKeyMintedC`.
struct SchedulingWebhookSecretC: Identifiable {
    let id = UUID()
    let url: String
    /// ⛔ THE SIGNING SECRET. Never logged, never persisted.
    let secret: String
}

/// Create a webhook, or change an existing one's events and fields.
///
/// ⛔ ONE MODEL FOR BOTH, BECAUSE THE FORM IS THE SAME FORM AND THE OPS ARE NOT.
/// `webhooks.create` takes `url`, `events` and `fields` and answers a row carrying
/// a once-only secret; `webhooks.patch` takes `events` and `fields` only and
/// answers **204 with no body**. Splitting them into two models would duplicate the
/// validation and the ordered-array construction, which is where the interesting
/// mistakes live; keeping the URL out of the patch is what ``mode`` is for.
///
/// ⛔ THE URL IS NOT EDITABLE ON AN EXISTING ROW. Offering a box that silently kept
/// the old value is worse than not offering one: the person believes deliveries
/// have moved. The sheet shows it as text and says why.
///
/// ⚠️ A SUCCESSFUL PATCH IS FOLLOWED BY `onChanged()` AND NOTHING ELSE. There is no
/// updated row to merge — the 204 has no body — so a screen that optimistically
/// applied its own edit would show the edit even where the fork clamped it.
@MainActor
@Observable
final class SchedulingWebhookEditorModel {
    /// Which op this sheet will run. ⚠️ Carries the whole row rather than an id,
    /// because the sheet renders the URL it may not change.
    enum ModeC {
        case create
        case edit(SchedulingWebhook)
    }

    var draft: SchedulingWebhookDraftC

    private(set) var urlError: String?
    private(set) var eventsError: String?
    private(set) var busy = false
    private(set) var failure: FailureText?
    private(set) var minted: SchedulingWebhookSecretC?
    /// ⚠️ SET ONLY WHEN A CREATE LANDED WITHOUT A SECRET, which the response schema
    /// allows: `secret` is `.optional()`, so a fork that mints none still parses and
    /// the webhook still exists. nil here plus nil `minted` means nothing happened.
    private(set) var savedNotice: String?

    let mode: ModeC

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    private let onChanged: () -> Void

    init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        mode: ModeC,
        onChanged: @escaping () -> Void
    ) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.mode = mode
        self.onChanged = onChanged
        draft = switch mode {
        case .create: .blank
        case let .edit(webhook): .from(webhook)
        }
    }

    var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        return false
    }

    /// The URL an edit may not change, for the sheet to render as text.
    var fixedURL: String? {
        if case let .edit(webhook) = mode {
            return webhook.url
        }
        return nil
    }

    /// ⛔ EVENT NAMES THE ROW CARRIES AND THIS BUILD DOES NOT KNOW. A save cannot
    /// send them back (the fork answers `unknown event: <name>`), so the sheet says
    /// they will be dropped rather than dropping them silently.
    var droppedEvents: [String] {
        if case let .edit(webhook) = mode {
            return SchedulingWebhookDraftC.unknownEvents(webhook)
        }
        return []
    }

    var canSubmit: Bool {
        !busy && !draft.events.isEmpty
    }

    func submit() async {
        guard !busy else { return }
        guard validate() else { return }
        failure = nil
        savedNotice = nil
        busy = true
        switch mode {
        case .create: await runCreate()
        case let .edit(webhook): await runPatch(webhook)
        }
        busy = false
    }

    func dismissMinted() {
        minted = nil
    }

    func dismissFailure() {
        failure = nil
    }

    func dismissNotice() {
        savedNotice = nil
    }

    // MARK: - The two ops

    private func runCreate() async {
        do {
            let created = try await repository.createWebhook(
                workspaceId: workspaceId,
                url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines),
                events: draft.orderedEvents,
                fields: draft.orderedFields
            )
            if let secret = created.secret {
                minted = SchedulingWebhookSecretC(url: created.url, secret: secret)
            } else {
                savedNotice = SchedulingWriteCopyC.webhookAdded
            }
            onChanged()
        } catch {
            failure = SchedulingFailureCopy.text(forAny: error)
        }
    }

    /// ⚠️ `events` GOES OUT AS `[String]` HERE AND AS THE ENUM ON CREATE, WHICH IS
    /// THE CATALOG'S OWN ASYMMETRY: `webhooks.patch` types the array
    /// `z.string().max(100)` with no enum, so our route does not pre-refuse an
    /// unknown name and the fork answers the 400 instead. Sending raw values off
    /// `SchedulingWebhookEvent` is what keeps this on the safe side of that.
    private func runPatch(_ webhook: SchedulingWebhook) async {
        do {
            _ = try await repository.updateWebhook(
                workspaceId: workspaceId,
                webhookId: webhook.id,
                events: draft.orderedEvents.map(\.rawValue),
                fields: draft.orderedFields
            )
            savedNotice = SchedulingWriteCopyC.webhookUpdated
            onChanged()
        } catch {
            failure = SchedulingFailureCopy.text(forAny: error)
        }
    }

    /// ⚠️ THE URL IS CHECKED ONLY ON A CREATE, because on an edit it is not being
    /// sent — and a stored row whose URL this build would now refuse is still a
    /// working webhook whose events somebody may legitimately want to narrow.
    private func validate() -> Bool {
        let urlProblem = isEditing ? nil : SchedulingWebhookURLCheckC.issue(draft.url)
        urlError = urlProblem
        let eventsProblem = draft.events.isEmpty ? SchedulingWriteCopyC.webhookEventsMissing : nil
        eventsError = eventsProblem
        return urlProblem == nil && eventsProblem == nil
    }
}
