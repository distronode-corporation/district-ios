import SwiftUI

/// The members a conversation can be assigned to, Unassigned first, the current owner
/// ticked. One tap writes; the sheet closes when the server affirms it.
///
/// ⚠️ THE WEB'S PICKER, AS A LIST. The website's thread header holds a select with the
/// same options (`ThreadAssignee.tsx`): Unassigned, then each member's address. A
/// phone has no room for a select in a row, so the row's swipe action opens this.
struct ThreadAssignSheet: View {
    let model: ThreadAssignModel
    let onAssigned: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(InboxCopy.assignLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(InboxCopy.cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .task { await model.load() }
        }
        .accessibilityIdentifier(A11yID.Inbox.assignSheet)
    }

    @ViewBuilder
    private var content: some View {
        switch model.members {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(failure):
            FailureView(failure: failure) { Task { await model.load() } }
        case let .ready(emails):
            List {
                Section {
                    row(InboxCopy.unassigned, email: nil)
                    ForEach(emails, id: \.self) { email in
                        row(email, email: email)
                    }
                } footer: {
                    if let failure = model.failure {
                        Text(failure.message)
                            .foregroundStyle(DistrictColors.resolve(colorScheme).destructive)
                    }
                }
            }
            .disabled(model.saving)
        }
    }

    private func row(_ title: String, email: String?) -> some View {
        Button {
            Task { await choose(email) }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isCurrent(email) {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isCurrent(email) ? .isSelected : [])
    }

    private func isCurrent(_ email: String?) -> Bool {
        guard let email else { return model.current == nil }
        return model.current?.caseInsensitiveCompare(email) == .orderedSame
    }

    /// ⚠️ CHOOSING THE CURRENT OWNER CLOSES WITHOUT A WRITE: the server would answer the
    /// same assignment and push the assignee again.
    private func choose(_ email: String?) async {
        guard !isCurrent(email) else {
            dismiss()
            return
        }
        guard await model.assign(email) else { return }
        onAssigned()
        dismiss()
    }
}
