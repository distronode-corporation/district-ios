@testable import DistrictAI
import DistrictModel
import Foundation
import Testing

/// The plan card names the plan: "Voice Pro", never the wire key `VoicePro`.
///
/// ⛔ THE FOUR NAMES ARE WRITTEN OUT, NOT READ FROM THE TABLE. They are the server's
/// `PLAN_TIER_LABELS` (distronode-website, `src/lib/payments/plan-urls.ts`), which is not
/// visible from here, so a test that derived them from ``BillingCopy/planNames`` would pass
/// whatever the table said. Through 2.2 the card printed `subscriptionTier` as is, and
/// every paying customer read "VoicePro" on their Billing page.
@MainActor
@Suite(.serialized)
struct BillingPlanNameTests {
    @Test("each of the four tiers reads as the pricing page names it")
    func fourTiers() {
        #expect(BillingCopy.planName("VoiceSolo") == "Voice Solo")
        #expect(BillingCopy.planName("VoiceStarter") == "Voice Starter")
        #expect(BillingCopy.planName("VoicePro") == "Voice Pro")
        #expect(BillingCopy.planName("VoiceStudio") == "Voice Studio")
    }

    /// ⚠️ EXACTLY THE FOUR. A fifth entry is a name this client invented.
    @Test("the table holds the server's four tiers and nothing else")
    func exactlyFour() {
        #expect(Set(BillingCopy.planNames.keys) == ["VoiceSolo", "VoiceStarter", "VoicePro", "VoiceStudio"])
    }

    @Test("a tier in another case or with spaces around it still reads as its name")
    func caseAndSpace() {
        #expect(BillingCopy.planName("voicepro") == "Voice Pro")
        #expect(BillingCopy.planName(" VOICESTUDIO\n") == "Voice Studio")
    }

    /// ⚠️ An unknown tier is still the workspace's plan, so it is shown exactly as sent.
    @Test("an unknown tier is shown exactly as the server sent it")
    func unknownTier() {
        #expect(BillingCopy.planName("VoiceEnterprise") == "VoiceEnterprise")
        #expect(BillingCopy.planName("Free") == "Free")
        #expect(BillingCopy.planName("") == "")
    }

    /// ⛔ NULL IS "NO PLAN", NOT "Free". See ``BillingCopy/planNone``.
    @Test("no tier keeps the no-plan sentence")
    func noTier() {
        #expect(BillingCopy.planName(nil) == BillingCopy.planNone)
        #expect(BillingCopy.planName(nil) == "No plan on this workspace")
    }

    /// The card itself, drawn and read back as VoiceOver and the smoke suite read it: the
    /// name is on screen and the key is not.
    @Test("the plan card shows the plan's name, not its key")
    func cardShowsTheName() async throws {
        let screen = try HostedAccessibility(BillingPlanCard(plan: Self.billing(tier: "\"VoicePro\"")))
        defer { screen.close() }

        let shown = await screen.elements { elements in
            elements.labels.contains { $0.contains("Voice Pro") }
        }
        let card = shown.labels(identified: A11yID.Billing.plan).joined(separator: " ")

        #expect(card.contains("Voice Pro"), "the plan card reads '\(card)'")
        #expect(!shown.labels.contains { $0.contains("VoicePro") }, "the wire key is on screen: \(shown)")
    }

    @Test("the plan card with no tier says there is no plan")
    func cardWithNoTier() async throws {
        let screen = try HostedAccessibility(BillingPlanCard(plan: Self.billing(tier: "null")))
        defer { screen.close() }

        let shown = await screen.elements { elements in
            elements.labels.contains { $0.contains(BillingCopy.planNone) }
        }

        #expect(shown.labels(identified: A11yID.Billing.plan).joined().contains(BillingCopy.planNone))
    }

    /// `GET /api/district/workspace/billing`'s `billing` object, the shape of DistrictCore's
    /// `district-workspace-billing.json` fixture, with `tier` as the raw JSON value.
    private static func billing(tier: String) throws -> WorkspaceBilling {
        let json = """
        {"subscriptionTier":\(tier),"subscriptionStatus":"active","plan":"voicepro",\
        "overagePolicy":"auto_bill","overageCapExceeded":false,"usage":null}
        """
        return try JSONDecoder().decode(WorkspaceBilling.self, from: Data(json.utf8))
    }
}
