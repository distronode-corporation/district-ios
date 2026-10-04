import Foundation

/// The profile, branding and booking assistant sentences, plus the two option lists
/// whose ORDER is part of the contract.
///
/// ⛔ PORTED FROM THE WEB'S PROFILE, NOTIFICATIONS, BOOKING PAGE AND BOOKING ASSISTANT
/// SETTINGS TABS AND THEIR SHARED FORMAT HELPERS. See the namespace note on
/// ``SchedulingBookingWriteCopy``.
enum SchedulingSettingsWriteCopy {
    // MARK: - Profile (me.patch)

    static let profileTitle = "Your scheduler profile"
    static let profileSave = "Save profile"
    static let profileDone = "Profile saved"
    static let nameLabel = "Name"
    static let nameRequired = "Give your name."
    /// ⚠️ THE SAME SENTENCE AS ``businessNameTooLong`` AND A SEPARATE CONSTANT.
    /// Two catalog fields happen to share a ceiling and a wording today; one of
    /// them moving should not silently move the other.
    static let nameTooLong = "That name is longer than 200 characters."
    static let nameLimit = 200
    static let timezoneLabel = "Timezone"
    static let timezoneRequired = "Choose your timezone."
    static let timeFormatLabel = "Time format"
    static let timeFormatRequired = "Choose 12-hour or 24-hour."
    static let weekStartLabel = "Week starts on"
    static let weekStartRequired = "Choose the day your week starts on."
    static let dateFormatLabel = "Date format"
    static let dateFormatRequired = "Choose how dates are written."

    /// ⛔ WIRE VALUE FIRST, LABEL SECOND, AND THE VALUES ARE THE CATALOG'S `z.enum`.
    /// Anything else is a **400 `invalid_params`** naming the field.
    static let timeFormats: [(value: String, label: String)] = [
        ("12h", "12-hour (2:30 pm)"),
        ("24h", "24-hour (14:30)"),
    ]

    /// ⚠️ THE FORK'S OWN 0-6 NUMBERING, WHICH STARTS AT SUNDAY. Not `Calendar`'s
    /// and not the device locale's: the index crosses the wire as an integer.
    static let weekStarts: [(value: Int, label: String)] = [
        (0, "Sunday"),
        (1, "Monday"),
        (2, "Tuesday"),
        (3, "Wednesday"),
        (4, "Thursday"),
        (5, "Friday"),
        (6, "Saturday"),
    ]

    /// ⚠️ THE EXAMPLES ARE THE LABELS, as on the web. A date format named `dmy`
    /// tells an operator nothing; `31/12/2026` tells them everything.
    static let dateFormats: [(value: String, label: String)] = [
        ("dmy", "31/12/2026"),
        ("mdy", "12/31/2026"),
        ("ymd", "2026-12-31"),
    ]

    // MARK: - Notification preferences (also me.patch)

    static let notificationsTitle = "Email notifications"
    static let notificationsSave = "Save notifications"
    static let notificationsDone = "Notifications saved"
    static let attendeeGroup = "As an attendee"
    static let hostGroup = "As a host"
    static let notifyConfirmation = "Booking confirmed"
    static let notifyCancellation = "Booking cancelled"
    static let notifyReschedule = "Booking rescheduled"
    static let notifyReminder = "Booking reminder"
    static let notifyHostBooking = "Someone booked with you"
    static let notifyHostCancel = "Someone cancelled with you"
    static let notifyHostReschedule = "Someone rescheduled with you"

    // MARK: - Branding (settings.branding.patch)

    static let brandingTitle = "Booking page"
    static let brandingSave = "Save booking page"
    static let brandingDone = "Booking page saved"
    static let businessNameLabel = "Business name"
    static let businessNameHint = "Shown at the top of every booking page."
    static let businessNameTooLong = "That name is longer than 200 characters."
    static let logoHeightLabel = "Logo height"
    static let logoHeightHint = "In pixels, between 16 and 64."
    static let logoOpacityLabel = "Logo opacity"
    static let bannerOpacityLabel = "Banner opacity"
    static let opacityHint = "A percentage, between 20 and 100."
    static let privacyUrlLabel = "Privacy policy link"
    static let termsUrlLabel = "Terms link"
    static let legalUrlHint = "Linked in the footer of the booking page. Leave it empty for none."
    static let fallbackLocaleLabel = "Page language"
    static let fallbackLocaleHint = "The language a visitor gets when their browser asks for one we do not have."
    static let fallbackLocaleRequired = "Choose the language the booking page falls back to."
    static let urlTooLong = "That link is too long."
    static let urlNotAbsolute = "Give the full address, starting with https://"

    static func wholeNumberBetween(_ min: Int, _ max: Int) -> String {
        "Give a whole number between \(min) and \(max)."
    }

    /// ⛔ CLIENT-SIDE CLAMPS MIRRORING THE WEB'S, WHICH MIRROR THE FORK.
    /// ⚠️ They exist so a slider cannot produce a value the server refuses, not as
    /// a second validator: the catalog is the only one.
    static let logoHeightRange = 16 ... 64
    static let opacityRange = 20 ... 100
    static let businessNameLimit = 200
    static let legalUrlLimit = 500

    // MARK: - Images

    static let avatarLabel = "Profile picture"
    static let logoLabel = "Logo"
    static let bannerLabel = "Banner"
    static let imageChoose = "Choose image"
    static let imageRemove = "Remove"
    static let imageHint = "JPEG, PNG, GIF or WebP, up to 5 MB."
    /// ⛔ THE ONLY TWO CHECKS A CLIENT CAN MAKE, and both buy a better message
    /// rather than a guarantee — the fork sniffs the first 512 bytes, so a renamed
    /// SVG still fails there. ⚠️ SVG is the one an operator will want for a logo
    /// and it is a script-bearing document; the route refuses it with a 415.
    static let imageTooLarge = "That image is larger than 5 MB. Choose a smaller one."
    static let imageWrongType = "That file is not an image we can use. Choose a JPEG, PNG, GIF or WebP."
    /// ⚠️ A DIFFERENT ANSWER FROM EITHER OF THOSE: the picker handed back nothing
    /// readable, which is not a rejected type and not a rejected size. Collapsing
    /// the three leaves an operator re-picking the same file.
    static let imageUnreadable = "That image could not be read. Choose another."

    static func imageUploaded(_ label: String) -> String {
        "\(label) uploaded"
    }

    static func imageRemoved(_ label: String) -> String {
        "\(label) removed"
    }

    /// ⛔ SAYS "TAKES EFFECT NOW". Upload and remove are immediate on their own ops
    /// and are NOT undone by closing the sheet — the web says the same, and a
    /// picture that vanished from the public booking page because somebody tapped
    /// Remove and then Cancel is the surprise this line exists to prevent.
    static let imageImmediate = "Images save as soon as you choose or remove them."

    // MARK: - The booking assistant (settings.llm)

    // ⚠️ The recording and notetaker switches that shared this sheet were retired with
    // meeting recording (2026-10-03), as on the web's "Booking assistant" tab.
    static let automationTitle = "Booking assistant"
    static let automationSave = "Save booking assistant"
    static let automationDone = "Booking assistant saved"

    static let assistantLabel = "Booking assistant"
    /// ⚠️ NO "AND WRITES THE NOTES": meeting notes were retired with recording (2026-10-03).
    static let assistantHint = "The assistant that answers questions on your booking page."
    static let assistantToggle = "Turn the booking assistant on"
    static let assistantInstructionsLabel = "Extra instructions for the booking assistant"
    static let assistantInstructionsHint = "Extra instructions for the booking assistant. Up to 4000 characters."
    static let assistantInstructionsPlaceholder = "We are closed on public holidays. "
        + "Always ask which location the customer means."
    /// ⚠️ THE WEB STATES THE 4000 LIMIT AND DOES NOT ENFORCE IT, so an over-long
    /// note is a zod 400 there. This client enforces it, because the refusal
    /// arrives as ``SchedulingAdminError/invalidParams`` with field NAMES only and
    /// nothing an operator could act on.
    static let assistantInstructionsLimit = 4000
    static let assistantInstructionsTooLong = "That is longer than 4000 characters."

    // MARK: - Shared

    static let notEditable = "You can view this but not change it."
}
