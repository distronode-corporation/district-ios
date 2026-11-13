import QuickLook
import SwiftUI

/// One RECEIVED attachment in a thread: an image drawn in place, any other file as a tile that
/// opens in Quick Look, and a sentence when it cannot be fetched.
///
/// ⛔ NOT ``ThreadMediaThumbnail``, WHICH STAYS THE REPLY BOX'S. The reply box only ever holds
/// images this app uploaded; a received message can carry whatever the sender's phone sent,
/// and `AsyncImage` cannot say what a body was, only that it did not decode. This view fetches
/// once, the same anonymous way (``ReceivedAttachmentLoader/anonymous``), and branches on the
/// `Content-Type` (``ReceivedAttachmentLoader/classify(data:response:)``).
///
/// ⚠️ QUICK LOOK BRINGS THE SHARE SHEET: its share button hands the file on (Files, Mail,
/// AirDrop, print). The temporary copy is removed when the preview closes.
struct ReceivedAttachmentView: View {
    let url: String
    var fetch: ReceivedAttachmentLoader.Fetch = ReceivedAttachmentLoader.anonymous

    @State private var phase: Phase = .loading
    @State private var preview: URL?

    @Environment(\.colorScheme) private var colorScheme

    private enum Phase {
        case loading
        case loaded(ReceivedAttachment)
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        content
            // ⛔ THE SAME BOX AS ``ThreadMediaThumbnail``: a fixed width for the column's
            // rhythm, a `minHeight` because three of the states are text that grows with the
            // text size.
            .frame(width: 96)
            .frame(minHeight: 96)
            .background(colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: DistrictRadius.control))
            // ⚠️ AN EDGE ON EVERY STATE BUT THE IMAGE: an inbound bubble is filled with the
            // same `muted` as this box, so a tile or a sentence had no outline at all.
            .overlay {
                if !showsImage {
                    RoundedRectangle(cornerRadius: DistrictRadius.control)
                        .strokeBorder(colors.border, lineWidth: 1)
                }
            }
            .task(id: url) {
                let loaded = await ReceivedAttachmentLoader.load(url, fetch: fetch)
                // ⚠️ A CANCELLED LOAD (the row scrolled away) SAYS NOTHING: it runs again on
                // the way back, and "can't be opened" would be untrue.
                guard !Task.isCancelled else { return }
                phase = .loaded(loaded)
            }
            .quickLookPreview($preview)
            .onChange(of: preview) { closed, now in
                if now == nil, let closed {
                    AttachmentPreviewFiles.discard(closed)
                }
            }
    }

    private var showsImage: Bool {
        if case .loaded(.image) = phase {
            return true
        }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            caption(InboxCopy.loadingAttachment)
        case let .loaded(.image(image)):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipped()
                .accessibilityLabel(InboxCopy.imageAttachment)
        case let .loaded(.file(file)):
            tile(file)
        case .loaded(.unavailable):
            unavailable
        }
    }

    private func tile(_ file: ReceivedAttachmentFile) -> some View {
        let name = file.typeName ?? InboxCopy.attachmentFile
        return Button {
            open(file)
        } label: {
            VStack(spacing: DistrictSpacing.hairline) {
                Image(systemName: file.symbol)
                    .font(.title2)
                    .foregroundStyle(colors.district)
                    .accessibilityHidden(true)
                Text(name)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.foreground)
                    .multilineTextAlignment(.center)
            }
            .padding(DistrictSpacing.hairline)
            .frame(maxWidth: .infinity, minHeight: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint(InboxCopy.attachmentOpenHint)
        .accessibilityIdentifier(A11yID.Inbox.attachmentFile)
    }

    private var unavailable: some View {
        VStack(spacing: DistrictSpacing.hairline) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(colors.mutedForeground)
                .accessibilityHidden(true)
            caption(InboxCopy.attachmentCannotOpen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Inbox.attachmentUnavailable)
    }

    /// Write the bytes where Quick Look can read them and present it.
    ///
    /// ⚠️ A WRITE THAT FAILS (a full disk) IS SAID THE SAME WAY as a fetch that failed, rather
    /// than a tap that does nothing.
    private func open(_ file: ReceivedAttachmentFile) {
        do {
            preview = try AttachmentPreviewFiles.write(file, named: InboxCopy.attachmentFile)
        } catch {
            phase = .loaded(.unavailable)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .multilineTextAlignment(.center)
            .padding(DistrictSpacing.hairline)
    }
}
