import SwiftUI

/// ⛔ WHAT A WORKSPACE-SETTINGS SCREEN SHOWS WHEN IT COULD NOT READ THE
/// CONFIGURATION, AND IT IS THE WHOLE POINT OF THIS DIRECTORY. A retry, and nothing
/// else. No fields, no toggles, no save.
///
/// Three of this surface's save routes replace their stored value WHOLESALE rather
/// than merging it, so a form rendered from nothing and then saved does not save
/// nothing: it deletes the transfer directory the voice agent routes live callers
/// through, or the agent's tool allowlist. The web never had to think about this —
/// its settings page is a server component that hydrates every form from the row
/// during render — which is exactly why a native client has to be explicit about it.
///
/// ⚠️ ``FailureView`` DECIDES WHETHER A RETRY IS OFFERED AT ALL. A 403 (the viewer
/// exclusion) and a contract mismatch both come back with `.none`, because pressing
/// again produces the identical answer.
struct SettingsLoadFailureView: View {
    let failure: FailureText
    let onRetry: () -> Void
    var onSignIn: (() -> Void)?

    var body: some View {
        VStack(spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: SettingsCopy.loadFailedEyebrow)
            FailureView(failure: failure, onRetry: onRetry, onSignIn: onSignIn)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The banner after a save.
///
/// ⛔ ``SettingsSaveState/savedButStale(_:)`` IS ITS OWN WORDING AND IS NOT
/// DESTRUCTIVE-COLOURED. The write landed; only the read back failed. Drawing it as
/// an error would invite a second save from state the client can no longer vouch
/// for, which on this surface means re-sending a wholesale-replace array built from
/// a stale baseline. It says so and offers a re-read rather than a re-save.
///
/// ⚠️ RENDERS NOTHING FOR `idle` AND `saving`. A spinner belongs on the control that
/// is disabled, not in a banner that would appear and vanish under the operator's
/// thumb.
///
/// ⛔ AND A BANNER THAT RENDERS SOMETHING CARRIES A WAY TO RETIRE IT. Every model on
/// this surface has a `dismissNotices()`, and without a control wired to it a stale red
/// refusal sits beside a fresh "Saved." with no affordance at all. ⚠️ ONE RULE FOR ALL
/// THREE VISIBLE CASES rather than "errors only": a "Saved." from ten minutes ago is a
/// claim about a state that has moved too, and two rules would be two things to get
/// wrong per call site.
struct SettingsSaveNotice: View {
    let state: SettingsSaveState
    /// ⚠️ Offered ONLY on the stale case, which is the one where re-reading is the
    /// correct next action. Nil elsewhere.
    var onReread: (() -> Void)?
    /// ⚠️ Nil renders no dismiss control at all, so a screen that has not wired one is
    /// unchanged rather than showing a button that does nothing.
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ THE BODY IS GATED ON THIS RATHER THAN LETTING THE SWITCH RETURN `EmptyView`
    /// INSIDE A `VStack`. A stack of two empty children still applies its own frame,
    /// which on a card of stacked notices is four invisible rows of layout.
    private var visible: Bool {
        switch state {
        case .idle, .saving: false
        case .saved, .savedButStale, .failed: true
        }
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                message
                dismissControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var message: some View {
        switch state {
        case .idle, .saving:
            EmptyView()
        case .saved:
            line(SettingsCopy.saved, colors.foreground)
        case let .savedButStale(failure):
            staleLine(failure)
        case let .failed(failure):
            line(failure.message, colors.destructive)
        }
    }

    /// ⚠️ SITS UNDER THE STALE CASE'S OWN "Reload" RATHER THAN REPLACING IT. They are
    /// different actions: one fixes the staleness, the other acknowledges the sentence.
    @ViewBuilder
    private var dismissControl: some View {
        if let onDismiss {
            Button(SettingsCopy.dismiss, action: onDismiss)
                .buttonStyle(.districtGhost)
        }
    }

    private func line(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ THE SERVER'S SENTENCE IS SHOWN UNDER OURS RATHER THAN INSTEAD OF IT. Ours
    /// says what happened to the WRITE, which is the part that matters; theirs says
    /// why the read failed, which is what decides whether reloading will help.
    private func staleLine(_ failure: FailureText) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            line(SettingsCopy.savedButStale, colors.foreground)
            line(failure.message, colors.mutedForeground)
            if let onReread {
                Button(SettingsCopy.reread, action: onReread)
                    .buttonStyle(.districtGhost)
            }
        }
    }
}

/// ⛔ THE READ SUCCEEDED AND THE VALUE STILL CANNOT BE EDITED, WHICH IS A THIRD
/// STATE AND NOT A FAILURE. `callDirectory` and `routingRules` are `Json` columns
/// that can hold rows written before their save routes validated anything, so a
/// stored array whose rows are not objects genuinely exists.
///
/// ⚠️ NO RETRY BUTTON, DELIBERATELY. Nothing about the request failed; retrying it
/// returns the same value. The fix is on the website, and the body says so.
struct SettingsNotEditableNotice: View {
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: SettingsCopy.notEditableEyebrow)
            Text(SettingsCopy.notEditableBody)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ⚠️ SKELETONS RATHER THAN A BLANK EXPANSE, so a slow read does not read as an
/// unconfigured workspace — which on this surface is the one thing it must never
/// look like.
struct SettingsSkeleton: View {
    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 3, id: \.self) { _ in
                SkeletonBlock(height: 72)
            }
        }
    }
}

/// One labelled text box, on the palette rather than the platform's.
///
/// ⚠️ THE LABEL IS A `Text` ABOVE THE FIELD rather than a placeholder, matching
/// ``CreateContactSheet``: a placeholder disappears the moment someone types, which
/// on a form of three similar boxes is where the wrong value gets saved into the
/// wrong field.
///
/// ⛔ "ON THE PALETTE RATHER THAN THE PLATFORM'S" IS LOAD-BEARING, because this is the
/// most reused field in the app. `.textFieldStyle(.roundedBorder)` with no background
/// lets UIKit paint its own near-black fill, which covers a large share of a form screen
/// such as the Agent persona. The treatment comes from ``View/districtField()``; see the
/// ⛔ there.
///
/// ⚠️ THE `prompt:` CARRIES THE SAME STRING AS THE TITLE, DELIBERATELY. The title is
/// what VoiceOver announces as the field's name and must not move; the prompt is the
/// only seam that can put the placeholder on ``DistrictColors/mutedForeground``
/// instead of the platform's grey. Both are `label`, so nothing on screen or in the
/// accessibility tree reads differently.
struct SettingsField: View {
    let label: String
    let text: Binding<String>
    var enabled = true
    /// ⚠️ Multi-line for prose (a greeting, a personality) and single-line for a
    /// name or a number. `axis:` rather than a separate editor so the two share one
    /// component and one disabled state.
    var multiline = false

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            box
        }
    }

    /// ⚠️ Hoisted out of the two branches below so the placeholder is written once.
    private var prompt: Text {
        Text(label).foregroundStyle(colors.mutedForeground)
    }

    @ViewBuilder
    private var box: some View {
        if multiline {
            TextField(label, text: text, prompt: prompt, axis: .vertical)
                .lineLimit(3 ... 8)
                .disabled(!enabled)
                .districtField()
        } else {
            TextField(label, text: text, prompt: prompt)
                .disabled(!enabled)
                .districtField()
        }
    }
}

/// A titled panel, so a screen with two independent save buttons reads as two
/// things rather than one long form.
///
/// ⛔ USED WHEREVER ONE SCREEN CARRIES TWO SAVES THROUGH TWO ROUTES. The capability
/// allowlist is a wholesale replace and the enrichment consent is a per-field merge;
/// folding them into one panel with one button would be one tap writing through two
/// routes with different failure modes, and the destructive one would be the half
/// nobody was thinking about.
struct SettingsCard<Content: View>: View {
    let eyebrow: String
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(eyebrow: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            DistrictEyebrow(text: eyebrow)
            content
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }
}

/// A read-only `label: value` line, for the persona fields this client displays and
/// never sends.
struct SettingsReadOnlyRow: View {
    let label: String
    let value: String?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Spacer(minLength: DistrictSpacing.tight)
            // ⚠️ "Not set" RATHER THAN A BLANK. An empty line beside a label reads as
            // a rendering fault, and on this screen it would read as a value that
            // failed to load.
            Text(value ?? SettingsCopy.personaUnset)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .multilineTextAlignment(.trailing)
        }
    }
}
