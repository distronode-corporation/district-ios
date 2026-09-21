import DistrictModel
import SwiftUI

/// Which hardware-keyboard commands can run, decided from the shell's state alone.
///
/// ⛔ A COMMAND THAT CANNOT RUN IS DISABLED, NEVER REMOVED. The menu a held ⌘ key shows is
/// how somebody learns the shortcuts exist; a menu whose entries come and go with the
/// screen teaches nothing, while a greyed entry says what it would do and that it cannot
/// do it here.
///
/// ⛔ ``unavailable`` IS WHAT A SIGNED-OUT APP GETS, and it gets it structurally rather than
/// by a check. The shell is the only publisher of ``ShellCommandActions``, and ``RootView``
/// draws the shell only for a signed-in session, so with nobody signed in there is no value
/// to read and every command falls back to this.
struct ShellCommandAvailability: Equatable {
    /// ⚠️ EVERY COMMAND NEEDS A WORKSPACE, because every section but Account reads one and
    /// the shell draws no sections at all until one resolves.
    let workspaceResolved: Bool
    let canSend: Bool
    let refreshAvailable: Bool

    init(workspaceId: String?, role: WorkspaceRole?, refreshAvailable: Bool) {
        workspaceResolved = workspaceId != nil
        // ⛔ THE SAME GATE THE INBOX'S OWN "New" BUTTON AND THE SEND ITSELF USE
        // (``InboxModel/canReply``, ``ComposeModel/canSend``), so the shortcut can never
        // offer a viewer the sheet the toolbar hides from them.
        canSend = WorkspaceRole.allowsMutation(role)
        self.refreshAvailable = refreshAvailable
    }

    static let unavailable = ShellCommandAvailability(workspaceId: nil, role: nil, refreshAvailable: false)

    var canSelectSection: Bool {
        workspaceResolved
    }

    var canCompose: Bool {
        workspaceResolved && canSend
    }

    var canSearch: Bool {
        workspaceResolved
    }

    /// ⚠️ ONLY WHILE A SCREEN WITH A PULL-TO-REFRESH IS ON SCREEN. See
    /// ``ShellCommandCenter``.
    var canRefresh: Bool {
        workspaceResolved && refreshAvailable
    }

    /// The digit ⌘ selects a tab with: 1 to 5, in the tab bar's order.
    static func digit(for tab: Tab) -> Character {
        let index = Tab.allCases.firstIndex(of: tab) ?? 0
        return Character(String(index + 1))
    }
}

/// What the signed-in shell lets the keyboard do, published for ``DistrictCommands``.
///
/// ⛔ ONE PUBLISHER, THE SHELL, SO THERE IS NEVER A QUESTION OF WHICH VALUE WINS. A
/// `focusedSceneValue` published by several screens would be resolved by focus, and on a
/// split view with nothing focused that is not a rule anyone can state. The screens reach
/// the keyboard through ``ShellCommandCenter`` instead, which the shell owns.
struct ShellCommandActions {
    let availability: ShellCommandAvailability
    let select: (Tab) -> Void
    let newMessage: () -> Void
    let search: () -> Void
    let refresh: () -> Void
}

private struct ShellCommandActionsKey: FocusedValueKey {
    typealias Value = ShellCommandActions
}

extension FocusedValues {
    var shellCommands: ShellCommandActions? {
        get { self[ShellCommandActionsKey.self] }
        set { self[ShellCommandActionsKey.self] = newValue }
    }
}

/// The hardware-keyboard commands.
///
/// ⚠️ ⌘F SELECTS THE INBOX AND, FROM iOS 18, FOCUSES ITS SEARCH FIELD. iOS 17 has no public
/// way to focus a `.searchable` field (`searchFocused` arrived in 18), so on 17 the command
/// only brings the field on screen. The Inbox is the only screen with one.
struct DistrictCommands: Commands {
    @FocusedValue(\.shellCommands) private var shell

    private var availability: ShellCommandAvailability {
        shell?.availability ?? .unavailable
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { shell?.newMessage() }
                .keyboardShortcut("n")
                .disabled(!availability.canCompose)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Messages") { shell?.search() }
                .keyboardShortcut("f")
                .disabled(!availability.canSearch)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { shell?.refresh() }
                .keyboardShortcut("r")
                .disabled(!availability.canRefresh)
        }
        CommandMenu("Go") {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(tab.label) { shell?.select(tab) }
                    .keyboardShortcut(KeyEquivalent(ShellCommandAvailability.digit(for: tab)))
                    .disabled(!availability.canSelectSection)
            }
        }
    }
}

extension View {
    /// Publish the shell's keyboard commands and hand the screens below the center they
    /// answer through.
    ///
    /// ⛔ APPLIED WHERE THE SECTIONS ARE DRAWN AND NOWHERE ELSE, so the loading, empty and
    /// failed workspace states publish nothing and every command is disabled there.
    func shellCommands(
        _ center: ShellCommandCenter,
        paths: Binding<ShellPaths>,
        workspaceId: String?,
        role: WorkspaceRole?,
        regular: Bool
    ) -> some View {
        let availability = ShellCommandAvailability(
            workspaceId: workspaceId,
            role: role,
            refreshAvailable: center.canRefresh
        )
        // ⛔ EACH LAYOUT SELECTS THE WAY ITS OWN CONTROLS DO. The sidebar's setter builds a
        // hub's root and closes the open hub on Overview; the tab bar's reopens the hub the
        // Overview tab was showing. Choosing by the layout on screen is what makes ⌘1 do
        // exactly what a tap on the first row or the first tab would.
        let select: (Tab) -> Void = { tab in
            if regular, let workspaceId {
                paths.wrappedValue.setRegularSelection(SidebarItem(tab: tab), workspaceId: workspaceId, role: role)
            } else {
                paths.wrappedValue.compactTab = tab
            }
        }
        let actions = ShellCommandActions(
            availability: availability,
            select: select,
            newMessage: {
                guard availability.canCompose else { return }
                select(.inbox)
                center.composeRequested = true
            },
            search: {
                guard availability.canSearch else { return }
                select(.inbox)
                center.searchRequested = true
            },
            refresh: {
                guard availability.canRefresh else { return }
                Task { await center.refresh() }
            }
        )
        return environment(center)
            .focusedSceneValue(\.shellCommands, actions)
    }
}
