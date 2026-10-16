import XCTest
@testable import EdgeMotionDiagnosticCore

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
    func testInvalidFrameDisablesBeforeOutput() {
        let session = DiagnosticSession(); session.startIfReady(true)
        var outputs = 0
        session.accept(frame(contacts: [])) { _ in outputs += 1 }
        XCTAssertEqual(outputs, 0)
        XCTAssertEqual(session.state, .disabled("frame validation: empty"))
    }
    func testUnavailableBackendStartsDisabled() {
        let session = DiagnosticSession(); session.startIfReady(false)
        XCTAssertEqual(session.state, .disabled("backend unavailable"))
    }
    func testStoppedSessionRejectsQueuedFramesWithoutOutput() {
        let session = DiagnosticSession(); session.startIfReady(true); session.stop()
        var outputs = 0
        XCTAssertEqual(session.accept(frame()) { _ in outputs += 1 }, .ignored)
        XCTAssertEqual(outputs, 0)
        XCTAssertEqual(session.state, .idle)
    }

    func testValidFramePreventsNoFrameTimeoutAndAllowsAnotherTerminalOutcome() {
        let lifecycle = DiagnosticLifecycle()
        XCTAssertTrue(lifecycle.recordValidFrame())
        XCTAssertFalse(lifecycle.completeNoFrameTimeout())
        XCTAssertTrue(lifecycle.complete(.stopped))
        XCTAssertEqual(lifecycle.outcome, .stopped)
    }

    func testNoFrameTimeoutClaimsDisabledTerminalOutcome() {
        let lifecycle = DiagnosticLifecycle()
        XCTAssertTrue(lifecycle.completeNoFrameTimeout())
        XCTAssertEqual(lifecycle.outcome, .disabled)
        XCTAssertFalse(lifecycle.complete(.stopped))
    }

    func testOnlyOneCompetingTerminalPathWins() {
        let lifecycle = DiagnosticLifecycle()
        let completions = DispatchGroup()
        let results = DispatchQueue(label: "results")
        var wins = 0

        for outcome in [DiagnosticTerminalOutcome.stopped, .disabled] {
            completions.enter()
            DispatchQueue.global().async {
                if lifecycle.complete(outcome) { results.sync { wins += 1 } }
                completions.leave()
            }
        }

        XCTAssertEqual(completions.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(wins, 1)
        XCTAssertNotNil(lifecycle.outcome)
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
