/// The setup wizard (``SetupWizardView``).
///
/// ⚠️ NEW ON BOTH CLIENTS: Android has no native setup wizard yet, so these are named here
/// first, in Android's `district-<screen>-<control>` shape so a port can copy them.
extension A11yID {
    enum Setup {
        static let root = "district-setup-root"
        static let loading = "district-setup-loading"
        static let refused = "district-setup-refused"
        static let finished = "district-setup-finished"
        static let failed = "district-setup-failed"
        static let progress = "district-setup-progress"
        static let finishLater = "district-setup-finish-later"
        static let back = "district-setup-back"
        static let skip = "district-setup-skip"
        static let stepError = "district-setup-step-error"
        static let done = "district-setup-done"

        /// The step on screen, keyed by the service's step key (`business`, `golive`).
        static func step(_ key: String) -> String {
            "district-setup-step-\(key)"
        }

        /// One choice in a list of choices, keyed by its wire value.
        static func choice(_ group: String, _ value: String) -> String {
            "district-setup-\(group)-\(value)"
        }

        enum Business {
            static let website = "district-setup-business-website"
            static let readWebsite = "district-setup-business-read"
            static let notice = "district-setup-business-notice"
            static let name = "district-setup-business-name"
            static let what = "district-setup-business-what"
            static let country = "district-setup-business-country"
            static let subdivision = "district-setup-business-subdivision"
            static let city = "district-setup-business-city"
            static let street = "district-setup-business-street"
            static let openSkills = "district-setup-business-open-skills"
            static let save = "district-setup-business-save"
        }

        enum Number {
            static let keep = "district-setup-number-keep"
            static let openPage = "district-setup-number-open-page"
        }

        enum Receptionist {
            static let name = "district-setup-receptionist-name"
            static let greeting = "district-setup-receptionist-greeting"
            static let voice = "district-setup-receptionist-voice"
            static let save = "district-setup-receptionist-save"
        }

        enum Callers {
            static let timezone = "district-setup-callers-timezone"
            static let website = "district-setup-callers-website"
            static let fill = "district-setup-callers-fill"
            static let useHours = "district-setup-callers-use-hours"
            static let discardHours = "district-setup-callers-discard-hours"
            static let addService = "district-setup-callers-add-service"
            static let addFaq = "district-setup-callers-add-faq"
            static let save = "district-setup-callers-save"
            static let saveAndContinue = "district-setup-callers-continue"

            static func day(_ day: String) -> String {
                "district-setup-callers-day-\(day)"
            }
        }

        enum Calls {
            static let ring = "district-setup-calls-ring"
            static let saveAnswering = "district-setup-calls-save-answering"
            static let openSkills = "district-setup-calls-open-skills"
            static let openIntegrations = "district-setup-calls-open-integrations"
            static let profiles = "district-setup-calls-profiles"
            static let saveAndContinue = "district-setup-calls-continue"
        }

        enum GoLive {
            static let mobile = "district-setup-golive-mobile"
            static let callMe = "district-setup-golive-call-me"
            static let callStatus = "district-setup-golive-call-status"
            static let businessLine = "district-setup-golive-business-line"
            static let startCheck = "district-setup-golive-start-check"
            static let checkStatus = "district-setup-golive-check-status"
            static let summary = "district-setup-golive-summary"
            static let finish = "district-setup-golive-finish"

            /// ⛔ A REAL CALL ON THE CARRIER ACCOUNT, OR THE WORKSPACE'S SETUP MARKED FINISHED, so
            /// `UITestApp.forbiddenSurfaces` refuses them: only the loopback
            /// `SetupWizardScreenshotTests` taps them.
            static let forbiddenSurfaces: Set<String> = [callMe, startCheck, finish]
        }
    }
}
