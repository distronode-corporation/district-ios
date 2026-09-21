import SwiftUI

/// The detail column while a list beside it has no row open.
///
/// ⚠️ THE SYSTEM'S OWN EMPTY STATE RATHER THAN ``EmptyStateView``. That one says a list
/// HAS nothing ("No contacts yet"); this says a list has not been chosen from, which is
/// a different sentence, and `ContentUnavailableView` is the shape iPadOS already uses for
/// it in its own split views.
///
/// ⛔ ONLY EVER BESIDE A LIST. A section that is not a list fills the detail column with
/// its own screen, and a placeholder there would be a screen that does nothing.
struct DetailPlaceholder: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(A11yID.Sidebar.detailPlaceholder)
    }
}
