import Foundation
import Sentry

/// Crash and app-hang reporting, and deliberately nothing else.
///
/// ⛔ FOUR THINGS ARE NOT ENABLED HERE AND EACH ABSENCE IS A DECISION, not an
/// omission to be tidied up later:
///
/// 1. **No tracing and no profiling.** ``Sentry/Options/enableAutoPerformanceTracing``
///    is false and ``Sentry/Options/tracesSampleRate`` is 0, so no transaction is
///    ever started. Performance data on a client this early answers no question
///    anyone is asking and it is the expensive half of the ingest bill.
/// 2. **No session replay and no screenshots.** A replay of this app is a replay of
///    a customer's call log, their contacts and their inbox. ``attachScreenshot``
///    and ``attachViewHierarchy`` are both false for the same reason.
/// 3. **No automatic breadcrumbs and no network instrumentation.** The breadcrumb
///    trail that costs nothing on a marketing site carries request URLs here, and a
///    District URL path contains workspace and contact identifiers. `Sentry`'s own
///    network breadcrumbs are off (``enableNetworkBreadcrumbs``) as well as its
///    performance hooks (``enableNetworkTracking``).
/// 4. **No PII.** ``sendDefaultPii`` is false, which is also the SDK's default; it
///    is stated anyway because it is the one option whose default flipping would be
///    invisible in review.
///
/// ⛔ THE DSN COMES FROM A BUILD SETTING AND A BLANK ONE DISABLES THE SDK ENTIRELY.
/// `project.yml` declares `SENTRY_DSN: ""` and routes it into `Info.plist` as
/// `DistrictSentryDSN`; with no DSN this type returns before ``SentrySDK/start(configureOptions:)``
/// is called at all, so nothing is initialised, no crash handler is installed and
/// no file is written. That is what every CI simulator build, every unit test and
/// every local scratch build get. `scripts/archive-imac.sh` is the only place a real
/// DSN is supplied, and only at archive time.
///
/// ⚠️ THE SENTRY ORG IS THE EU ONE (`de.sentry.io`), so the DSN's host must be the
/// German ingest host. The SDK reads the ingest host out of the DSN itself and needs
/// no configuration for it; `sentry-cli` does NOT, which is why the archive script
/// sets `SENTRY_URL` explicitly on the dSYM upload. A US-pointed upload silently
/// does nothing while the build stays green.
///
/// ⚠️ SERVER-SIDE SETTINGS LIVE WITH THE SENTRY PROJECT, NOT HERE. Alert rules and
/// server-side IP scrubbing are configured on the receiving project; nothing in this
/// file reads that configuration and changing one does not change the other.
enum DistrictSentry {
    /// The `Info.plist` key carrying `$(SENTRY_DSN)`. See `project.yml`.
    static let dsnInfoKey = "DistrictSentryDSN"

    /// The `Info.plist` key carrying `$(CONFIGURATION)`.
    static let environmentInfoKey = "DistrictSentryEnvironment"

    /// Start Sentry, or do nothing at all.
    ///
    /// ⛔ CALLED AS THE FIRST LINE OF ``DistrictApp/init()``, BEFORE THE CONTAINER
    /// IS BUILT. `AppContainer.init` touches the Keychain and constructs the whole
    /// object graph; a crash in there is exactly the crash worth having a report
    /// for, and a handler installed afterwards would miss it.
    ///
    /// ⚠️ SAFE TO CALL WHEN NOTHING IS CONFIGURED, WHICH IS THE COMMON CASE ON EVERY
    /// MACHINE THAT IS NOT THE RELEASE LANE. It is not safe to call twice: the SDK
    /// treats a second `start` as a reconfiguration. There is one call site.
    static func startIfConfigured(bundle: Bundle = .main) {
        guard let dsn = configuredValue(bundle, forKey: dsnInfoKey) else { return }
        let environment = configuredValue(bundle, forKey: environmentInfoKey)?.lowercased()
        let release = releaseName(bundle)

        SentrySDK.start { options in
            options.dsn = dsn
            if let environment {
                options.environment = environment
            }
            if let release {
                // ⚠️ `releaseName`, NOT `release`. The SDK has no `release`
                // property, and the string format below is the same one its own
                // default builds; it is stated explicitly so a change to that
                // default cannot silently re-label every event.
                options.releaseName = release
            }

            // The two things this SDK is here for.
            options.enableCrashHandler = true
            // ⚠️ The default 2 second `appHangTimeoutInterval` is deliberately not
            // overridden. A longer window under-reports and a shorter one reports
            // ordinary main-thread work.
            options.enableAppHangTracking = true

            // ── Everything else, off. See the ⛔ on the type. ─────────────────
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = 0
            options.enableAutoBreadcrumbTracking = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sendDefaultPii = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false

            // ⛔ BELT AND BRACES OVER THE OPTIONS ABOVE, NOT INSTEAD OF THEM. Every
            // option here is a promise about what the SDK COLLECTS; this is the
            // last gate before an event leaves the device, and it holds even if a
            // future SDK version changes one of those defaults or adds a collector
            // nobody read about. `user` is dropped whole (this app never calls
            // `SentrySDK.setUser`, so anything in it arrived automatically) and so
            // is `request`, whose URL would carry workspace and contact ids.
            // ⚠️ Returning the event rather than nil: dropping every event would
            // disable the SDK by a route nobody would find.
            options.beforeSend = { event in
                event.user = nil
                event.request = nil
                return event
            }
        }
    }

    /// An `Info.plist` string that a build actually supplied, or nil.
    ///
    /// ⛔ BLANK AND UNEXPANDED BOTH COUNT AS "NOT CONFIGURED". A build setting that
    /// is empty or absent expands to the empty string, which is the intended off
    /// switch; and if the plist were ever processed without build-setting expansion
    /// the value would be the literal `$(SENTRY_DSN)`, which the SDK would try to
    /// parse as a DSN and log a failure for. Neither is a DSN, so neither starts
    /// anything.
    private static func configuredValue(_ bundle: Bundle, forKey key: String) -> String? {
        guard let raw = infoString(bundle, key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// `<bundle id>@<short version>+<build>`, the release identifier Sentry groups by.
    ///
    /// ⚠️ THE BUILD NUMBER IS THE COMMIT COUNT ON A RELEASE ARCHIVE
    /// (`scripts/archive-imac.sh` passes `CURRENT_PROJECT_VERSION`), so a release
    /// string maps back to a sha. On a scratch build it is the placeholder "1" from
    /// `project.yml`, which is why the environment is carried separately.
    ///
    /// ⛔ `project.yml`'s `info.properties` MUST KEEP DECLARING `CFBundleVersion`.
    /// Without it xcodegen writes its own literal `1` into the generated Info.plist,
    /// the `CURRENT_PROJECT_VERSION` passed at archive time reaches the build settings
    /// without ever reaching the bundle, and every release is labelled
    /// `com.distronode.district@1.0+1`: no two builds distinguishable in Sentry and no
    /// crash mapped back to a sha.
    private static func releaseName(_ bundle: Bundle) -> String? {
        guard let identifier = bundle.bundleIdentifier else { return nil }
        guard let short = infoString(bundle, "CFBundleShortVersionString") else { return nil }
        guard let build = infoString(bundle, "CFBundleVersion") else { return nil }
        return "\(identifier)@\(short)+\(build)"
    }

    private static func infoString(_ bundle: Bundle, _ key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}
