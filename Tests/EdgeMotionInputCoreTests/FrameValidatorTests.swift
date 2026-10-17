import XCTest
@testable import EdgeMotionInputCore

final class FrameValidatorTests: XCTestCase {
    private func frame(sequence: Int64 = 1, contacts: [Contact]? = nil) -> ContactFrame {
        let timestamp = 10.0
        return ContactFrame(contacts: contacts ?? [Contact(deviceID: 1, pathIndex: 2, fingerID: 2, x: 0.5, y: 0.5, timestamp: timestamp, phase: .moved)], timestamp: timestamp, sequence: sequence)
    }
    func testAcceptsNormalizedUniqueContactsAndIncreasingSequence() {
        XCTAssertSuccess(FrameValidator.validate(frame(), previousSequence: 0))
    }
    func testRejectsInvalidCoordinatesAndDuplicateIdentity() {
        XCTAssertFailure(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 1.1, y: 0, timestamp: 10, phase: .moved)]), previousSequence: nil), .invalidCoordinate)
        XCTAssertFailure(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .moved), Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .ended)]), previousSequence: nil), .duplicateIdentity)
    }

    func testRejectsNegativePathIndex() {
        XCTAssertFailure(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: -1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .moved)]), previousSequence: nil), .invalidIdentity)
    }
    func testRejectsNonMonotonicAndInconsistentFrames() {
        XCTAssertFailure(FrameValidator.validate(frame(sequence: 4), previousSequence: 4), .invalidSequence)
        XCTAssertFailure(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 11, phase: .moved)]), previousSequence: nil), .inconsistentTimestamp)
    }
    func testRejectsEmptyFramesAndContactOverflow() {
        XCTAssertFailure(FrameValidator.validate(frame(contacts: []), previousSequence: nil), .empty)
        let contact = Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0.5, y: 0.5, timestamp: 10, phase: .moved)
        XCTAssertFailure(FrameValidator.validate(frame(contacts: Array(repeating: contact, count: 17)), previousSequence: nil), .tooManyContacts)
    }

    func testRejectsInvalidTimestampsAndIdentity() {
        XCTAssertFailure(FrameValidator.validate(
            ContactFrame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0.5, y: 0.5, timestamp: 0, phase: .moved)], timestamp: 0, sequence: 1),
            previousSequence: nil
        ), .invalidTimestamp)
        XCTAssertFailure(FrameValidator.validate(frame(contacts: [
            Contact(deviceID: 0, pathIndex: 1, fingerID: 1, x: 0.5, y: 0.5, timestamp: 10, phase: .moved)
        ]), previousSequence: nil), .invalidIdentity)
    }

    private func XCTAssertSuccess(_ result: Result<Void, FrameValidationError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result { XCTFail("Expected success, got \(error)", file: file, line: line) }
    }

    private func XCTAssertFailure(_ result: Result<Void, FrameValidationError>, _ expected: FrameValidationError, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let actual) = result else { return XCTFail("Expected failure \(expected)", file: file, line: line) }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

final class QuartzOutputTests: XCTestCase {
    func testUsesDragEventWhileLeftButtonIsHeld() {
        XCTAssertEqual(QuartzOutput.mouseEventType(isLeftButtonPressed: false), .mouseMoved)
        XCTAssertEqual(QuartzOutput.mouseEventType(isLeftButtonPressed: true), .leftMouseDragged)
    }
}
