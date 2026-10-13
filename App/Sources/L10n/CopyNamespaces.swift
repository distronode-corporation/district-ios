// The namespaces for screens whose sentences were written inline before they moved into
// `l10n/ios.toml`. Every member is generated (`Generated/Copy.swift`, one `extension`
// per enum), so each enum here is empty and exists only for the generated file to extend.
//
// ⚠️ A SCREEN THAT ALREADY HAD A `*Copy` ENUM KEPT IT. These are only the features that
// had none: their views said their words as literals.

/// The Account screen.
enum AccountCopy {}

/// The Analytics screen and its cards.
enum AnalyticsCopy {}

/// The call log and a call's detail.
enum CallsCopy {}

/// Words shared by the design system and the platform layer: retry and sign-in buttons,
/// the row context menu, the notification actions.
enum CommonCopy {}

/// The contact list, a contact's detail and its dossier.
enum ContactsCopy {}

/// The signed-in devices list.
enum DevicesCopy {}

/// The dialer and the in-call screen. ``DialerModel`` and ``InCallCopy`` keep the
/// sentences they already held.
enum DialerCopy {}

/// The inbox, the compose sheet and a conversation thread.
enum InboxCopy {}

/// The shell: the sidebar, the menu commands and the workspace gate.
enum NavigationCopy {}

/// The Overview screen.
enum OverviewCopy {}

/// The workspace header and picker.
enum WorkspacesCopy {}
