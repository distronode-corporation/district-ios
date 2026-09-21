import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The analytics half of ``AnalyticsContent``.
///
/// ⛔ EVERY TYPE IN THIS FILE IS DECLARED AT FILE SCOPE RATHER THAN NESTED, AND THAT
/// IS A SAFETY MEASURE RATHER THAN A LAYOUT PREFERENCE. A nested type whose NAME
/// matches an associated-type requirement of a protocol the enclosing type conforms
/// to becomes the WITNESS for that requirement, which is the trap
/// `DistrictButton.swift` documents at length for `Body`;
/// `Content`, `Label`, `ID`, `Value` and `Configuration` are the rest of the list.
/// `AnalyticsContent` is one rename away from being on it, and a nested `Content`
/// under a `View` is the exact collision. File scope makes it unreachable rather
/// than merely unlikely, and the prefixed names keep it that way after a rename.
enum AnalyticsCardState {
    case ready(AnalyticsResponse)
    case failed(FailureText)
}

/// The current month's half.
enum UsageCardState {
    /// ⛔ A nil PAYLOAD MEANS "NOTHING METERED THIS MONTH", NOT ZERO OF EVERYTHING.
    /// The server sends a JSON null when the month has no rows at all; rendering
    /// that as a column of zeros states a billing fact nobody measured, and it looks
    /// authoritative in exactly the place an operator would trust it.
    case ready(UsageMonth?)
    case failed(FailureText)
}

/// The recent-months half.
///
/// ⛔ A SEPARATE SUB-STATE FROM ``UsageCardState`` EVEN THOUGH BOTH COME FROM
/// `workspace/usage`. They are two requests with two response shapes (an object and
/// an array, switched by `history=true`) and either can fail while the other
/// answers. Folding them together would let a failed history read blank the current
/// month's figures, which is the mistake this whole screen is built to avoid.
enum UsageHistoryCardState {
    /// ⛔ EMPTY MEANS "NOTHING HAS EVER BEEN METERED", NOT A FAILURE. The server
    /// appends only the months that had rows.
    case ready([UsageMonth])
    case failed(FailureText)
}

/// Everything the screen draws once at least one read has answered.
///
/// ⚠️ `range` IS THE WINDOW THE PICKER SHOULD SHOW AS SELECTED, updated the moment a
/// new one is chosen rather than when its response lands — so the segment never lags
/// the tap. ``refreshing`` is what says the figures on screen are still the previous
/// window's.
struct AnalyticsContent {
    let range: AnalyticsRange
    let analytics: AnalyticsCardState
    let usage: UsageCardState
    let history: UsageHistoryCardState
    let refreshing: Bool
}

/// The three top-level states.
///
/// ⛔ ``failed(_:)`` MEANS *EVERY* READ FAILED. Anything partial stays in
/// ``content(_:)`` with the failure confined to its own card, because an operator
/// who can see this month's SMS count must not lose it to a call aggregate that
/// timed out. This case is the one situation where there is nothing on screen to
/// preserve and a single retry is the honest control.
enum AnalyticsState {
    case loading
    case content(AnalyticsContent)
    case failed(FailureText)
}

/// Drives the Analytics screen: three independent reads for one workspace.
///
/// ⛔ THE THREE READS RUN CONCURRENTLY, AND THAT IS A CORRECTNESS-ADJACENT DECISION
/// RATHER THAN A PERFORMANCE ONE. Sequentially the usage figures would be gated
/// behind an aggregate that scans every `Call` row in the window, so a slow query
/// would hold back a fast unrelated read — and a FAILING one would, in the obvious
/// early-return shape, stop the others being issued at all. `async let` makes "any
/// read can be late or absent without touching the others" structural instead of
/// something each branch has to remember.
///
/// ⛔ AND ALL THREE LAND BEFORE CONTENT IS PUBLISHED. Emitting the first arrival
/// would let the screen assemble itself in whatever order the network answered, so
/// the layout would jump and, worse, a reader could see a usage card beside an empty
/// analytics area and read the emptiness as data. One state change, every answer.
///
/// ⚠️ `@Observable` AND `@MainActor`, NOT `ObservableObject`. iOS 17 is the floor, so
/// the macro's per-property tracking applies.
@MainActor
@Observable
final class AnalyticsModel {
    private(set) var state: AnalyticsState = .loading

    /// The selected window.
    ///
    /// ⚠️ HELD HERE RATHER THAN READ BACK OUT OF ``state``. ``AnalyticsState/failed(_:)``
    /// carries no range, so a retry after a total failure would otherwise have to
    /// invent one — and it would silently pick 7d, discarding the 90-day window the
    /// operator had chosen.
    private(set) var range: AnalyticsRange = .sevenDays

    private let container: AppContainer
    private let workspaceId: String

    /// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY. Every repository is a `let` on
    /// the container built from the one ``ApiClient``; one constructed here would
    /// reach a second ``TokenRefreshCoordinator``.
    init(container: AppContainer, workspaceId: String) {
        self.container = container
        self.workspaceId = workspaceId
    }

    /// Read all three.
    ///
    /// ⚠️ NOT GUARDED AGAINST A CONCURRENT CALL, unlike anything that spends money.
    /// All three are idempotent GETs, and the realistic double-trigger is a session
    /// change landing on top of a manual retry — one wasted read against one
    /// duplicated state write of the same value.
    func load(refreshing: Bool = false) async {
        state = Self.pending(from: state, range: range, refreshing: refreshing)

        // ⚠️ HOISTED TO LOCALS BEFORE THE `async let`, DELIBERATELY. The initialiser
        // of an `async let` runs concurrently, so anything it captures has to be
        // `Sendable` — and `self` is a `@MainActor` class that is not. A repository
        // is a `Sendable` struct wrapping the shared client, so copying it out first
        // is both correct and free. See the ⚠️ on `AppContainer.api`.
        let repository = container.analytics
        let workspace = workspaceId
        let window = range

        async let report = repository.analytics(workspaceId: workspace, range: window)
        async let usage = repository.usage(workspaceId: workspace)
        // ⚠️ NO EXPLICIT `months`. The repository's default is the span the web
        // console asks for, and naming a number here would be a second copy of that
        // decision — the kind that drifts and shows two spans under one heading.
        async let history = repository.usageHistory(workspaceId: workspace)

        state = await Self.publish(
            range: window,
            analytics: report,
            usage: usage,
            history: history
        )
    }

    /// Switch the window.
    ///
    /// ⚠️ A TAP ON THE ALREADY-SELECTED SEGMENT IS A NO-OP, not a refresh. The
    /// picker is a selector rather than a row of buttons, and re-issuing the same
    /// window would make an impatient double-tap cost two full-window aggregates.
    ///
    /// ⚠️ THE HISTORY IS RE-READ BY A SWITCH THAT CANNOT AFFECT IT, for the reason
    /// the current month already is: the alternative is two load paths, and the one
    /// that skipped the unwindowed reads would be the one a session-expiry retry
    /// needed. One redundant request per tap.
    func select(_ next: AnalyticsRange) async {
        guard next != range else { return }
        range = next
        await load(refreshing: true)
    }

    /// ⚠️ KEEPS THE FIGURES ON SCREEN FOR A RELOAD and shows ``AnalyticsState/loading``
    /// only when there is nothing to keep. Blanking the screen on a window switch
    /// would flash it on every tap; the selected segment moves immediately, so the
    /// tap is acknowledged either way.
    private static func pending(
        from current: AnalyticsState,
        range: AnalyticsRange,
        refreshing: Bool
    ) -> AnalyticsState {
        guard refreshing, case let .content(content) = current else { return .loading }
        return .content(
            AnalyticsContent(
                range: range,
                analytics: content.analytics,
                usage: content.usage,
                history: content.history,
                refreshing: true
            )
        )
    }

    /// ⛔ A WHOLE-SCREEN FAILURE ONLY WHEN EVERY READ FAILED. If any answered, its
    /// card is rendered and the others carry their own failures. Collapsing a partial
    /// failure into the full-screen state throws away an answer already in hand,
    /// which is the same mistake as rendering "we could not look" as "there is
    /// nothing".
    ///
    /// ⚠️ THE ANALYTICS FAILURE IS THE ONE SURFACED in the all-failed case. They are
    /// almost always the same underlying cause (a dead session, an unreachable
    /// region), and analytics is the subject of the screen.
    private static func publish(
        range: AnalyticsRange,
        analytics: Result<AnalyticsResponse, ApiError>,
        usage: Result<UsageMonth?, ApiError>,
        history: Result<[UsageMonth], ApiError>
    ) -> AnalyticsState {
        let analyticsCard: AnalyticsCardState = switch analytics {
        case let .success(report): .ready(report)
        case let .failure(error): .failed(FailureText.from(error))
        }

        let usageCard: UsageCardState = switch usage {
        case let .success(month): .ready(month)
        case let .failure(error): .failed(FailureText.from(error))
        }

        let historyCard: UsageHistoryCardState = switch history {
        case let .success(months): .ready(months)
        case let .failure(error): .failed(FailureText.from(error))
        }

        if case let .failed(failure) = analyticsCard, case .failed = usageCard, case .failed = historyCard {
            return .failed(failure)
        }
        return .content(
            AnalyticsContent(
                range: range,
                analytics: analyticsCard,
                usage: usageCard,
                history: historyCard,
                refreshing: false
            )
        )
    }
}
