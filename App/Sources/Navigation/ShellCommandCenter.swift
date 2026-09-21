import Observation
import SwiftUI

/// How a keyboard command reaches a screen the shell cannot see into.
///
/// ⛔ THE SHELL HOLDS NO SCREEN'S MODEL, SO IT ASKS RATHER THAN CALLS. The Inbox's compose
/// sheet and search field belong to a view that is `@State` on its own root and rebuilt on
/// a workspace switch, exactly the reason ``ShellView/inboxPushSignal`` is a value the
/// screen observes. ⌘N and ⌘F therefore set a request here and select the Inbox; the Inbox
/// consumes the request when it sees it, whether it was already on screen or is being built
/// by the same selection (``View/commandTargets(canCompose:composing:)``).
///
/// ⛔ ⌘R RUNS THE REFRESH OF THE SCREEN ON SCREEN, AND "ON SCREEN" IS APPEARANCE, NOT
/// EXISTENCE. A tab the bar is not showing and a list under a pushed screen both still
/// exist; a refresh chosen by existence would re-read a list nobody is looking at. Every
/// pull-to-refresh registers here while it is visible
/// (``View/districtRefreshable(_:)``), and the most recently appeared one is the one run.
/// A list and the detail beside it do not compete: no detail screen has a pull-to-refresh.
@MainActor
@Observable
final class ShellCommandCenter {
    /// ⚠️ MAIN-ACTOR ISOLATED, AS `.refreshable`'S OWN ACTION IS (it inherits the view's
    /// actor), so a screen can hand over the same closure it gave the pull.
    typealias Refresh = @MainActor @Sendable () async -> Void

    /// ⌘N was pressed and the Inbox has not opened its compose sheet yet.
    var composeRequested = false

    /// ⌘F was pressed and the Inbox has not focused its search field yet.
    var searchRequested = false

    private var refreshers: [(id: UUID, action: Refresh)] = []

    /// ⚠️ ONE AT A TIME. A second ⌘R during a slow read would start a second read of the
    /// same list, and the models do not all guard against that themselves.
    private(set) var isRefreshing = false

    var canRefresh: Bool {
        !refreshers.isEmpty && !isRefreshing
    }

    func register(_ id: UUID, action: @escaping Refresh) {
        refreshers.removeAll { $0.id == id }
        refreshers.append((id, action))
    }

    func unregister(_ id: UUID) {
        refreshers.removeAll { $0.id == id }
    }

    /// Run the refresh of the screen that appeared last, if any is on screen.
    func refresh() async {
        guard !isRefreshing, let current = refreshers.last else { return }
        isRefreshing = true
        await current.action()
        isRefreshing = false
    }
}

extension View {
    /// `.refreshable`, and the same action on ⌘R while this view is on screen.
    ///
    /// ⛔ THE ONE ACTION FOR BOTH, SO THE KEYBOARD CAN NEVER REFRESH DIFFERENTLY FROM THE
    /// PULL. Outside the shell (a preview, a test host) there is no center and this is
    /// exactly `.refreshable`.
    func districtRefreshable(_ action: @escaping ShellCommandCenter.Refresh) -> some View {
        modifier(CommandRefreshable(action: action))
    }

    /// Where ⌘N and ⌘F land: open the compose sheet, focus the search field.
    ///
    /// ⚠️ APPLIED AFTER `.searchable`, because the search focus it binds belongs to that
    /// field.
    func commandTargets(canCompose: Bool, composing: Binding<Bool>) -> some View {
        modifier(CommandTargets(canCompose: canCompose, composing: composing))
    }
}

private struct CommandRefreshable: ViewModifier {
    let action: ShellCommandCenter.Refresh

    @Environment(ShellCommandCenter.self) private var center: ShellCommandCenter?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .refreshable { await action() }
            .onAppear { center?.register(id, action: action) }
            .onDisappear { center?.unregister(id) }
    }
}

private struct CommandTargets: ViewModifier {
    let canCompose: Bool
    @Binding var composing: Bool

    @Environment(ShellCommandCenter.self) private var center: ShellCommandCenter?
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        focusable(content)
            // ⛔ `initial: true`, BECAUSE THE REQUEST CAN ARRIVE BEFORE THIS VIEW DOES. On
            // regular width ⌘N selects the Inbox and sets the request in one update, and the
            // Inbox is built by that same selection, so the request is already set on its
            // first evaluation and would never be a change.
            .onChange(of: center?.composeRequested == true, initial: true) { _, requested in
                guard requested else { return }
                center?.composeRequested = false
                // ⚠️ CONSUMED EITHER WAY, so a request this role cannot honour does not sit
                // waiting for a workspace where it can.
                if canCompose {
                    composing = true
                }
            }
            .onChange(of: center?.searchRequested == true, initial: true) { _, requested in
                guard requested else { return }
                center?.searchRequested = false
                searchFocused = true
            }
    }

    /// ⚠️ iOS 18 OR LATER ONLY: `searchFocused` does not exist on 17, where the command
    /// brings the field on screen and stops. See ``DistrictCommands``.
    @ViewBuilder
    private func focusable(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.searchFocused($searchFocused)
        } else {
            content
        }
    }
}
