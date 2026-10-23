import SwiftUI

/// The latest conversations, unread first to the eye.
struct InboxView: View {
    let store: WatchStore
    /// nil when the phone could not read the inbox, which is not an empty one.
    let conversations: [WatchSnapshot.Conversation]?

    var body: some View {
        List {
            if let conversations {
                if conversations.isEmpty {
                    Text(WatchCopy.noConversations)
                        .foregroundStyle(.secondary)
                }
                ForEach(conversations) { conversation in
                    NavigationLink {
                        ThreadView(store: store, conversation: conversation)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                }
            } else {
                Text(WatchCopy.couldNotLoad)
                    .font(.footnote)
            }
        }
        .navigationTitle(WatchCopy.inbox)
    }
}

struct ConversationRow: View {
    let conversation: WatchSnapshot.Conversation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(conversation.unread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .accessibilityLabel(conversation.unread ? WatchCopy.unreadConversation : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(conversation.unread ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                Text(conversation.preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// One conversation's latest message, with Reply and Mark read.
///
/// ⚠️ THE PREVIEW ONLY. The watch holds what the snapshot carried, which is the latest
/// message's first line; the whole thread is on the phone.
struct ThreadView: View {
    let store: WatchStore
    let conversation: WatchSnapshot.Conversation

    @State private var draft = ""

    private var replyKey: String {
        WriteKey.reply(conversation.id)
    }

    private var sending: Bool {
        store.writes[replyKey] == .sending
    }

    var body: some View {
        List {
            Section {
                Text(conversation.preview)
                    .font(.footnote)
            } header: {
                Text(conversation.title)
            }
            if conversation.canReply {
                replySection
            } else {
                Text(WatchCopy.cannotReply)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if conversation.unread {
                Section {
                    Button(WatchCopy.markRead) {
                        Task { await store.markRead(conversation) }
                    }
                    .disabled(store.writes[WriteKey.markRead(conversation.id)] == .sending)
                    .accessibilityIdentifier("watch.thread.markRead")
                    WriteStatusRow(store: store, key: WriteKey.markRead(conversation.id))
                }
            }
        }
        .navigationTitle(WatchCopy.inbox)
    }

    private var replySection: some View {
        Section {
            WriteStatusRow(store: store, key: replyKey)
            // ⚠️ THE SYSTEM'S OWN INPUT: dictation, Scribble or the keyboard.
            TextField(WatchCopy.dictateReply, text: $draft)
                .onSubmit { send(draft) }
                .disabled(sending)
                .accessibilityIdentifier("watch.thread.compose")
            ForEach(CannedReply.all, id: \.self) { text in
                Button(text) { send(text) }
                    .disabled(sending)
            }
        } header: {
            Text(WatchCopy.reply)
        }
    }

    private func send(_ text: String) {
        Task {
            await store.reply(text, to: conversation)
            if store.writes[replyKey] == .succeeded(WatchCopy.replySent) {
                draft = ""
            }
        }
    }
}

/// The ready-made replies, in the watch's language.
enum CannedReply {
    static var all: [String] {
        [WatchCopy.cannedOnMyWay, WatchCopy.cannedCallBack, WatchCopy.cannedThanks, WatchCopy.cannedCantTalk]
    }
}
