import Foundation

/// Real error bodies, copied out of the committed contract fixtures. Every key and every message string is verbatim;
/// only the source-line wrapping differs, so the decoded values are identical
/// while the literals stay inside the 120-column lint.
///
/// ⛔ COPIED RATHER THAN LOADED, AND ONLY BECAUSE THESE ARE ERROR SHAPES. The
/// fixture loader belongs to the strict contract gate, which is what pins the
/// SUCCESS shapes the app renders. Error shapes are deliberately not gate-pinned
/// on either client — the Kotlin client pins four of them by hand for the same
/// reason these are here: the cost of a missed field is a vaguer sentence, not
/// wrong data.
///
/// ⚠️ EVERY ONE OF THESE IS A DIFFERENT ENVELOPE, WHICH IS THE POINT. Two of the
/// three shapes appear below; the third (the shared auth guard's bare `{error}`)
/// has no fixture of its own because it is not a route's output at all — it is
/// what `if (error) return error` returns on every 401/403/404 in the API, so it
/// is written out longhand in the tests instead.
enum CapturedErrorBodies {
    /// `district-workspace-list-degraded.json` — the `{error, code}` envelope,
    /// with NO `success` key at all. ⛔ This is the body that would make a strict
    /// `{success, error}` DTO throw, and its `code` is what stops the app drawing
    /// "you have no workspaces" over "one region did not answer".
    static let workspaceListDegraded = """
    {
      "error": "Your workspaces could not be listed because one or more regions \
    are unreachable right now. This is not a change to your account.",
      "code": "REGIONS_DEGRADED",
      "degradedRegions": [
        "eu",
        "apac"
      ]
    }
    """

    /// `district-enrich-disabled.json` — a route's own `{success: false, error}`,
    /// with `success` PRESENT AND FALSE and no `code` to branch on. The sentence
    /// is the whole product here: it names the settings page the opt-in lives on.
    static let enrichDisabled = """
    {
      "success": false,
      "error": "Lead enrichment is off for this workspace. Turn it on in \
    Settings → AI Agent → Skills & Integrations to enrich contacts with \
    external business data."
    }
    """

    /// `district-dial-subscription.json` — `{success, error, code, status}`, the
    /// widest error body in the suite and the one that proves `status` is real.
    static let dialSubscription = """
    {
      "success": false,
      "error": "This workspace's subscription is not active. Please update \
    billing to resume calls and messaging.",
      "code": "subscription_inactive",
      "status": "past_due"
    }
    """

    /// `district-dial-dnc.json` — a 403 whose refusal carries no code at all, so
    /// the sentence is the only specific thing a client has.
    static let dialDoNotCall = """
    {
      "success": false,
      "error": "This number has opted out of calls from this workspace (DNC)."
    }
    """

    /// `district-dial-dormant.json` — the SAME 403 shape as the DNC refusal with
    /// one key more. ⛔ That key is the entire difference between a dead end and
    /// an instruction: `workspace_dormant` is what tells the app to point at the
    /// dashboard's reactivation route rather than draw a refusal the operator
    /// cannot act on.
    static let dialDormant = """
    {
      "success": false,
      "error": "This workspace has not sent anything for 100 days, so outbound \
    calling and messaging are paused pending an account review. Request \
    reactivation from your dashboard and we will re-enable it.",
      "code": "workspace_dormant"
    }
    """

    /// What a captive portal answers on hotel or conference wifi: HTML, with a
    /// perfectly ordinary-looking status code.
    static let captivePortalHtml = """
    <!doctype html><html><head><title>Sign in to continue</title></head>
    <body><form action="/portal/login"></form></body></html>
    """
}
