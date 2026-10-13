/// District Desk and its new-ticket form.
///
/// ⚠️ `root` AND THE `compose*` STRINGS ARE ANDROID'S, copied verbatim from `DeskScreen.kt`
/// and `DeskComposeSheet.kt`. `newTicket` is iOS-first: Android's button carries no tag.
extension A11yID {
    enum Desk {
        static let root = "district-desk-root"
        static let newTicket = "district-desk-new-ticket"
        static let composeRoot = "district-desk-compose-root"
        static let composeCancel = "district-desk-compose-cancel"
        static let composeFailure = "district-desk-compose-failure"
        /// ⛔ A FORBIDDEN SURFACE: it puts a real ticket in a live workspace's queue.
        static let composeSubmit = "district-desk-compose-submit"
    }
}
