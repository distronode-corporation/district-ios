import Foundation

/// A section of the District dashboard that this app has a REAL destination for.
///
/// Port of the Android client's `DistrictSection` (its `AppLinkResolver`), narrowed to
/// what this app has screens for.
///
/// ⛔ THIS IS NOT A COPY OF THE WEB'S ROUTE LIST AND MUST NOT BECOME ONE. The web
/// dashboard publishes 23 pages under `/dashboard/district`; seven of them are here.
/// Every other one is listed in ``AppLinkResolver/resolve(_:)``'s documentation with the
/// reason it is absent, because "no mapping yet" and "no mapping that is not a dead end"
/// are different states and the second one is a decision rather than a gap.
///
/// ⛔ AND THE FILTER IS NOT "DOES A `Route` CASE EXIST", IT IS "DOES THAT ROUTE DRAW A
/// REAL SCREEN". `Route` seeds every destination in the app, and eight of them still
/// resolve to `PlaceholderView`, whose own contract says nothing may link to it from a
/// build that reaches external testers (App Store Review Guideline 2.1). Resolving a
/// tapped link onto "Coming in a later build." is worse than resolving it onto the
/// overview, because the user waited for an app to open in order to be told nothing.
/// So `hq`, `billing`, `marketplace`, `workflows`, `rooms` and workspace
/// settings are deliberately NOT here even though each has a `Route` case ready for
/// them. Adding one is the same commit that gives it a screen.
///
/// ⛔ AND AN ABSENCE HERE IS A HAND-OFF TO THE BROWSER RATHER THAN A SILENT LANDING ON
/// THE OVERVIEW, which is what makes the paragraph above affordable. Otherwise a tapped
/// link to a real web page would arrive on a screen that was not it and say nothing
/// about why; the honest answer for a page this app cannot draw is the page. See ``AppLinkOutcome/openInBrowser``.
public enum DistrictSection: String, Hashable, Sendable, CaseIterable {
    /// The dashboard root, and only that.
    ///
    /// ⛔ THIS IS NOT THE CATCH-ALL. Only `/dashboard/district` itself and its
    /// trailing-slash spellings resolve here; a claimed URL naming a section this app has no screen for
    /// resolves to ``AppLinkOutcome/openInBrowser``.
    case overview

    case inbox

    /// The call log. ⚠️ The one section that can carry a ``AppLinkDestination/detailId``.
    case calls

    case contacts

    case analytics

    case scheduling

    /// ⚠️ THE ONE SECTION WITH NO WEB PAGE BEHIND IT, AND THE ONLY ONE THAT NEEDS NO
    /// WORKSPACE. There is no `/dashboard/district/devices` on the website today, so
    /// nothing can currently produce a link that resolves here; it is mapped because
    /// the app's own screen is account-scoped and unambiguous, so the day that page
    /// exists the client half is already right. Until then this arm is reachable only
    /// from a hand-typed URL, which lands somewhere real rather than on the overview.
    case devices
}

/// What a claimed URL means: a section, optionally one detail id, optionally a tenant.
///
/// ⛔ A VALUE RATHER THAN A ROUTE, AND THAT SEAM IS WHAT KEEPS THIS FILE ON THE LINUX
/// TIER. `Route` and `Tab` are App-target types (they name SwiftUI screens); turning a
/// section into one of them is `AppLinkRouting` in `App/Sources/Navigation/`, which is
/// the same split Android makes between `AppLinkResolver` (pure, plain-JVM) and
/// `appLinkRoute` (in the `ui` package, because it touches the framework). Everything
/// about a URL that can be WRONG is decided here, where a test can see it.
public struct AppLinkDestination: Equatable, Sendable {
    /// The section the URL named. ⚠️ Always a section this app can actually draw: a
    /// claimed URL naming anything else never becomes a destination at all, it becomes
    /// ``AppLinkOutcome/openInBrowser``.
    public let section: DistrictSection

    /// The second path segment, for the two sections that have a drill-down.
    ///
    /// ⚠️ ALWAYS NIL EXCEPT ON ``DistrictSection/calls`` AND ``DistrictSection/scheduling``,
    /// AND IT MEANS DIFFERENT THINGS ON THE TWO. A detail id guessed out of a URL is only
    /// worth carrying where the app has a destination that can show it AND a stack to fall
    /// back onto; see the ⚠️ in ``AppLinkResolver/resolve(_:)``.
    ///
    /// ⛔ ON `calls` IT IS AN OPAQUE SERVER ID AND ON `scheduling` IT IS A FIXED
    /// VOCABULARY, which is why this type does not validate it. A call id is whatever the
    /// API minted and only the detail screen can say whether it resolves; a scheduling
    /// segment is one of nine names the App target knows (`SchedulingSection`), and an
    /// unknown one there lands on the hub rather than on a failure. Validating here would
    /// put the App's own section vocabulary on the Linux tier, which is the cut the ⛔ on
    /// this type exists to hold.
    public let detailId: String?

    /// The `workspaceId` query item, when the link carried one.
    ///
    /// ⛔ A LINK MAY SWITCH TENANT WHERE A PUSH MAY NOT, AND THE DIFFERENCE IS CONSENT.
    /// ``PushDeepLinkDecision/drop`` refuses to re-point the app at another workspace
    /// because a notification arrives on its own schedule, from a lock screen, mid-task.
    /// A link is the opposite: someone deliberately tapped a URL that names this tenant,
    /// so honouring it is doing what was asked rather than acting on the user's behalf.
    public let workspaceId: String?

    public init(section: DistrictSection, detailId: String? = nil, workspaceId: String? = nil) {
        self.section = section
        self.detailId = detailId
        self.workspaceId = workspaceId
    }

    /// Whether this destination cannot be honoured until a workspace has resolved.
    ///
    /// ⛔ THE ANSWER IS "WAIT", NOT "NOWHERE", AND THAT IS WHY THIS IS A QUESTION AT
    /// ALL. On a cold start from a link the active workspace comes from two requests
    /// still in flight (`workspace/list` then `overview`), so a destination that needs
    /// one has to be HELD and asked again, exactly the way ``PushDeepLinkDecision/wait``
    /// holds a tapped notification. Dropping instead would make Universal Links work
    /// only when the app was already open and loaded, which is never the case they
    /// exist for. Kotlin's `appLinkRoute` states the same rule as a nullable return.
    ///
    /// ⚠️ FOUR OF THE SEVEN SECTIONS ANSWER FALSE, WHICH IS THE PLACE THIS DIVERGES
    /// FROM ANDROID AND IT IS A PLATFORM DIFFERENCE RATHER THAN A DECISION. Android's
    /// inbox, calls and contacts are workspace-scoped ROUTES and cannot be built
    /// without an id; here they are TABS, and `Tab` carries no tenant. Selecting a tab
    /// during the workspace load is not merely safe, it is what makes the right tab be
    /// showing the moment the tabs appear rather than a frame later, which is the same
    /// reasoning `ShellView.apply(_:)` already records for a push that switches tenant.
    public var requiresWorkspace: Bool {
        switch section {
        case .analytics, .scheduling:
            // Both become a `Route` carrying the workspace id in the value.
            true
        case .calls:
            // The LIST is a tab; only the drill-down needs an id.
            detailId != nil
        case .overview, .inbox, .contacts, .devices:
            false
        }
    }
}

/// What a claimed URL is worth acting on AS: a place in this app, or the web page.
///
/// ⛔ THE THIRD OUTCOME, AND IT IS NOT THE SAME AS THE SECOND. Android says this as a
/// three-armed sealed interface (`Section`, `OpenInBrowser`, `Ignore`); here the third
/// arm is `nil`, because ``AppLinkResolver/resolve(_:)`` already answered a
/// `AppLinkOutcome?` and nil already MEANT "not ours, leave the URL completely alone".
/// Collapsing nil into ``openInBrowser`` would hand `districtai://auth` to a browser and
/// break sign-in, which is the exact ⛔ Kotlin's `AppLinkDestination` carries.
///
/// ⛔ AND ``openInBrowser`` IS NEVER A DEAD END, WHICH IS THE WHOLE REASON IT EXISTS.
/// The app claims a broad path prefix and draws seven of the dashboard's screens; before
/// this case, every other claimed URL landed on the overview, which is a real screen and
/// the WRONG one. A user who tapped a link to billing waited for an app to launch in
/// order to be shown something they did not ask for, with nothing on screen to say the
/// page they wanted exists elsewhere. The web page does exist, and it is the honest
/// answer. Kotlin words it the same way: "NEVER A DEAD END".
public enum AppLinkOutcome: Equatable, Sendable {
    /// Somewhere in this app. ⚠️ ``AppLinkDestination/requiresWorkspace`` still decides
    /// whether it can be acted on YET.
    case destination(AppLinkDestination)

    /// Hand the URL, unchanged, to the system browser.
    ///
    /// ⛔ THE URL IS NOT CARRIED IN THIS CASE, DELIBERATELY. The caller already holds the
    /// `URL` it passed in, and re-emitting it here would invite a future edit to hand
    /// back a REBUILT one. The value that reaches `SFSafariViewController` has to be
    /// byte-for-byte what the OS delivered, query and fragment included, or the browser
    /// lands somewhere the tap did not name.
    case openInBrowser
}

/// Turn a URL the OS handed us into a destination, or refuse it.
///
/// ⛔ THREE PLACES HAVE TO AGREE FOR A LINK TO OPEN THIS APP AT ALL, and this is only
/// the third: the entitlement in `project.yml` (what the OS will offer us), the
/// `apple-app-site-association` file the web server publishes under `/.well-known/`
/// (what the OS will believe), and this type (what the app will act on). A host present in
/// only some of them fails differently in each direction, and every one of those
/// failures looks identical from the outside: the link opens Safari.
public enum AppLinkResolver {
    /// The hosts whose `https://` links this app will act on.
    ///
    /// ⚠️ WIDER THAN THE ENTITLEMENT ON PURPOSE, AND THAT ASYMMETRY IS WORTH KNOWING
    /// BEFORE IT READS AS A BUG. The entitlement claims `www.distronode.com` only, so
    /// iOS will never deliver an apex link here; the apex is accepted anyway because
    /// the website serves the association file on BOTH hosts, Android's intent filter
    /// claims both, and widening the entitlement should then be a one-line change with
    /// no client half to remember. It can only ever admit a URL the OS already decided
    /// belonged to us.
    ///
    /// ⛔ `distronode.ca` IS IN NONE OF THE THREE PLACES, DELIBERATELY. The French
    /// Canadian domain is unclaimed on both clients; see the ⛔ in the AASA route.
    public static let hosts: Set<String> = ["distronode.com", "www.distronode.com"]

    /// The claimed path prefix. ⛔ Widening it is a promise to handle more URLs, and
    /// the promise has to be made in the served association file first.
    public static let pathPrefix = "/dashboard/district"

    /// Resolve a URL to an outcome, or nil if it is not ours to act on.
    ///
    /// ## What nil means
    ///
    /// ⛔ NIL IS A REFUSAL, NOT A FAILURE, AND IT IS UNREACHABLE THROUGH A REAL
    /// UNIVERSAL LINK. Apple's association file claims exactly `/dashboard/district`
    /// and `/dashboard/district/*` for one host, so the OS delivers nothing else; every
    /// nil below is a URL that arrived some other way (a hand-built one in a test, a
    /// future custom scheme) and the honest answer is to leave it alone.
    ///
    /// ⛔ SO A PATH OUTSIDE THE CLAIM STILL ANSWERS NIL RATHER THAN THE BROWSER, AND
    /// THAT IS THE ONE PLACE THIS TYPE DELIBERATELY DIVERGES FROM ANDROID IN THE OTHER
    /// DIRECTION. Kotlin's `appLinkDestination` answers `OpenInBrowser` for
    /// `/dashboard/districts-of-europe` because its manifest `pathPrefix` filter really
    /// does deliver that page to the app, so somebody has to send it back out. Apple's
    /// `*` pattern never matches it, so on this client the same URL is one that was
    /// never ours; bouncing it to a browser would mean acting on a URL the OS did not
    /// give us. ⚠️ THE MIRROR OF THAT DIVERGENCE IS BELOW: Kotlin answers OVERVIEW for
    /// an unrecognised segment INSIDE the prefix and states that choice in its own ⚠️.
    /// This client answers the browser, because Android maps ten sections to this
    /// client's seven, so the segments that fall through here (`hq`, `billing`,
    /// `marketplace`, `workflows`) are pages Android actually draws.
    ///
    /// ## Web pages deliberately NOT mapped
    ///
    /// All of them are inside the claimed prefix, so none of them refuses; each resolves
    /// to ``AppLinkOutcome/openInBrowser`` and opens the real web page. Any other
    /// segment inside the prefix resolves the same way.
    ///
    /// - `settings`: ⛔ AMBIGUOUS IN A WAY THAT MATTERS, exactly as on Android. This
    ///   app has TWO settings surfaces, `Tab.account` (sign-out and account deletion,
    ///   deliberately tenant-free) and `Route.workspaceSettings` (persona, routing,
    ///   members, viewer-excluded server-side on every route behind it). The web has one
    ///   page. Guessing wrong sends a user to a screen that either 403s or holds nothing
    ///   they were looking for, and the tenant guess is a `PlaceholderView` today
    ///   besides.
    /// - `hq`, `billing`, `marketplace`, `workflows`, `rooms`: a `Route` case
    ///   exists for each and every one of them draws `PlaceholderView`. See the ⛔ on
    ///   ``DistrictSection``.
    /// - `meetings` and `meetings/<id>`: `Route.activeRoom` carries the full
    ///   `meet_<workspaceId>_<suffix>` room name as ONE value because that is what a
    ///   media token is minted against, and rebuilding one from a URL segment is exactly
    ///   how a `video_` name (a BILLABLE avatar session, one character away in the same
    ///   `startsWith` chain) gets built by mistake. `RoomName` in `DistrictNetwork` is
    ///   the only mint.
    /// - `live`: `Route.dialer` is the OUTBOUND softphone, not a live-calls monitor.
    ///   Landing a link on a keypad that can spend money is the wrong kind of wrong.
    /// - `campaigns`: "Campaigns" is not an entity on either client (one boolean, one
    ///   int and one string on `Workspace`).
    /// - `dgi`: a per-contact enrichment surface behind a default-off flag, not a
    ///   standalone screen.
    /// - `support`, `desk`, `workspaces`: no destination exists at all.
    ///
    /// ⚠️ ONLY THE FIRST SEGMENT AFTER THE PREFIX DECIDES THE OUTCOME, so `billing/invoices`
    /// resolves the way `billing` does (to the browser) and a deeper path under a MAPPED
    /// section lands on that section. Android has the same behaviour, pinned by a test.
    ///
    /// ⚠️ `scheduling/<sub>` IS THE SECOND DEEPER PATH THAT IS KEPT. The web
    /// publishes eight real sub-pages under `/dashboard/district/scheduling` (`event-types`,
    /// `hours`, `bookings`, `calendar`, `team`, `recordings`, `settings`, `developer`) and
    /// the app now draws every one of them, so sending all eight to the hub would be the
    /// same wrong answer the `openInBrowser` case was introduced to stop — a link that
    /// resolved, opened the app, and showed something the user did not ask for. ⚠️ A ninth
    /// name, `overview`, is accepted for the register that the web serves at the scheduling
    /// ROOT; nothing produces that URL today, and it is mapped on the same reasoning the
    /// `calls/<id>` paragraph below gives for a page the website has not published either.
    ///
    /// ⚠️ `calls/<id>` IS THE OTHER DEEPER PATH THAT IS KEPT, AND THIS IS THE DELIBERATE
    /// DIVERGENCE FROM ANDROID. Android drops the id because it navigates to a single
    /// route and "a detail id guessed out of a URL is a 404 with a back button that
    /// returns to the same 404". Here the detail is appended ON TOP of the freshly reset
    /// call-log root of the calls tab, so a stale or invented id shows the detail
    /// screen's own failure state with the call log one back-swipe away. The stack is
    /// what makes it safe, not the id. ⚠️ The website publishes no such page today, so
    /// nothing produces this URL yet; the mapping costs one branch and is right the day
    /// it does.
    ///
    /// ⚠️ THE PATH IS PERCENT-DECODED BEFORE IT IS SPLIT, so a `%2F` inside an id
    /// becomes a segment boundary and the id is truncated at it. That is a 404 in the
    /// detail view rather than a traversal: `DistrictNetwork` builds request paths from
    /// SEGMENTS and never by interpolation, pinned by negative tests, so a `..` cannot
    /// reach a different route however it arrives.
    public static func resolve(_ url: URL) -> AppLinkOutcome? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            hosts.contains(host),
            isClaimed(components.path)
        else { return nil }

        let segments = components.path.dropFirst(pathPrefix.count).split(separator: "/").map(String.init)
        // ⛔ THE CLAIM IS ALREADY MADE BY HERE, SO THE ONLY QUESTION LEFT IS WHICH KIND OF
        // "YES" THIS IS. An unmapped section is the browser, never nil: nil would leave a
        // tapped link doing nothing at all, which is the one outcome worse than both.
        guard let section = section(for: segments.first) else { return .openInBrowser }
        return .destination(AppLinkDestination(
            section: section,
            detailId: detailId(for: section, segments: segments),
            workspaceId: workspaceId(in: components)
        ))
    }

    /// ⛔ A PREFIX MATCH IS NOT A `startsWith`, AND THE DIFFERENCE IS A REAL URL.
    /// `startsWith` alone would claim `/dashboard/districts-of-europe` and
    /// `/dashboard/districtai-pricing`, which are different pages that merely begin with
    /// the same characters. Apple's own `*` pattern rejects them, so this is agreement
    /// with the served association file rather than belt and braces.
    private static func isClaimed(_ path: String) -> Bool {
        path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }

    /// The section a first segment names, or nil for one this app has no screen for.
    ///
    /// ⛔ NIL HERE MEANS THE BROWSER, NOT A REFUSAL, AND THIS FUNCTION USED TO ANSWER
    /// ``DistrictSection/overview`` INSTEAD. The overview is a real screen and it is the
    /// wrong one for a link that named `billing`: the tap resolved, the app opened, and
    /// the page the user asked for was neither shown nor mentioned. Only
    /// ``AppLinkResolver/resolve(_:)`` turns this nil into
    /// ``AppLinkOutcome/openInBrowser``; a refusal is still spelled nil THERE, one level
    /// up, for URLs that were never ours.
    ///
    /// ⚠️ NO SEGMENT AT ALL IS THE OVERVIEW, AND THAT IS THE DASHBOARD ROOT RATHER THAN A
    /// FALLBACK. `/dashboard/district`, `/dashboard/district/` and `/dashboard/district//`
    /// are one page to the web server (`split` drops empty segments), so they have to be
    /// one destination here: a link copied with a trailing slash behaving differently
    /// from the same link without one is indistinguishable from a bug.
    ///
    /// ⚠️ CASE-FOLDED because a path is case-sensitive to a server but a shared link is
    /// retyped by humans. Folding can only ever widen what reaches a real section; it
    /// cannot make a claimed URL unreachable.
    private static func section(for segment: String?) -> DistrictSection? {
        guard let segment else { return .overview }
        switch segment.lowercased() {
        case "inbox": return .inbox
        case "calls": return .calls
        case "contacts": return .contacts
        case "analytics": return .analytics
        case "scheduling": return .scheduling
        case "devices": return .devices
        default: return nil
        }
    }

    /// ⚠️ GUARDED ON THE SECTION RATHER THAN ON THE SEGMENT COUNT ALONE, so that a
    /// deeper path under any other section (`billing/invoices`, and whatever the web adds
    /// next) keeps landing on its parent instead of quietly carrying a value nothing
    /// reads.
    ///
    /// ⚠️ `scheduling` JOINED `calls` HERE WHEN THE NATIVE SCHEDULING SECTION LANDED, and
    /// it is the SAFER of the two rather than a widening of the risk. A `calls/<id>`
    /// segment is an opaque id that may not resolve; a `scheduling/<sub>` segment is one
    /// of nine fixed names, and the App target's mapping answers the hub for anything it
    /// does not recognise — so the worst case is landing one level up, inside the surface
    /// the URL named, with nothing to fail.
    ///
    /// ⛔ IT IS LOWERCASED HERE AND NOT AT THE CALL SITE. ``section(for:)`` case-folds its
    /// own segment because a shared link is retyped by humans, and a sub-path that did not
    /// get the same treatment would send `/scheduling/Event-Types` to the hub while
    /// `/Scheduling` reached the section — one rule applied to half a path is worse than
    /// either rule applied whole.
    private static func detailId(for section: DistrictSection, segments: [String]) -> String? {
        guard section == .calls || section == .scheduling, segments.count > 1 else { return nil }
        return section == .scheduling ? segments[1].lowercased() : segments[1]
    }

    /// ⚠️ AN EMPTY VALUE IS TREATED AS ABSENT. `?workspaceId=` is what a truncated or
    /// hand-edited link looks like, and switching the app to a workspace named by the
    /// empty string is not a thing that can succeed.
    ///
    /// ⚠️ NOTHING ON THE WEBSITE PRODUCES THIS QUERY ITEM TODAY. The dashboard resolves
    /// the active workspace server-side from the session and puts no tenant in its page
    /// URLs. It is honoured because a shared link is exactly where naming the tenant
    /// matters, and because the cost of reading it is one optional.
    private static func workspaceId(in components: URLComponents) -> String? {
        guard let value = components.queryItems?.first(where: { $0.name == "workspaceId" })?.value else {
            return nil
        }
        return value.isEmpty ? nil : value
    }
}
