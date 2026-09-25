import XCTest
@testable import RiverDiaryMac

/// Regression tests for user-facing error mapping.
final class ProductPolishTests: XCTestCase {

    func testPermissionErrorMapsToActionableMessage() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "You don’t have permission."]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.contains("权限"), "expected an actionable permission message, got: \(message)")
        XCTAssertFalse(message.contains("permission"), "should not surface the raw system text, got: \(message)")
    }

    func testUnknownErrorFallsBackToLocalizedDescription() {
        let detail = "An obscure backend detail"
        let error = NSError(
            domain: "rs.example",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
        XCTAssertEqual(UserFacingError.message(for: error), detail)
    }

    func testDecryptionFailureMapsToHumanMessage() {
        let message = UserFacingError.message(for: StateEncryptionError.decryptionFailed)
        XCTAssertTrue(message.contains("解密"), "expected human decryption message, got: \(message)")
    }

    func testMissingFileMapsToHumanMessage() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened."]
        )
        let message = UserFacingError.message(for: error)
        XCTAssertTrue(message.contains("不存在"), "expected actionable missing-file message, got: \(message)")
    }

    func testRetentionPolicyRequiresConfirmationOnlyWhenItWillPurgeOlderData() {
        XCTAssertTrue(RetentionPolicy.requiresConfirmation(currentDays: 0, requestedDays: 90))
        XCTAssertTrue(RetentionPolicy.requiresConfirmation(currentDays: 365, requestedDays: 90))
        XCTAssertFalse(RetentionPolicy.requiresConfirmation(currentDays: 90, requestedDays: 180))
        XCTAssertFalse(RetentionPolicy.requiresConfirmation(currentDays: 90, requestedDays: 0))
        XCTAssertFalse(RetentionPolicy.requiresConfirmation(currentDays: 90, requestedDays: 90))
    }
}
