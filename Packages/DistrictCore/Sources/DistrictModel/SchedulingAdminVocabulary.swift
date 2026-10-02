import Foundation

/// What an event type's `location_value` column holds, which depends entirely on
/// its `location_type`.
///
/// ⛔ FOUR KINDS FOR ONE COLUMN, WHICH IS WHY THE CATALOG VALIDATES IT
/// CONDITIONALLY AND WHY NOTHING HERE MAY VALIDATE IT UNCONDITIONALLY. The server
/// refuses a non-URL value only when BOTH fields are present and the type is one
/// of the two URL kinds (`refuseNonUrlLocation` in `admin-ops.ts`); a URL check
/// applied to every type would refuse every phone consultation in the product.
public enum SchedulingLocationValueKind: Sendable, Equatable {
    /// ⛔ THE SCHEDULER GENERATES THE JOIN LINK ITSELF, so a value sent for one of
    /// these is at best ignored. An editor must not offer a field.
    case generated
    /// A URL, and the one kind the catalog checks.
    case url
    /// A phone number the attendee is asked to call, or is called on.
    case phone
    /// A street address.
    case address
}

/// The location types the catalog permits on an event type.
///
/// ⛔ SEVEN, AND `zoom` IS ABSENT DELIBERATELY RATHER THAN FORGOTTEN. The fork's
/// own DB CHECK accepts eight — the eighth is `zoom` — so nothing downstream
/// would refuse it; the catalog is what withholds it, and adding a case here
/// would produce a picker whose eighth entry is a **400 `invalid_params`** on
/// every save. The gap between this list and the fork's is the product decision,
/// and `admin-ops.ts` is the only place it is made.
///
/// ⛔ THE RAW VALUES ARE THE SERVER'S STRINGS VERBATIM AND ARE PINNED A SECOND
/// TIME BY `SchedulingAdminVocabularyTests`, for the reason
/// ``SchedulingAdminOp`` states about its own 75: a value renamed on the server
/// is a 400 here and not a compile error, so a test that read the enum back would
/// assert that the code equals itself and would pass through any rename.
///
/// ⚠️ A STORED ROW MAY CARRY A TYPE THIS LIST DOES NOT KNOW, which is why
/// ``SchedulingEventType/locationType`` is a raw `String?` and this enum is
/// reached through ``known(_:)``. An event type created before the allowlist
/// narrowed, or through the fork's own admin, is still the event type the
/// scheduler serves today; a read that failed on it would lose the whole row to
/// report one field.
public enum SchedulingLocationType: String, CaseIterable, Sendable, Equatable {
    case googleMeet = "google_meet"
    case teams
    case customVideo = "custom_video"
    case phone
    case inPerson = "in_person"
    case link
    case livekit

    /// What this type's `location_value` means.
    ///
    /// ⚠️ EXHAUSTIVE WITH NO `default`, so a case added without being classified
    /// fails to compile here. That is the only thing keeping this in step with
    /// `LOCATION_TYPES`.
    public var valueKind: SchedulingLocationValueKind {
        switch self {
        case .googleMeet, .teams, .livekit: .generated
        case .customVideo, .link: .url
        case .phone: .phone
        case .inPerson: .address
        }
    }

    /// ⚠️ nil FOR A STORED VALUE THIS BUILD DOES NOT KNOW, which a caller renders
    /// as the raw string rather than replacing. See the ⚠️ on the type.
    public static func known(_ wire: String?) -> SchedulingLocationType? {
        guard let wire else { return nil }
        return SchedulingLocationType(rawValue: wire)
    }
}
