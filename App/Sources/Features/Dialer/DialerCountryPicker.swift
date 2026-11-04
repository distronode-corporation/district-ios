import SwiftUI

/// The country list behind the flag button: searchable by name or code, the workspace's
/// home country and the two countries this product sells numbers in first, then every
/// country alphabetically in the app's language.
///
/// ⚠️ A SHEET RATHER THAN A `Menu`: about two hundred rows need a search field, and a menu
/// has nowhere to put one.
///
/// ⚠️ DISMISS FIRST, THEN PICK, so the field re-reads under the new flag on a keypad that
/// is already back on screen. A pick changes the country and never dials.
struct DialerCountryPicker: View {
    let home: String?
    let selected: String?
    let onPick: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                colors.background.ignoresSafeArea()
                rows
            }
            .navigationTitle(DialerCopy.country)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: DialerCopy.countrySearch
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(DialerCopy.cancel) { dismiss() }
                }
            }
        }
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    section(DialerCopy.countriesSuggested, DialPlan.suggested(home: home, current: selected))
                    section(DialerCopy.countriesAll, DialPlan.sortedCountries())
                } else {
                    matches(DialPlan.search(query))
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ countries: [String]) -> some View {
        DistrictEyebrow(text: title)
            .padding(.horizontal, DistrictSpacing.gutter)
            .padding(.top, DistrictSpacing.section)
            .padding(.bottom, DistrictSpacing.tight)
            .accessibilityAddTraits(.isHeader)
        ForEach(countries, id: \.self) { iso in
            row(iso)
        }
    }

    @ViewBuilder
    private func matches(_ countries: [String]) -> some View {
        if countries.isEmpty {
            Text(DialerCopy.countriesNoMatch)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .padding(DistrictSpacing.gutter)
        } else {
            ForEach(countries, id: \.self) { iso in
                row(iso)
            }
        }
    }

    /// ⛔ THE CHOSEN COUNTRY IS A TRAIT, NOT ONLY A TICK, as on ``WorkspacePickerSheet``.
    private func row(_ iso: String) -> some View {
        VStack(spacing: 0) {
            Button { pick(iso) } label: {
                DistrictListRow(
                    title: DialPlan.name(iso),
                    subtitle: DialPlan.callingCode(for: iso).map { "+" + $0 },
                    leading: {
                        Text(DialPlan.flag(iso))
                            .font(DistrictType.headline)
                            .accessibilityHidden(true)
                    },
                    trailing: { checkmark(iso) }
                )
                .padding(.horizontal, DistrictSpacing.gutter)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(iso == selected ? [.isSelected] : [])
            .accessibilityIdentifier(A11yID.Dialer.countryOption(iso))
            DistrictRowDivider()
        }
    }

    @ViewBuilder
    private func checkmark(_ iso: String) -> some View {
        if iso == selected {
            Image(systemName: "checkmark")
                .font(DistrictType.labelLarge)
                .foregroundStyle(colors.district)
                .accessibilityHidden(true)
        }
    }

    private func pick(_ iso: String) {
        dismiss()
        onPick(iso)
    }
}
