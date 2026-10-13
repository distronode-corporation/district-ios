import Foundation

/// Every sentence the workspace settings hub and its sections say.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A MODEL, the same call
/// ``DialerCopy`` and ``IncomingCallCopy`` make and for the same reason: `swiftlint
/// --strict` promotes the `file_length` warning at 500 lines to an error, and this
/// surface is eight screens' worth of copy. Keeping it in one place also means the
/// four sentences that have to AGREE with each other (the load failure, the
/// not-editable notice, the saved-but-stale banner and the viewer note) are
/// readable side by side rather than scattered across eight files.
///
/// ⛔ THE WORDING IS THE PRODUCT ON THIS SURFACE, NOT DECORATION. Three of its save
/// routes replace a stored array wholesale, so the difference between "we could not
/// read your configuration" and "your configuration is empty" is the difference
/// between a retry and a deletion; and the difference between "saved" and "saved,
/// but we could not read it back" is what stops an operator saving a second time
/// from a baseline that has moved. Read the ⛔s beside each string before rewriting
/// one.
enum SettingsCopy {}
