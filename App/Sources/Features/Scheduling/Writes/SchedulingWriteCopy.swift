import Foundation

/// The words the scheduling admin's write sheets put on screen.
///
/// ⛔ COPIED FROM THE WEB'S COMPONENTS VERBATIM WHEREVER THE WEB HAS A SENTENCE,
/// AND THAT IS A CORRECTNESS RULE RATHER THAN A CONSISTENCY ONE. These sheets
/// drive the same fork through the same catalog as the web dashboard's
/// scheduling components, so a refusal, a confirmation or a
/// validation message that differs between the two is one product answering a
/// question two ways. Where a string here has no web original it says so.
///
/// ⛔ AND NOTHING HERE IS LOCALISED, because nothing in this app is yet. The
/// French site is a website surface; the iOS client ships English only, and a
/// half-localised catalog would be worse than an honest monolingual one.
///
/// ⚠️ SEPARATE FROM `SchedulingCopy` (the hub card's copy) ON PURPOSE: keeping
/// the two surfaces' wording in separate types lets each change without touching
/// the other.
enum SchedulingWriteCopy {}
