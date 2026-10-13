import Foundation

/// The words of the authenticator-code step after Sign in with Apple.
///
/// ⚠️ ENGLISH CONSTANTS IN ONE PLACE, AS ``SessionCopy`` AND ``SignInCopy`` ARE: the app
/// is English only, and a single home is what a later localisation pass replaces.
///
/// ⛔ ``expired`` TELLS THE PERSON WHAT TO DO, because it is the one refusal no amount
/// of typing can fix: the ticket is gone and only a fresh Apple sign-in mints another.
/// ``SignInStatusTone`` colours it as a warning on the sign-in screen.
enum MfaCopy {}
