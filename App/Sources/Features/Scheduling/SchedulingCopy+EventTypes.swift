import DistrictData
import DistrictModel
import Foundation

/// The event-types list and the one-event-type inspector.
extension SchedulingCopy {
    /// ⛔ THE LABELS COME FROM ``SchedulingLocationType``, WHICH IS THE MODULE'S OWN
    /// VOCABULARY, AND AN UNKNOWN WIRE VALUE IS ECHOED RATHER THAN CALLED "Not set". A
    /// location kind the fork added since this build shipped is still meaningful to an
    /// operator; "Not set" is reserved for a genuinely absent value, which is a different
    /// fact and the one the web distinguishes too.
    static func locationLabel(_ wire: String?) -> String {
        guard let wire, !wire.isEmpty else { return locationNotSet }
        guard let known = SchedulingLocationType.known(wire) else { return wire }
        switch known {
        case .googleMeet: return locationGoogleMeet
        case .teams: return locationTeams
        case .customVideo: return locationCustomVideo
        case .phone: return locationPhone
        case .inPerson: return locationInPerson
        case .link: return locationLink
        case .livekit: return locationBuiltInVideo
        }
    }

    /// ⚠️ A HOST'S ROLE AND WHETHER THEY ARE STILL AROUND, in one value. An archived host
    /// is still ON the event type — the fork keeps the link — so hiding the row would make
    /// a rota look complete when it is not.
    static func hostValue(role: String, archived: Bool) -> String {
        archived ? hostArchived(role) : role
    }

    /// ⚠️ THE TYPE AND WHETHER IT IS COMPULSORY. Optional is the default and says nothing,
    /// so only "required" is worth the word.
    static func questionValue(type: String, required: Bool) -> String {
        required ? questionRequired(type) : type
    }
}
