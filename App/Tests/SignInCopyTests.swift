@testable import DistrictAI
import XCTest

/// What the sign-in screen says to an Apple ID that has no account.
///
/// ⛔ THE SENTENCE IS THE SERVER'S, WORD FOR WORD. `POST /api/auth/native/apple`
/// carries the same text in its 403 `message`, and the client does not read it
/// (it keys on the status), so this literal is the only thing holding the two
/// copies together. Reword both or neither.
final class SignInCopyTests: XCTestCase {
    func testTheNoAccountSentenceIsTheServersSentence() {
        XCTAssertEqual(
            SignInCopy.noAccount,
            "No District AI account uses this Apple ID. Ask your organization's administrator to invite you, "
                + "then sign in with the invited email."
        )
    }

    /// ⛔ INFORMATIONAL, NOT A FAILURE. Warning or danger ink would read as "try
    /// again", and no retry can help; neutral would bury the one sentence the
    /// user has to act on.
    func testTheNoAccountSentenceIsInformational() {
        XCTAssertEqual(SignInStatusTone.forReason(SignInCopy.noAccount), .info)
    }

    /// ⚠️ THE NEIGHBOURS KEEP THEIR TONES, so adding the `info` set moved nothing
    /// that was already classified.
    func testTheExistingReasonsKeepTheirTones() {
        XCTAssertEqual(SignInStatusTone.forReason("That sign-in could not be verified. Please try again."), .danger)
        XCTAssertEqual(SignInStatusTone.forReason("That sign-in expired. Please try again."), .warning)
        XCTAssertEqual(SignInStatusTone.forReason("You are signed out."), .neutral)
    }
}
