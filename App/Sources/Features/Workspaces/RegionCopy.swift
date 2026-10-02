import Foundation

/// How a data region reads on screen: the workspace picker's rows and Support's
/// provenance chip say the same words.
enum RegionCopy {
    /// ⛔ AN UNRECOGNISED REGION RENDERS ITS OWN RAW ID, UPPERCASED, AND IS NEVER
    /// COERCED TO A DEFAULT. A helper that answered "us" for anything it did not
    /// know would tell a customer their data sits in the United States on the
    /// strength of a typo.
    static func label(_ region: String) -> String {
        switch region {
        case "us": "US"
        case "ca": "Canada"
        case "eu": "Europe"
        case "apac": "APAC"
        default: region.uppercased()
        }
    }
}
