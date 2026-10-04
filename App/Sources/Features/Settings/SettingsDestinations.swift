import DistrictModel
import SwiftUI

/// The one place a ``SettingsSection`` becomes a screen.
///
/// ⛔ ITS OWN SWITCH RATHER THAN EIGHT MORE ARMS IN ``RouteDestinations``, AND THAT IS
/// A LINT CEILING AS WELL AS A READABILITY ONE. `swiftlint --strict` caps cyclomatic
/// complexity at 10 and that switch is already at its limit with the whole route table
/// grouped; adding a section per arm there would break it, and grouping the sections
/// would defeat the exhaustiveness the outer switch exists to keep. The outer table
/// stays one line per destination FAMILY, this one is one line per section, and both
/// stay exhaustive — a new ``SettingsSection`` case fails to compile here until someone
/// decides what it shows.
///
/// ⚠️ `hub` AND `scheduling` ARE THE TWO ARMS THAT ARE NOT A FORM. `hub` is the list
/// itself, and `scheduling` is unreachable in practice because ``SettingsHubView``
/// navigates to `Route.scheduling` rather than to this section — the screen already
/// exists and resolves `canManage` from the server's own status route, which is a
/// better gate than a role string. It is handled anyway rather than grouped away,
/// because a `Route` restored from a back stack or arriving from a deep link can carry
/// any section, and falling through to the wrong screen is worse than showing the hub.
enum SettingsDestinations {
    @MainActor
    @ViewBuilder
    static func view(
        for section: SettingsSection,
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?
    ) -> some View {
        switch section {
        case .hub, .scheduling:
            SettingsHubView(workspaceId: workspaceId, role: role)

        // ⛔ IT TAKES A ROLE BECAUSE IT WRITES MORE THAN THREE STRINGS AND BECAUSE ITS
        // PREVIEW SPENDS MONEY. `workspace/config` already excludes a viewer, so the
        // row is hidden — but a control that was not drawn is not a boundary, and the
        // persona form moves the engine, voice, language and style as well as
        // minting billed audition sessions.
        case .persona:
            PersonaView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ IT TAKES A ROLE FOR THE SAME REASON: its save moves the engine every call runs on.
        case .voiceStudio:
            VoiceStudioView(container: container, workspaceId: workspaceId, role: role)

        case .capabilities:
            CapabilitiesView(container: container, workspaceId: workspaceId)

        // ⛔ THE ONE CONFIG-SHAPED SECTION THAT DOES NOT HYDRATE FROM `workspace/config`,
        // WHICH IS WHY IT TAKES A ROLE AND ITS TWO NEIGHBOURS DO NOT.
        // `workspace/call-handling` has its own GET, that GET admits a `viewer`, and its
        // PATCH writes scalars and ECHOES them — so the screen is offered read-only and
        // gates its own controls, exactly as knowledge and messaging do.
        case .calls:
            CallHandlingView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ THE TWO WHOLESALE-REPLACE ARRAYS, AND BOTH ARE EDITORS. Each one's save
        // REPLACES its stored array, so both take a role and both gate every write in
        // their model. ⚠️ The routing rules' only server-side validation is a
        // per-workspace voice and model allow-list nothing here can see, and the answer
        // to that is not a refusal: the editor offers the catalogue `persona/options`
        // publishes, pre-validates against nothing, and shows the server's refusal
        // verbatim — which names the value it rejected.
        case .directory:
            DirectoryView(container: container, workspaceId: workspaceId, role: role)

        case .routing:
            RoutingView(container: container, workspaceId: workspaceId, role: role)

        // ⚠️ THE THREE THAT DO NOT HYDRATE FROM `workspace/config`, WHICH IS ALSO THE
        // LINE THE ROLE GATE FALLS ON: the knowledge and messaging READS admit a
        // viewer, so both screens gate their own controls rather than being hidden.
        case .knowledge:
            KnowledgeView(container: container, workspaceId: workspaceId, role: role)

        case .messaging:
            MessagingView(container: container, workspaceId: workspaceId, role: role)

        case .members:
            MembersView(container: container, workspaceId: workspaceId, role: role)
        }
    }
}
