import DistrictData
import DistrictModel
import Foundation
import Observation

/// Which part of the screen is showing.
///
/// ⚠️ "My numbers" IS THE LANDING TAB, NOT SEARCH. The common reason to open this
/// screen is to look up a line the workspace already runs; searching is the rarer,
/// more deliberate act, and opening on an empty search form would make the screen
/// look like it had nothing in it.
///
/// ⛔ FOUR TABS, AND TWO OF THEM ARE NOT SEARCH RESULTS. `registrations` is the
/// regulatory paperwork that has to exist before a number in some countries can be bought;
/// `carrier` is the account the number lives on, plus the compliance filings and the billable
/// lookup. Both are role-gated where the marketplace's two reads are not, so the tab is
/// present for a viewer and its controls are not — ⛔ a viewer must not see a dead control.
///
/// ⛔ AND THERE IS STILL NO PURCHASE TAB. Buying a number charges a setup fee AND opens a
/// recurring monthly charge for a service consumed inside the app, which is App Store Review
/// Guideline 3.1.1: an in-app purchase or nothing. ⛔ 3.1.1 covers steering too, so there is
/// no link either — ``MarketplaceCopy/purchaseElsewhere`` states the boundary in prose,
/// names no destination and offers nothing to tap.
///
/// ⛔ DECLARED AT FILE SCOPE RATHER THAN NESTED, like every type in
/// `WorkflowsModel.swift` and for the reason `AnalyticsModel.swift` records: a
/// nested type whose name matches an associated-type requirement of a protocol the
/// enclosing type conforms to becomes the WITNESS for it, and the error surfaces
/// somewhere else entirely.
enum MarketplaceTab {
    case owned
    case search
    case registrations
    case carrier
}

/// The search form's fields.
///
/// ⚠️ NO PAGE SIZE AND NO CAPABILITY FILTER, because the server hardcodes both
/// (limit 10, sms+voice). A control for either would be a control the route ignores,
/// which is worse than its absence: the operator would believe they had narrowed
/// something.
struct NumberSearchForm {
    var areaCode = ""
    /// ⚠️ Defaults to the server's own default, so an untouched form sends exactly
    /// what an omitted parameter would.
    var country = MarketplaceCopy.defaultCountry
    var type = MarketplaceCopy.numberTypeLocal
}

/// What the carrier inventory half of the screen is doing.
enum MarketplaceSearchState {
    /// ⚠️ NOTHING HAS BEEN SEARCHED YET, AND THAT IS NOT "no results". The form is
    /// the whole content of this state; an empty-results message here would answer a
    /// question the operator has not asked.
    case idle

    case loading

    /// ⚠️ ``provider`` is the carrier that ANSWERED rather than the one that was
    /// asked for, and it is required on the wire, so it is a plain `String` here
    /// where Android models it as nullable.
    case ready(provider: String, numbers: [AvailableNumber])

    /// ⛔ THE WORKSPACE HAS NO CARRIER CONNECTED, WHICH IS AN ACCOUNT STATE RATHER
    /// THAN A FAULT. The route answers 400 both for "no messaging provider
    /// configured" and for "the provider you named is not connected", and neither is
    /// something a retry fixes. It renders as an explanatory empty state with no
    /// retry button, because a red error would tell an operator their app is broken
    /// while their account is merely new.
    case notConfigured(String)

    case failed(FailureText)
}

/// What the "numbers this workspace already has" half is doing.
enum MarketplaceOwnedState {
    case loading

    /// - Parameters:
    ///   - partial: ⛔ TRUE MEANS THIS LIST IS SHORT AND THE SCREEN MUST SAY SO. One
    ///     carrier answered and another did not, on a **200** that decodes perfectly,
    ///     which is the most dangerous shape this route produces because it draws
    ///     exactly like a complete answer. The rows still render: a banner that
    ///     replaced them would discard inventory already in hand.
    ///   - failedProviders: which carrier was unreachable, so the banner can name it.
    case ready(numbers: [ListedNumber], partial: Bool, failedProviders: [String])

    case failed(FailureText)
}

/// The marketplace's state machine: two independent reads and no writes of its own.
///
/// ⛔ THIS TYPE HAS NO WRITE STATE. ``NumbersRepository`` has release, configure, the whole
/// regulatory-registration surface and the carrier-account surfaces, but those writes live on
/// ``NumberProvisioningModel``, which owns its own confirmations and its own per-write states,
/// so the two marketplace READS stay a pair of reads that cannot blank each other. ⛔ A
/// `purchasing` flag here or anywhere is App Store Review Guideline 3.1.1 and has to be
/// discussed.
///
/// ⛔ AND THERE IS NO `webURL` HERE EITHER, WHICH IS THE SAME DECISION ONE STEP OUT. A
/// URL held on this model is a link waiting for a button; the screen states in prose that
/// numbers are not bought here and offers nothing to tap. See the ⛔ on ``MarketplaceView``.
///
/// ⛔ TWO INDEPENDENT READS THAT NEVER SHARE A FAILURE. "What can I buy" and "what do
/// I have" hit different routes with different data layers, so a single failure state
/// would blank an answer the client already holds. Each half carries its own, the
/// same call ``WorkflowsModel`` and ``AnalyticsModel`` make.
///
/// ⛔ THE OWNED LIST LOADS ON ENTRY AND THE SEARCH DOES NOT. Listing what the
/// workspace has is why the screen exists and costs one request; a search is a
/// carrier inventory query against filters only the operator can supply, so firing
/// one on open would spend a request to answer a question nobody asked, and would
/// fill the tab with US local numbers regardless of where the workspace operates.
/// ⛔ THE SAME RULE GOVERNS THE TWO PROVISIONING TABS, and it is sharper there: the filing list
/// refreshes every in-review bundle FROM THE CARRIER on read, and the lookup is billed per
/// call. Each provisioning read fires when its tab is opened, and the lookup only on a tap.
///
/// ⚠️ THE FORM LIVES HERE RATHER THAN IN THE VIEW so it survives a tab switch, which
/// is the one thing on this screen that replaces the search half's content.
@MainActor
@Observable
final class MarketplaceModel {
    private(set) var tab: MarketplaceTab = .owned

    private(set) var form = NumberSearchForm()

    private(set) var search: MarketplaceSearchState = .idle

    private(set) var owned: MarketplaceOwnedState = .loading

    /// Whether this member could make the change at all, wherever they made it.
    ///
    /// ⛔ IT DECIDES WORDING AND NOTHING ELSE, WHICH IS THE WHOLE OF THE ROLE'S JOB ON
    /// THIS SCREEN. Both READ routes admit `viewer`, so nothing here is gated; what
    /// differs is which sentence is true. An agency or client member is pointed at the
    /// other tabs, a viewer is told who to ask, because sending them somewhere that
    /// will also refuse them is worse than saying nothing. ``Route/marketplace(workspaceId:role:)``
    /// records the same rule from the routing side.
    ///
    /// ⚠️ NAMED FOR THE ROLE, NOT FOR A LINK, BECAUSE THIS SCREEN HAS NO LINK. The name is
    /// not cosmetic: a boolean called `canOpenWeb` would be an invitation to hang a link
    /// off it. See the ⛔ on ``MarketplaceView``.
    ///
    /// ⚠️ AN AFFORDANCE, NOT A SECURITY CONTROL, and it errs low: a nil role means
    /// "the role could not be established", never "assume client".
    let canChangeNumbers: Bool

    private let repository: NumbersRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        canChangeNumbers = WorkspaceRole.allowsMutation(role)
        repository = container.numbers
        self.workspaceId = workspaceId
    }

    // MARK: - Derived

    /// ⛔ WORDED PER ROLE, WHICH IS THE WHOLE REASON ``Route/marketplace(workspaceId:role:)``
    /// CARRIES ONE. There is nothing here to gate but there is something to word:
    /// telling a viewer to "use the web dashboard" points them at a second refusal,
    /// so they are told who to ask instead. `Route.swift` states the same rule.
    var readOnlyCaption: String {
        canChangeNumbers ? MarketplaceCopy.readOnly : MarketplaceCopy.readOnlyViewer
    }

    var isSearching: Bool {
        guard case .loading = search else { return false }
        return true
    }

    // MARK: - Form and tabs

    func selectTab(_ next: MarketplaceTab) {
        guard next != tab else { return }
        tab = next
    }

    func updateAreaCode(_ value: String) {
        form.areaCode = value
    }

    func updateCountry(_ value: String) {
        form.country = value
    }

    func updateType(_ value: String) {
        form.type = value
    }

    // MARK: - Reading

    /// Read the workspace's own numbers.
    ///
    /// ⚠️ DELIBERATELY DOES NOT TOUCH THE SEARCH HALF. A retry re-reads the owned
    /// list; re-running a search the operator typed minutes ago would replace results
    /// they are reading with a fresh, possibly different set under no visible trigger.
    ///
    /// ⛔ `partial` IS CARRIED INTO THE READY STATE RATHER THAN PROMOTED TO A
    /// FAILURE. It arrives on a 200 with real rows: one carrier answered, another did
    /// not. Promoting it would hide inventory the operator owns; ignoring it would
    /// draw an incomplete list as a complete one. Both are wrong, which is why it is
    /// a flag on the content.
    ///
    /// ⚠️ BOTH FIELDS ARE READ, NOT EITHER ALONE. ``OwnedNumbersResponse/failedProviderNames``
    /// is the names half and already answers `[]` for a clean list; `partial` is the
    /// "this list is short" half. Reading only the names would silently drop the
    /// banner if the flag ever arrived without them.
    func loadOwned() async {
        owned = .loading
        switch await repository.owned(workspaceId: workspaceId) {
        case let .success(response):
            owned = .ready(
                numbers: response.numbers,
                partial: response.partial == true,
                failedProviders: response.failedProviderNames
            )
        case let .failure(error):
            owned = .failed(FailureText.from(error))
        }
    }

    /// Run the search currently in the form.
    ///
    /// ⚠️ NOT GUARDED AGAINST A CONCURRENT CALL. This is an idempotent GET that
    /// spends nothing on this side; the realistic double-trigger is an impatient
    /// second tap, and its cost is one duplicated read resolving to the same state.
    /// The button is disabled while one is in flight, which is where the guard that
    /// matters lives. (Contrast the contact dossier's enrich, where the same double
    /// tap buys a second LLM run and IS guarded in the model.)
    ///
    /// ⚠️ THE FILTERS ARE PASSED THROUGH RAW. ``NumbersRepository/search(workspaceId:areaCode:country:type:provider:)``
    /// normalises a blank one to absent, because the server distinguishes an omitted
    /// parameter from an empty one; doing it twice would be two places to get it
    /// wrong.
    func runSearch() async {
        let filters = form
        search = .loading
        let outcome = await repository.search(
            workspaceId: workspaceId,
            areaCode: filters.areaCode,
            country: filters.country,
            type: filters.type
        )
        switch outcome {
        case let .success(response):
            search = .ready(provider: response.provider, numbers: response.numbers)
        case let .failure(error):
            search = Self.searchFailure(error)
        }
    }

    // MARK: - Internals

    /// ⛔ A 400 IS AN ACCOUNT STATE, NOT A FAULT, AND IT IS THE ONLY STATUS TREATED
    /// SPECIALLY HERE. The route answers 400 both for "no messaging provider
    /// configured for this workspace" and for "the provider you named is not
    /// connected", and neither is something a retry fixes: they are both "finish
    /// connecting a carrier".
    ///
    /// ⛔ AND IT MUST NEVER BECOME AN EMPTY SUCCESS. Telling an operator the carrier
    /// has no numbers in their area code is a claim about inventory that was never
    /// looked at. ``NumbersRepository`` refuses the same conversion one layer down.
    ///
    /// ⚠️ THE SERVER'S OWN SENTENCE IS CARRIED THROUGH rather than replaced, because
    /// it distinguishes those two cases and this layer cannot. Blank counts as
    /// absent, the same normalisation ``DialerModel/refusalText(_:fallback:)`` makes.
    private static func searchFailure(_ error: ApiError) -> MarketplaceSearchState {
        guard case let .http(status, message) = error else { return .failed(FailureText.from(error)) }
        guard status == notConfiguredStatus else { return .failed(FailureText.from(error)) }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .notConfigured(trimmed.isEmpty ? MarketplaceCopy.notConfiguredFallback : trimmed)
    }

    /// The route's "no carrier connected yet" answer. See ``searchFailure(_:)``.
    private static let notConfiguredStatus = 400
}
