import SwiftUI

/// The type scale, mirroring the Android client's `DistrictType.kt`.
///
/// ⛔ THE SYSTEM FACE, NOT GEIST, AND THAT IS A DELIBERATE DIVERGENCE FROM ANDROID.
/// The web ships Geist through `next/font/google`; the Android client bundles three
/// static TTFs because Compose cannot consume woff2. Bundling them here would mean
/// adding font files to the app target and a `UIAppFonts` key to `Info.plist`,
/// which is generated from `project.yml`. San Francisco at the same sizes and
/// weights is the honest interim: the scale is what the layouts are built on, and
/// the face can be swapped in one file later without moving a single call site.
///
/// ⚠️ SIZES COME FROM REAL COMPONENTS, NOT FROM A DEFAULT TABLE. The web sets no
/// custom type scale, so the anchors are the components themselves: `PageHeader` is
/// `text-2xl md:text-3xl font-semibold`, the login card title is
/// `text-3xl md:text-4xl`, buttons are `text-sm`/`text-xs`, body copy is
/// `text-base`. Each value below is the Kotlin port's, so the two clients render
/// the same hierarchy.
///
/// ⚠️ WEIGHTS ARE 400/600/700 ONLY. Android is limited to those three because they
/// are the cuts it vendors; matching the limit here keeps a design that reads the
/// same on both clients rather than one that quietly uses a weight the other
/// cannot render.
/// One text style: the size and weight we chose, plus the system style its scaling
/// is anchored to.
///
/// ⛔ A DESCRIPTOR RATHER THAN A `Font`, AND THE REASON IS THAT THE OBVIOUS API DOES
/// NOT EXIST. The natural move is `Font.system(size:weight:design:relativeTo:)` —
/// compiled against the iOS 17 SDK it is `error: extra argument 'relativeTo' in
/// call`. `relativeTo:` lives on `Font.custom(_:size:relativeTo:)`, which needs a
/// bundled font file this app deliberately does not ship, and on `@ScaledMetric`,
/// which is a property wrapper and therefore needs a view. So the size travels as
/// DATA to a modifier that owns the wrapper.
///
/// ⛔ AND NOT A SIZE COMPUTED THROUGH `UIFontMetrics` INTO A `static let`. That
/// compiles, reads correctly, and is FROZEN: a `static let` is evaluated once, so
/// Larger Text would do nothing until the app was relaunched. The failure would look
/// like the feature working for whoever tested it after a restart.
///
/// ⚠️ THE ANCHOR IS NOT COSMETIC. iOS scales each text style by a different curve —
/// a caption grows proportionally more than a title — so a 12pt label anchored to
/// `.caption` reaches a different size at AX5 than the same 12pt anchored to
/// `.body`. The anchors below mirror what each token is FOR, not its raw size.
struct DistrictFont {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let style: Font.TextStyle

    init(size: CGFloat, weight: Font.Weight, design: Font.Design = .default, style: Font.TextStyle) {
        self.size = size
        self.weight = weight
        self.design = design
        self.style = style
    }
}

/// ⚠️ `@ScaledMetric` RESOLVES PER VIEW, WHICH IS THE WHOLE POINT. It reads the
/// environment's size category at body-evaluation time, so changing Larger Text
/// while the app is open reflows immediately.
private struct DistrictFontModifier: ViewModifier {
    private let font: DistrictFont
    @ScaledMetric private var scaled: CGFloat

    /// ⛔ `nonisolated`, AND SO IS THE `.font(_:)` OVERLOAD BELOW, BECAUSE SwiftUI'S
    /// OWN `.font(_:)` IS. `ViewModifier` conformance infers main-actor isolation, so
    /// without this a `@ViewBuilder` closure the compiler treats as nonisolated — a
    /// `PhotosPicker` label in `DeskSettingsView` was the one that found it — fails
    /// with "non-Sendable 'some View'-typed result can not be returned from main
    /// actor-isolated instance method". Marking only the overload downgrades that to a
    /// warning about this initialiser; both have to be nonisolated for a clean build.
    nonisolated init(font: DistrictFont) {
        self.font = font
        _scaled = ScaledMetric(wrappedValue: font.size, relativeTo: font.style)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaled, weight: font.weight, design: font.design))
    }
}

extension View {
    /// ⛔ AN OVERLOAD OF `.font(_:)`, WHICH IS WHAT KEEPS 351 CALL SITES UNTOUCHED.
    /// `.font(DistrictType.body)` selects this because the argument is a
    /// ``DistrictFont``; nothing had to move for the app to start scaling.
    nonisolated func font(_ font: DistrictFont) -> some View {
        modifier(DistrictFontModifier(font: font))
    }
}

enum DistrictType {
    /// Login-card scale headline. The web's `md:text-4xl` = 36px.
    static let display = DistrictFont(size: 36, weight: .bold, style: .largeTitle)

    /// `PageHeader` at md, `text-3xl` = 30px.
    static let headlineLarge = DistrictFont(size: 30, weight: .semibold, style: .title)

    /// `PageHeader` base, `text-2xl` = 24px. The most used title size in the product.
    static let headline = DistrictFont(size: 24, weight: .semibold, style: .title2)

    static let titleLarge = DistrictFont(size: 20, weight: .semibold, style: .title3)

    static let title = DistrictFont(size: 16, weight: .semibold, style: .headline)

    /// List-row titles.
    static let titleSmall = DistrictFont(size: 14, weight: .semibold, style: .subheadline)

    /// `text-base`, the reading size. Fields and body copy.
    static let body = DistrictFont(size: 16, weight: .regular, style: .body)

    /// `text-sm`, the default for secondary copy and list subtitles.
    static let bodySmall = DistrictFont(size: 14, weight: .regular, style: .callout)

    /// `text-xs`.
    static let caption = DistrictFont(size: 12, weight: .regular, style: .caption)

    /// Button at the default size: `text-sm font-medium`.
    static let labelLarge = DistrictFont(size: 14, weight: .semibold, style: .subheadline)

    /// Small button and badge: `text-xs font-medium`.
    static let label = DistrictFont(size: 12, weight: .semibold, style: .caption)

    static let labelSmall = DistrictFont(size: 11, weight: .semibold, style: .caption2)

    /// ⛔ THE SIGNATURE TYPOGRAPHIC MOVE OF THE BRAND, and the most copied string in
    /// the web codebase: `font-mono text-[10px] uppercase tracking-[0.18em]
    /// text-muted-foreground`. Used for every section and field label.
    ///
    /// ⚠️ UPPERCASING AND TRACKING ARE THE CALLER'S JOB, because neither is part of
    /// a `Font`. Use ``DistrictEyebrow`` rather than this constant directly, or the
    /// label renders at 10pt with none of what makes it recognisable.
    static let eyebrow = DistrictFont(size: 10, weight: .regular, design: .monospaced, style: .caption2)

    /// The web's `tracking-[0.18em]` at the eyebrow's 10pt size.
    static let eyebrowTracking: CGFloat = 1.8

    /// The large number on a metric card. Big digits need tight tracking or they
    /// look loose.
    static let metric = DistrictFont(size: 30, weight: .semibold, style: .title)

    /// `tracking-tight`, applied to headings only, at the 24pt heading size.
    static let headingTracking: CGFloat = -0.6

    /// Every scalable token, for the test that guards the anchor.
    ///
    /// ⛔ HAND-MAINTAINED ON PURPOSE, BECAUSE SWIFT CANNOT ENUMERATE STATIC MEMBERS.
    /// `Mirror` reflects instances, not a caseless enum's statics, so there is no way
    /// to ask "did somebody add a token without an anchor". `DistrictTypeTests` pins
    /// this list's COUNT, so a fifteenth token that is never added here fails a test
    /// instead of shipping as the one label on the app that does not grow.
    static let allScalable: [(name: String, font: DistrictFont)] = [
        ("display", display), ("headlineLarge", headlineLarge), ("headline", headline),
        ("titleLarge", titleLarge), ("title", title), ("titleSmall", titleSmall),
        ("body", body), ("bodySmall", bodySmall), ("caption", caption),
        ("labelLarge", labelLarge), ("label", label), ("labelSmall", labelSmall),
        ("eyebrow", eyebrow), ("metric", metric),
    ]
}

/// The wide-tracked uppercase micro-label the whole product is labelled with.
///
/// ⚠️ A VIEW RATHER THAN A FONT CONSTANT, because the uppercasing and the tracking
/// are two thirds of the effect and neither lives in a `Font`. See
/// ``DistrictType/eyebrow``.
struct DistrictEyebrow: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ TRACKING IS POINTS, SO IT SCALES OR THE LABEL COMES APART. At AX5 the
    /// glyphs are roughly twice the size while a fixed 1.8pt gap stays put, which
    /// reads as letters crowding rather than as the wide-tracked label the brand is
    /// built on. Anchored to `.caption2`, the same style the eyebrow font uses.
    @ScaledMetric(relativeTo: .caption2) private var tracking: CGFloat = DistrictType.eyebrowTracking

    var body: some View {
        Text(text.uppercased())
            .font(DistrictType.eyebrow)
            .tracking(tracking)
            .foregroundStyle(colors.mutedForeground)
            // ⛔ ANNOUNCED IN ITS ORIGINAL CASE, NOT THE ONE ON SCREEN. The uppercasing
            // here is typographic — the brand's wide-tracked label — but VoiceOver
            // treats a short all-caps string as an initialism and spells it: "Reply"
            // rendered as REPLY is read "R, E, P, L, Y". Passing the unmodified text
            // as the label keeps the look and the word.
            .accessibilityLabel(text)
    }
}
