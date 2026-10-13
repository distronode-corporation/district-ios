import Foundation

/// Every sentence District HQ says on this client.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF `HQView.swift`, AND THAT
/// IS A LINT CEILING RATHER THAN A DESIGN STATEMENT, the same call ``DialerCopy`` and
/// ``OverviewEntry`` make. `swiftlint --strict` promotes the `file_length` WARNING at
/// 500 lines to an error.
///
/// ⚠️ HOISTED TO `String` CONSTANTS RATHER THAN WRITTEN INLINE, for the reason
/// `DevicesView` records: a literal handed straight to an API carrying both a
/// `LocalizedStringKey` and a `StringProtocol` overload is an inference question at the
/// call site, and the error lands far from the literal.
///
/// ⛔ THE COPY IS ANDROID'S, WORD FOR WORD WHERE ANDROID HAS A STRING. Two clients
/// answering "did that change apply" with two different sentences is how one of them
/// ends up wrong; the Android client's string resources are the source.
enum HQCopy {}
