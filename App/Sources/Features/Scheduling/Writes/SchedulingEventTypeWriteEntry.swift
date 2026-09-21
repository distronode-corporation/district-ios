import DistrictData
import DistrictModel
import SwiftUI

/// "Create event type", on the list's header.
///
/// ⛔ THE TAKEN SLUGS COME FROM THE LIST THAT IS ON SCREEN, NOT FROM A SECOND READ.
/// ``SchedulingEventTypeEditorModel`` refuses a slug the tenancy already holds
/// before it spends a request, and the only honest source for that set is the rows
/// the operator is looking at. A list that failed to load therefore offers no
/// create control at all — see ``SchedulingEventTypesView``.
struct SchedulingEventTypeCreateButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let takenSlugs: [String]
    let onSaved: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingEventTypeEditorModel>?

    var body: some View {
        Button(SchedulingWriteCopy.createTitle) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.eventTypeCreate)
        .sheet(item: $editing) { entry in
            SchedulingEventTypeEditorSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingEventTypeEditorModel {
        SchedulingEventTypeEditorModel(
            admin: admin,
            workspaceId: workspaceId,
            takenSlugs: takenSlugs,
            onSaved: { _ in onSaved() }
        )
    }
}

/// The four writes one event type carries: the form, the state actions, its hosts
/// and its questions.
///
/// ⛔ IT TAKES THE LOADED ``SchedulingEventType`` RATHER THAN THE SLUG, AND THAT IS
/// WHAT KEEPS A FORM OFF A FAILED READ. `eventTypes.patch` sends the fields it was
/// given and `hosts.put` REPLACES the host list wholesale, so an editor opened over
/// a row this screen never loaded would save a form built from nothing. The detail
/// screen renders this only from `.ready`.
///
/// ⚠️ A DELETE IS NOT A REFRESH. `onDeleted` pops the screen, because re-reading a
/// slug the fork has just removed answers a refusal the operator did not cause.
struct SchedulingEventTypeWriteBar: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let eventType: SchedulingEventType
    let onChanged: () -> Void
    let onDeleted: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingEventTypeEditorModel>?
    @State private var actions: SchedulingWritePresentation<SchedulingEventTypeActionsModel>?
    @State private var hosts: SchedulingWritePresentation<SchedulingEventTypeHostsModel>?
    @State private var questions: SchedulingWritePresentation<SchedulingEventTypeQuestionsModel>?

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            HStack(spacing: DistrictSpacing.tight) {
                Button(SchedulingWriteCopy.edit) {
                    editing = SchedulingWritePresentation(model: editorModel())
                }
                .buttonStyle(.districtPrimary)
                .accessibilityIdentifier(A11yID.SchedulingWriteEntry.eventTypeEdit)
                Button(SchedulingWriteCopy.manage) {
                    actions = SchedulingWritePresentation(model: actionsModel())
                }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.SchedulingWriteEntry.eventTypeActions)
            }
            HStack(spacing: DistrictSpacing.tight) {
                Button(SchedulingWriteCopy.hostsTitle) {
                    hosts = SchedulingWritePresentation(model: hostsModel())
                }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.SchedulingWriteEntry.eventTypeHosts)
                Button(SchedulingWriteCopy.questionsTitle) {
                    questions = SchedulingWritePresentation(model: questionsModel())
                }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.SchedulingWriteEntry.eventTypeQuestions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { entry in
            SchedulingEventTypeEditorSheet(model: entry.model)
        }
        .sheet(item: $actions) { entry in
            SchedulingEventTypeActionsSheet(model: entry.model)
        }
        .sheet(item: $hosts) { entry in
            SchedulingEventTypeHostsSheet(model: entry.model)
        }
        .sheet(item: $questions) { entry in
            SchedulingEventTypeQuestionsSheet(model: entry.model)
        }
    }

    private func editorModel() -> SchedulingEventTypeEditorModel {
        SchedulingEventTypeEditorModel(
            admin: admin,
            workspaceId: workspaceId,
            editing: eventType,
            onSaved: { change in apply(change) }
        )
    }

    private func actionsModel() -> SchedulingEventTypeActionsModel {
        SchedulingEventTypeActionsModel(
            admin: admin,
            workspaceId: workspaceId,
            eventType: eventType,
            onSaved: { change in apply(change) }
        )
    }

    private func hostsModel() -> SchedulingEventTypeHostsModel {
        SchedulingEventTypeHostsModel(
            admin: admin,
            workspaceId: workspaceId,
            eventType: eventType,
            onSaved: { _ in onChanged() }
        )
    }

    private func questionsModel() -> SchedulingEventTypeQuestionsModel {
        SchedulingEventTypeQuestionsModel(
            admin: admin,
            workspaceId: workspaceId,
            slug: eventType.slug,
            onSaved: { _ in onChanged() }
        )
    }

    private func apply(_ change: SchedulingEventTypeChange) {
        switch change {
        case .saved:
            onChanged()
        case .deleted:
            onDeleted()
        }
    }
}
