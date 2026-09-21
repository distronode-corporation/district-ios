import SwiftUI

/// Page-level layout limits that are not spacing.
enum DistrictLayout {
    /// The widest a column of forms, cards or running text is allowed to grow,
    /// measured across the page gutters.
    ///
    /// ⚠️ WIDER THAN ANY PHONE ON PURPOSE, so the cap only ever engages on a regular-
    /// width layout: the largest iPhone in portrait is well under it, and on a phone the
    /// app does not rotate. The detail column of a full-screen split view on a large
    /// iPad is half as wide again, which is where a text field stretched edge to edge
    /// stops reading as a field.
    static let readableWidth: CGFloat = 700
}

extension View {
    /// Caps a page's content column at ``DistrictLayout/readableWidth`` and centres it,
    /// leaving whatever sits behind it (the page background, the scroll view and its
    /// indicator) at the full width of the column it is in.
    ///
    /// ⛔ APPLIED TO THE CONTENT, INSIDE THE `ScrollView`, NEVER TO THE `ScrollView`
    /// ITSELF. Capping the scroll view would move its indicator into the middle of the
    /// screen and turn the margins either side into dead zones a drag cannot start in.
    ///
    /// ⚠️ IT REPLACES THE PAGE'S `frame(maxWidth: .infinity, alignment: .leading)` RATHER
    /// THAN SITTING BESIDE IT, and that frame is the first thing it applies, so on any
    /// width below the cap the result is exactly the layout the screen had before: the
    /// middle frame proposes the width it was given and the outer one has nothing to
    /// centre. Apply it after the gutter padding, which the cap then includes.
    ///
    /// ⛔ NOT FOR A LIST THAT SITS BESIDE ITS DETAIL. A content column in a three-column
    /// split view is already as narrow as the system makes it, and a selectable row
    /// with margins either side would highlight a band rather than the row.
    func districtReadableWidth() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: DistrictLayout.readableWidth)
            .frame(maxWidth: .infinity)
    }
}
