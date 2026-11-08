import SwiftUI

/// Step 2, "Your number".
///
/// ⛔ BUYING A NUMBER CHARGES A CARD AND STAYS ON THE WEB (Sean, 2026-11-08). An owner who
/// already holds one keeps it here; one who holds none opens the setup page in a sheet, where
/// the web's own wizard opens on this step, and the wizard reads its state again when the
/// sheet closes. A number bought there marks the step done, so this one moves on by itself.
///
/// ⚠️ "WHERE CALLS ARE ANSWERED" IS THE WORKSPACE'S REGION, the residency fact the web states on
/// the same step.
struct SetupNumberStep: View {
    let wizard: SetupWizardModel
    let baseURL: URL
    let open: (URL) -> Void

    private var held: Int {
        wizard.data?.numbersHeld ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            if held > 0 {
                SettingsCard(eyebrow: SetupCopy.numberTitle) {
                    SetupNote(text: SetupCopy.numberHaveLead)
                    plan
                    answered
                    SetupPrimaryButton(
                        title: SetupCopy.numberKeep,
                        busy: wizard.isCompleting,
                        identifier: A11yID.Setup.Number.keep
                    ) {
                        Task { await wizard.complete(.number, as: .done) }
                    }
                }
            } else {
                SettingsCard(eyebrow: SetupCopy.numberNoneHeading) {
                    SetupNote(text: SetupCopy.numberNoneBody)
                    plan
                    answered
                    SetupHandOffButton(
                        title: SetupCopy.numberOpenPage,
                        page: .setup,
                        baseURL: baseURL,
                        identifier: A11yID.Setup.Number.openPage,
                        open: open
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("number"))
    }

    @ViewBuilder
    private var plan: some View {
        if let included = wizard.data?.includedNumbers {
            SetupNote(text: SetupCopy.numberIncluded(held, included), font: DistrictType.caption)
        } else {
            SetupNote(text: SetupCopy.numberHeld(held), font: DistrictType.caption)
        }
    }

    @ViewBuilder
    private var answered: some View {
        if let sentence = Self.answeredIn(wizard.region) {
            SetupNote(text: sentence, font: DistrictType.caption)
        }
    }

    static func answeredIn(_ region: String?) -> String? {
        switch region {
        case "us": SetupCopy.numberAnsweredUs
        case "ca": SetupCopy.numberAnsweredCa
        case "eu": SetupCopy.numberAnsweredEu
        case "apac": SetupCopy.numberAnsweredApac
        default: nil
        }
    }
}
