import Foundation

/// Every sentence the billing screen says.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A SCREEN, the same call
/// ``DialerCopy`` and ``WorkflowsCopy`` make: `swiftlint --strict` promotes the
/// `file_length` WARNING at 500 lines to an error, and the copy for a screen with six
/// cards and four degraded states is most of a file on its own.
///
/// ⛔ THERE IS NO "UPGRADE", NO "MANAGE BILLING" AND NO "OPEN INVOICE" STRING IN HERE,
/// AND THE ABSENCE IS THE POINT. App Store Review Guideline 3.1.3(b) keeps subscription
/// purchase and management out of the app entirely, so this screen states what is being
/// billed and states the limitation. ⛔ IT NAMES NO DESTINATION EITHER:
/// 3.1.1 anti-steering makes "on the web dashboard at distronode.com" the rejection just
/// as surely as a button would be, so every sentence here says what cannot be done in
/// this app and stops. `StoreCopyTests` fails the build if one names a place.
/// Android's screen hands a Stripe hosted invoice URL out to be opened
/// (`onOpenInvoice`, `billing_invoice_open`); that is the one place where matching
/// Android would fail review, so it is deliberately not ported. A string added here that
/// reads as a control is the rejection.
///
/// ⛔ THE COPY IS THE ANDROID CLIENT'S WHERE ANDROID HAS A STRING, so the two apps say
/// the same thing about the same bill. Three are load bearing:
/// "No plan on this workspace" rather than "Free", "Calls are being declined" rather than
/// a generic over-limit note, and the unavailable body rather than an empty invoice list.
///
/// ⚠️ ANDROID'S EM DASHES ARE COMMAS HERE. The repo's house style avoids em dashes, and
/// VoiceOver reads one as nothing at all, so a sentence hinging on one loses its hinge.
enum BillingCopy {
    // MARK: - The plan card

    /// The plan names the pricing page shows, keyed by the wire tier.
    ///
    /// ⛔ THE SERVER'S `PLAN_TIER_LABELS` (distronode-website,
    /// `src/lib/payments/plan-urls.ts`), WORD FOR WORD. ``WorkspaceBilling/subscriptionTier``
    /// is the catalogue KEY (`VoicePro`), never a name, and the card printed it as is
    /// until 2.2.1. Product marks, so the same in every language.
    static var planNames: [String: String] {
        [
            "VoiceSolo": planNameVoiceSolo,
            "VoiceStarter": planNameVoiceStarter,
            "VoicePro": planNameVoicePro,
            "VoiceStudio": planNameVoiceStudio,
        ]
    }

    /// The plan card's headline: the plan's name for a tier in ``planNames``, any other
    /// tier exactly as the server sent it, and ``planNone`` for no tier at all.
    ///
    /// ⚠️ AN UNKNOWN TIER IS SHOWN, NOT HIDDEN. A tier added server side before this table
    /// knows it is still the workspace's plan; printing its key is less wrong than
    /// "no plan", which would be a claim about the account.
    ///
    /// ⚠️ MATCHED IGNORING CASE AND SURROUNDING SPACE, as ``BillingFormat/normalisedStatus(_:)``
    /// matches the status: nothing normalises the column on write, and DistrictCore's
    /// ``WorkspaceBilling`` calls a case-insensitive comparison the only safe one.
    static func planName(_ tier: String?) -> String {
        guard let tier else { return planNone }
        let key = BillingFormat.normalisedStatus(tier)
        return planNames.first { $0.key.lowercased() == key }?.value ?? tier
    }
}
