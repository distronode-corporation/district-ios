import DistrictData
import PhotosUI
import SwiftUI

/// One image target: what is published now, a picker, and a remove.
///
/// ⛔ THE BYTES CROSS INTO THE MODEL THROUGH ONE `@MainActor` CALL and nothing else
/// is carried across: `Data` is a value, the model owns every decision about it,
/// and the type and the size are refused there before a byte is uploaded. Same
/// seam the composer's attachment picker uses.
///
/// ⛔ AND THE REMOVE IS BEHIND A CONFIRMATION THOUGH THE WEB'S IS NOT. It is an
/// immediate write against the PUBLIC booking page that closing the sheet does not
/// undo, and on a phone it sits one thumb-width from the picker that replaces it.
///
/// ⚠️ A NIL OR THROWING LOAD IS "COULD NOT BE READ", WHICH IS NOT THE SAME AS A
/// REJECTED TYPE OR A REJECTED SIZE. Those three call for three different next
/// actions; collapsing them leaves an operator re-picking the same file.
struct SchedulingWritesBImageRow: View {
    let label: String
    let publishedUrl: String?
    let state: SchedulingWriteState
    let pickIdentifier: String
    let removeIdentifier: String
    let onPicked: (Data, String) -> Void
    let onRemove: () -> Void
    let onUnreadable: () -> Void

    /// ⚠️ A `PhotosPickerItem` THAT STAYS SELECTED IS EQUAL TO ITSELF, so picking
    /// the same image twice fires `onChange` only once. Clearing it after each read
    /// is what makes a re-pick of the same photo work at all.
    @State private var picked: PhotosPickerItem?
    @State private var confirmingRemove = false

    var body: some View {
        SettingsCard(eyebrow: label) {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                SettingsReadOnlyRow(label: label, value: publishedUrl)
                SchedulingWriteHint(text: SchedulingSettingsWriteCopy.imageHint)
                SchedulingWriteHint(text: SchedulingSettingsWriteCopy.imageImmediate)
                controls
                SchedulingWriteOutcome(state: state)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: DistrictSpacing.tight) {
            PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .compatible) {
                Text(SchedulingSettingsWriteCopy.imageChoose)
            }
            .disabled(state.isWorking)
            .accessibilityIdentifier(pickIdentifier)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task { await read(item) }
            }
            if publishedUrl != nil {
                Button(SchedulingSettingsWriteCopy.imageRemove) { confirmingRemove = true }
                    .buttonStyle(.districtDestructive)
                    .disabled(state.isWorking)
                    .accessibilityIdentifier(removeIdentifier)
                    .confirmationDialog(
                        SchedulingSettingsWriteCopy.imageRemove,
                        isPresented: $confirmingRemove,
                        titleVisibility: .visible
                    ) {
                        Button(SchedulingSettingsWriteCopy.imageRemove, role: .destructive, action: onRemove)
                        Button(SchedulingTeamWriteCopy.cancel, role: .cancel) {}
                    } message: {
                        Text(SchedulingSettingsWriteCopy.imageImmediate)
                    }
            }
        }
    }

    private func read(_ item: PhotosPickerItem) async {
        defer { picked = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            onUnreadable()
            return
        }
        onPicked(data, item.preferredMIMEType(allowed: SchedulingUploadFile.acceptedMimeTypes))
    }
}
