import DistrictData
import DistrictModel
import Foundation

/// The event-types list and the one-event-type inspector.
extension SchedulingCopy {
    static let loadingEventTypes = "Loading event types…"

    static let eventTypesEmptyTitle = "No event types yet"
    static let eventTypesEmptyBody = "An event type is a page a customer can book. "
        + "Create one in a browser and its booking page goes live."

    /// ⛔ "Not public" IS A STATE, NOT A MISSING VALUE. It covers a tenancy with no public
    /// host AND a row that is archived, inactive or private — four different reasons for
    /// one honest answer: there is no address to give out. ⚠️ Never render a URL for any
    /// of them; a published link to a page that does not answer is the one mistake a
    /// customer discovers.
    static let notPublic = "Not public"

    static let eventTypeDetailsEyebrow = "Details"
    static let eventTypeHostsEyebrow = "Hosts"
    static let eventTypeQuestionsEyebrow = "Questions"

    static let eventTypeNoHosts = "No hosts are assigned, so this event type cannot be booked."
    static let eventTypeNoQuestions = "This event type asks no questions."

    static let factDuration = "Duration"
    static let factInterval = "Starts every"
    static let factLocation = "Location"
    static let factLocationValue = "Address"
    static let factNotice = "Minimum notice"
    static let factHorizon = "Bookable up to"
    static let factBufferBefore = "Buffer before"
    static let factBufferAfter = "Buffer after"
    static let factState = "State"

    /// The row's second line: how long it runs and where.
    static func eventTypeSubtitle(duration: String, location: String) -> String {
        "\(duration) · \(location)"
    }

    static func daysLabel(_ days: Int) -> String {
        days == 1 ? "1 day ahead" : "\(days) days ahead"
    }

    /// ⛔ THE LABELS COME FROM ``SchedulingLocationType``, WHICH IS THE MODULE'S OWN
    /// VOCABULARY, AND AN UNKNOWN WIRE VALUE IS ECHOED RATHER THAN CALLED "Not set". A
    /// location kind the fork added since this build shipped is still meaningful to an
    /// operator; "Not set" is reserved for a genuinely absent value, which is a different
    /// fact and the one the web distinguishes too.
    static func locationLabel(_ wire: String?) -> String {
        guard let wire, !wire.isEmpty else { return "Not set" }
        guard let known = SchedulingLocationType.known(wire) else { return wire }
        switch known {
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .customVideo: return "Video link"
        case .phone: return "Phone"
        case .inPerson: return "In person"
        case .link: return "Link"
        case .livekit: return "Built-in video"
        }
    }

    /// ⚠️ A HOST'S ROLE AND WHETHER THEY ARE STILL AROUND, in one value. An archived host
    /// is still ON the event type — the fork keeps the link — so hiding the row would make
    /// a rota look complete when it is not.
    static func hostValue(role: String, archived: Bool) -> String {
        archived ? "\(role) · archived" : role
    }

    /// ⚠️ THE TYPE AND WHETHER IT IS COMPULSORY. Optional is the default and says nothing,
    /// so only "required" is worth the word.
    static func questionValue(type: String, required: Bool) -> String {
        required ? "\(type) · required" : type
    }
}
