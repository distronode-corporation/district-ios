import DistrictModel
import SwiftUI

/// What the composer shows in place of the reply box when the WhatsApp window has
/// closed: the website's sentence, and the button that opens the template sheet.
struct WhatsAppClosedWindow: View {
    let model: ThreadModel

    @State private var choosing = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(InboxCopy.whatsappWindowClosed)
                .font(DistrictType.caption)
                .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(InboxCopy.whatsappTemplatePlaceholder) { choosing = true }
                .buttonStyle(.districtPrimary)
                .accessibilityIdentifier(A11yID.Inbox.whatsAppTemplates)
        }
        .sheet(isPresented: $choosing) {
            WhatsAppTemplateSheet(model: model)
                .districtSheetBackground()
        }
    }
}

/// The sender's approved templates; one chosen, its variables, a preview and Send.
///
/// ⛔ ONLY APPROVED TEMPLATES ARE LISTED (``WhatsAppTemplate/isSendable``): Meta refuses
/// any other, and the website's picker offers the same set.
struct WhatsAppTemplateSheet: View {
    let model: ThreadModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(InboxCopy.whatsappTemplateLabel)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: TemplatePick.self) { pick in
                    if let template = template(pick.id) {
                        WhatsAppTemplateForm(model: model, template: template) { dismiss() }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(InboxCopy.cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .task { await model.loadWhatsAppTemplates() }
        }
        .accessibilityIdentifier(A11yID.Inbox.whatsAppTemplates)
    }

    private func template(_ id: String) -> WhatsAppTemplate? {
        guard case let .ready(templates) = model.whatsApp.templates else { return nil }
        return templates.first { $0.id == id }
    }

    @ViewBuilder
    private var content: some View {
        switch model.whatsApp.templates {
        case .idle, .loading:
            VStack(spacing: DistrictSpacing.tight) {
                ProgressView()
                Text(InboxCopy.whatsappTemplatesLoading)
                    .font(DistrictType.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(failure):
            FailureView(failure: FailureText(message: InboxCopy.whatsappTemplatesFailed, action: failure.action)) {
                Task { await model.loadWhatsAppTemplates() }
            }
        case let .ready(templates) where templates.isEmpty:
            EmptyStateView(
                systemImage: "text.bubble",
                title: InboxCopy.whatsappTemplateLabel,
                message: InboxCopy.whatsappTemplatesNone
            )
        case let .ready(templates):
            List(templates, id: \.id) { template in
                NavigationLink(value: TemplatePick(id: template.id)) {
                    VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                        HStack(spacing: DistrictSpacing.tight) {
                            Text(template.name)
                                .font(DistrictType.titleSmall)
                            DistrictBadge(text: template.language, tone: .neutral)
                        }
                        Text(template.body)
                            .font(DistrictType.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

/// One template: a field per variable, the filled text, and Send.
private struct WhatsAppTemplateForm: View {
    let model: ThreadModel
    let template: WhatsAppTemplate
    let onSent: () -> Void

    @State private var values: [String] = []

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var count: Int {
        ThreadModel.templateVariableCount(template)
    }

    private var complete: Bool {
        ThreadModel.templateComplete(template, values)
    }

    var body: some View {
        Form {
            if count > 0 {
                Section {
                    ForEach(0 ..< count, id: \.self) { index in
                        TextField(InboxCopy.whatsappTemplateVariable(index + 1), text: binding(index))
                            .disabled(model.whatsApp.sendingTemplate)
                    }
                } footer: {
                    if !complete {
                        Text(InboxCopy.whatsappTemplateVariableRequired)
                    }
                }
            }
            Section(InboxCopy.whatsappTemplatePreview) {
                Text(preview)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
            }
            if let failure = model.whatsApp.templateFailure {
                Section {
                    Text(failure.message)
                        .foregroundStyle(colors.destructive)
                }
            }
            Section {
                Button(model.whatsApp.sendingTemplate ? InboxCopy.sending : InboxCopy.whatsappTemplateSend) {
                    Task {
                        if await model.sendWhatsAppTemplate(template, variables: values) {
                            onSent()
                        }
                    }
                }
                .disabled(!complete || model.whatsApp.sendingTemplate)
                .accessibilityIdentifier(A11yID.Inbox.whatsAppTemplateSend)
            }
        }
        .navigationTitle(template.name)
        .onAppear {
            model.clearTemplateFailure()
            if values.count != count {
                values = Array(repeating: "", count: count)
            }
        }
    }

    /// ⚠️ A BLANK VARIABLE STAYS `{{n}}` IN THE PREVIEW, so the operator sees where it
    /// goes; ``WhatsAppTemplate/filled(with:)`` would print nothing there.
    private var preview: String {
        let shown = (0 ..< count).map { index in
            let value = index < values.count ? values[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return value.isEmpty ? "{{\(index + 1)}}" : value
        }
        return template.filled(with: shown)
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < values.count ? values[index] : "" },
            set: { value in
                if index < values.count {
                    values[index] = value
                }
            }
        )
    }
}

/// The navigation value for one template: its id, looked up in the loaded list.
private struct TemplatePick: Hashable {
    let id: String
}
