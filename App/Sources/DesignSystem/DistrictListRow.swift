import SwiftUI

/// One list row: optional leading slot, title, optional subtitle, optional trailing
/// slot. Ported from Android's `DistrictListRow.kt`.
///
/// ⛔ THE TRAILING SLOT SITS NEXT TO THE TEXT, NOT AT THE SCREEN EDGE. The Android
/// rows were full-bleed, so each row's status ended up an inch from the name it
/// described with an empty desert between them. Capping the text column and giving
/// the row a trailing slot are two halves of one fix.
///
/// ⛔ NO `onTap` PARAMETER, DELIBERATELY, AND IT IS NOT AN OMISSION. On iOS a
/// tappable row is a `NavigationLink` or a `Button` WRAPPING this view, which is
/// what gives it the disclosure affordance, the press highlight, the accessibility
/// button trait and the swipe actions a `List` provides. A tap gesture attached in
/// here would give none of those and would fight the enclosing `List` for the
/// gesture.
///
/// ⚠️ NO POINTER EFFECT HERE, FOR THE SAME REASON THERE IS NO TAP. The `List` cell, the
/// `NavigationLink` or the `Button` wrapping this row already answers the pointer, and a
/// second effect on the content would draw two highlights, one inside the other.
///
/// ⚠️ 56pt minimum, not the 44pt touch-target floor. Two lines of text need more
/// than 44pt before they start to feel wedged in, and most rows here have a
/// subtitle.
///
/// ⛔ THE TEXT COLUMN YIELDS AND THE TRAILING SLOT DOES NOT, AND THAT ORDERING HAS TO
/// BE STATED OR `HStack` SPLITS THE SHORTFALL BETWEEN THEM. Once, nothing
/// here expressed it: every subview sat at layout priority 0, so when the children's
/// ideal widths exceeded the row, `HStack` proposed each of them a proportional share
/// and every `Text` in the row complied by WRAPPING. On the call log that rendered as
/// "Transferr/ed" and "complet/ed" in the pills AND a two-line subtitle at the same
/// time, on exactly the rows carrying two pills; one-pill rows were fine because their
/// ideal widths still fitted, which is what made it look like a badge bug rather than
/// a row-layout one.
///
/// ⚠️ `.frame(maxWidth: .infinity)` ON THE TEXT COLUMN DOES NOT MAKE IT YIELD. It makes
/// it GREEDY, and greed only decides who takes the SURPLUS. Under a shortfall the frame
/// passes the reduced proposal straight through to the `Text`s inside it.
///
/// So: `layoutPriority(1)` on the trailing slot, which makes `HStack` size it first
/// against the full available width and hand the remainder to the text column; and
/// `lineLimit(1)` on both `Text`s, so the column that yields TRUNCATES rather than
/// growing the row. ``DistrictBadge`` holds the other half, keeping one pill's label on
/// one line.
///
/// ⛔ AND THE TRAILING SLOT IS DELIBERATELY NOT `fixedSize`. That would pin it to its
/// ideal width against any proposal, which is right for two pills and wrong for
/// ``ConversationRow``, whose trailing slot can emit FIVE (channel labels, status,
/// "Draft", the unread count): a fixed-size slot wider than the row pushes the text
/// column to zero and overflows the right edge, where content is unreachable rather
/// than merely cramped. Priority gives the pills their full width whenever it exists
/// and lets the slot compress only when nothing else can, which is the honest ordering.
struct DistrictListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme

    /// ⛔ THE ONE SWITCH THIS ROW MAKES FOR LARGER TEXT. `isAccessibilitySize` is true
    /// from AX1 up, which is where a one-line title stops being a tidy truncation and
    /// starts being the row saying nothing: at AX5 a 56pt row holds about three words.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ WRITTEN OUT RATHER THAN LEFT TO THE MEMBERWISE INITIALISER. `@ViewBuilder`
    /// on a stored property does hand the synthesised initialiser a builder closure,
    /// but leaning on that subtlety makes a failure an inference error inside every
    /// call site rather than here.
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        // ⛔ `AnyLayout` RATHER THAN AN `if`, SO THE SUBTREE KEEPS ITS IDENTITY. Two
        // branches returning different containers would make SwiftUI tear down and
        // rebuild the row on every size change, losing scroll position and any
        // in-flight animation; `AnyLayout` swaps the ARRANGEMENT around the same views.
        //
        // ⚠️ AT AN ACCESSIBILITY SIZE THE TRAILING SLOT GOES UNDERNEATH rather than
        // beside. It holds badges and chevrons, and at AX5 a `layoutPriority(1)`
        // trailing view takes the width it needs and leaves the title three words.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.tight))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.row))
        return layout {
            leading
            VStack(alignment: .leading, spacing: 2) {
                // ⛔ ONE LINE EACH. This is the half of the fix that decides HOW the
                // text column yields: without it a narrow proposal is absorbed by
                // wrapping, which both breaks the 56pt rhythm and hides that the row
                // ran out of width. Truncating says the same thing and keeps the row.
                // ⚠️ THE LIMIT IS LIFTED AT AN ACCESSIBILITY SIZE, which is the
                // opposite of the ⛔ above and does not contradict it: truncating is
                // right when the row is losing a few characters and wrong when it is
                // losing the sentence. Apple's own bar is that text WRAPS rather than
                // truncating to a line at the accessibility sizes.
                Text(title)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⛔ SIZED BEFORE THE TEXT COLUMN. See the ⛔ on the type: at equal
            // priority the pills and the subtitle both wrapped.
            // ⚠️ THE PRIORITY IS DROPPED WHEN STACKED. In a VStack it would make the
            // badge claim vertical space ahead of the wrapped title, which is the
            // same crush one axis over.
            trailing
                .layoutPriority(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.vertical, DistrictSpacing.row)
        .frame(minHeight: 56)
        // ⛔ THE ROW IS THE TAP TARGET, WHOLE. Without this a `Button` or
        // `NavigationLink` wrapping the row hit-tests only the UNION OF THE GLYPH
        // BOUNDS, so the gutter padding, the vertical padding and the dead space
        // between the text column and the trailing slot are all inert — which is
        // most of the row. It was reported as "only the text or the chevron is
        // tappable" on the Overview entries, the Settings hub, Account and the dialer
        // callbacks; all of them wrap THIS view, so the fix
        // belongs here and nowhere else. It is a no-op for the `List`-hosted rows
        // (Calls, Contacts, Inbox), which already hit-test full width.
        .contentShape(Rectangle())
        // ⛔ ONE ELEMENT, NOT FOUR. Without this VoiceOver walks the avatar, the
        // title, the subtitle and every badge in the trailing slot as separate
        // stops: a Contacts list of thirty people is a hundred and twenty swipes,
        // and the initials in the avatar are read out as a word before each name.
        // `.combine` concatenates the descendants' labels into one announcement in
        // layout order — which is the reading order the row was designed in.
        //
        // ⚠️ SAFE ONLY BECAUSE NO TRAILING SLOT HOLDS A CONTROL. `.combine` flattens
        // its children, so a Toggle or Button in there would lose its action and its
        // trait. Checked across every call site: every trailing slot is a badge, a
        // chevron, a tick or a glyph, and the sign-out Button WRAPS its row rather
        // than sitting inside it. A future interactive slot means
        // `.contain` here and an explicit label, not `.combine`.
        .accessibilityElement(children: .combine)
    }
}

// ⚠️ THREE CONSTRAINED INITIALISERS RATHER THAN DEFAULTED GENERIC CLOSURES. A
// default argument that pins a generic parameter (`leading: () -> Leading = {
// EmptyView() }`) compiles but makes the inference failure, when a caller supplies
// only the other slot, unreadable. Constrained extensions say the same thing to the
// type checker and produce an error naming the initialiser that does not exist.
//
// ⛔ ALWAYS LABEL THE SLOT. `DistrictListRow(title: "x") { … }` with a TRAILING
// closure is `ambiguous use of 'init'`: the two single-slot initialisers below are
// equally good candidates and the compiler cannot tell which one you meant. Measured
// against a Linux type-check of this exact shape, not assumed. Write
// `leading: { … }` or `trailing: { … }`.

extension DistrictListRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

extension DistrictListRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, leading: leading, trailing: { EmptyView() })
    }
}

extension DistrictListRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The list separator.
///
/// ⚠️ Inset to the text column so it does not cut across a leading avatar: a
/// full-bleed rule under a circle reads as a strikethrough.
struct DistrictRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Rectangle()
            .fill(colors.border)
            .frame(height: 1)
            .padding(.leading, DistrictSpacing.gutter)
    }
}

/// Initials in a tinted circle.
///
/// ⚠️ EXISTS TO GIVE A LIST ROW A LEFT ANCHOR. Rows of bare text separated by rules
/// read as a spreadsheet; a consistent leading element gives the eye a column to
/// travel down. It is also the cheapest possible avatar: no image loading, so no
/// placeholder or error states.
///
/// ⚠️ FALLS BACK TO A SINGLE GLYPH RATHER THAN RENDERING EMPTY. An unnamed contact
/// is common (the voice agent writes "Unknown" for an unidentified caller) and an
/// empty circle looks like a loading failure rather than an absence of data.
struct DistrictAvatar: View {
    let name: String
    var tone: Tone = .district

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        // ⚠️ THE AVATAR IS THE SAME INK-ON-TINT PAIR AS A BADGE, so it takes the same
        // switch. Initials in a tinted circle are the one place a name is reduced to
        // two characters, which makes them the worst place to lose half a point of
        // contrast.
        let increased = colorSchemeContrast == .increased
        return Circle()
            .fill(tone.fill(colors, increasedContrast: increased))
            .frame(width: 36, height: 36)
            .overlay {
                Text(initials)
                    .font(DistrictType.label)
                    .foregroundStyle(tone.ink(colors, increasedContrast: increased))
            }
    }

    private var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
        return letters.isEmpty ? "·" : letters
    }
}
