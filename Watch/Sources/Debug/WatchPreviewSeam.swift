#if DEBUG

    import SwiftUI
    import WidgetKit

    /// Debug-only screens with made-up data, for screenshots of states a simulator cannot
    /// reach without a signed-in phone.
    ///
    /// ⛔ COMPILED OUT OF RELEASE, LIKE THE iPHONE'S `UITestSession`: the whole file is inside
    /// `#if DEBUG`, so no archive carries it. Armed only by launch arguments:
    ///
    ///     -WatchPreview demo|signedOut|update   which state to show (nothing is sent or kept)
    ///     -WatchPreviewScreen home|calls|call|inbox|thread|complication
    ///     -WatchPreviewLanguage en|fr-CA        the phone's language in the made-up snapshot
    ///     -WatchPreviewStale                    a snapshot 25 minutes old
    ///     -WatchPreviewWrite unreachable|failed the thread's reply state
    ///
    /// ⚠️ THE WATCH CONNECTIVITY SESSION IS NOT STARTED WHILE ARMED, so a real snapshot cannot
    /// replace the made-up one mid-screenshot.
    enum WatchPreviewSeam {
        static func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        static var screen: String? {
            argument("-WatchPreviewScreen")
        }

        /// Arm the store with made-up state. False when no preview was asked for.
        @MainActor
        static func apply(to store: WatchStore) -> Bool {
            guard let mode = argument("-WatchPreview") else { return false }
            let language = argument("-WatchPreviewLanguage") ?? "en"
            let stale = ProcessInfo.processInfo.arguments.contains("-WatchPreviewStale")
            let now = Date()
            switch mode {
            case "signedOut":
                store.preview(.snapshot(.signedOut(at: now, language: language)))
            case "update":
                store.preview(.versionMismatch(WatchSnapshot.currentProtocolVersion + 1))
            default:
                let snapshot = demo(at: stale ? now.addingTimeInterval(-25 * 60) : now, language: language)
                var writes: [String: WatchWriteState] = [:]
                let key = WriteKey.reply(snapshot.conversations?.first?.id ?? "")
                switch argument("-WatchPreviewWrite") {
                case "unreachable":
                    writes[key] = .unreachable
                case "failed":
                    let french = language == "fr-CA"
                    writes[key] = .failed(
                        title: WatchCopy.replyNotSent,
                        reason: french
                            ? "Vous n'avez pas la permission de faire cela dans cet espace de travail."
                            : "You do not have permission to do that in this workspace."
                    )
                default:
                    break
                }
                store.preview(.snapshot(snapshot), writes: writes)
            }
            return true
        }

        @MainActor @ViewBuilder
        static func view(for screen: String, store: WatchStore) -> some View {
            if let snapshot = store.snapshot {
                switch screen {
                case "calls":
                    NavigationStack { CallsView(store: store, calls: snapshot.calls) }
                case "call":
                    NavigationStack {
                        if let call = snapshot.calls?.first {
                            CallDetailView(store: store, call: call)
                        }
                    }
                case "inbox":
                    NavigationStack {
                        InboxView(store: store, conversations: snapshot.conversations)
                            .watchDestinations(store: store, snapshot: snapshot)
                    }
                case "thread":
                    NavigationStack {
                        if let conversation = snapshot.conversations?.first {
                            ThreadView(store: store, conversation: conversation)
                        }
                    }
                case "complication":
                    complications(ComplicationState(snapshot))
                default:
                    WatchRootView(store: store)
                }
            } else if screen == "complication" {
                complications(ComplicationState(signedIn: false, workspaceName: nil, available: nil, language: nil))
            } else {
                WatchRootView(store: store)
            }
        }

        /// The three families on one screen, roughly at their sizes on a face.
        @MainActor
        private static func complications(_ state: ComplicationState) -> some View {
            VStack(spacing: 10) {
                ComplicationView(state: state, family: .accessoryCircular)
                    .frame(width: 50, height: 50)
                ComplicationView(state: state, family: .accessoryRectangular)
                    .frame(height: 50)
                    .padding(.horizontal, 8)
                ComplicationView(state: state, family: .accessoryInline)
                    .font(.footnote)
            }
        }

        private static func demo(at date: Date, language: String) -> WatchSnapshot {
            let french = language == "fr-CA"
            let ago = { (minutes: Double) in date.addingTimeInterval(-minutes * 60) }
            let relative = { (minutes: Double) in
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                formatter.locale = Locale(identifier: french ? "fr_CA" : "en_CA")
                return formatter.localizedString(for: ago(minutes), relativeTo: date)
            }
            return WatchSnapshot(
                protocolVersion: WatchSnapshot.currentProtocolVersion,
                generatedAt: date,
                language: language,
                signedIn: true,
                workspace: .init(id: "ws_demo", name: "Plomberie Desrosiers"),
                availability: .init(workspaceId: "ws_demo", available: true, canToggle: true, note: nil),
                unreadCount: 3,
                calls: [
                    .init(
                        id: "c1", caller: "Marie Tremblay", direction: french ? "Entrant" : "Inbound",
                        time: french ? "23 oct. 2026, 14 h 05" : "Oct 23, 2026 at 2:05 PM",
                        relativeTime: relative(12), occurredAt: ago(12),
                        outcome: french ? "Terminé" : "Completed", duration: "3m 12s"
                    ),
                    .init(
                        id: "c2", caller: "••• 0134", direction: french ? "Entrant" : "Inbound",
                        time: french ? "23 oct. 2026, 13 h 20" : "Oct 23, 2026 at 1:20 PM",
                        relativeTime: relative(57), occurredAt: ago(57),
                        outcome: french ? "Sans réponse" : "No answer", duration: nil
                    ),
                    .init(
                        id: "c3", caller: "Jean Lavoie", direction: french ? "Sortant" : "Outbound",
                        time: french ? "23 oct. 2026, 10 h 41" : "Oct 23, 2026 at 10:41 AM",
                        relativeTime: relative(216), occurredAt: ago(216),
                        outcome: french ? "Terminé · Transféré" : "Completed · Transferred", duration: "6m 40s"
                    ),
                ],
                conversations: [
                    .init(
                        id: "contact:c_1", workspaceId: "ws_demo", title: "Marie Tremblay",
                        preview: french ? "↓ Pouvez-vous passer demain matin ?" : "↓ Can you come by tomorrow morning?",
                        unread: true, canReply: true
                    ),
                    .init(
                        id: "addr:14165550134", workspaceId: "ws_demo", title: "••• 0134",
                        preview: french ? "↓ Merci pour la soumission." : "↓ Thanks for the quote.",
                        unread: true, canReply: true
                    ),
                    .init(
                        id: "contact:c_3", workspaceId: "ws_demo", title: "Jean Lavoie",
                        preview: french ? "↑ C'est confirmé pour jeudi." : "↑ Confirmed for Thursday.",
                        unread: false, canReply: true
                    ),
                ]
            )
        }
    }

#endif
