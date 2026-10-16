import XCTest
@testable import EdgeMotionDiagnosticCore

final class FrameValidatorTests: XCTestCase {
    private func frame(sequence: Int64 = 1, contacts: [Contact]? = nil) -> ContactFrame {
        let timestamp = 10.0
        return ContactFrame(contacts: contacts ?? [Contact(deviceID: 1, pathIndex: 2, fingerID: 2, x: 0.5, y: 0.5, timestamp: timestamp, phase: .moved)], timestamp: timestamp, sequence: sequence)
    }
    func testAcceptsNormalizedUniqueContactsAndIncreasingSequence() {
        XCTAssertEqual(FrameValidator.validate(frame(), previousSequence: 0), .success(()))
    }
    func testRejectsInvalidCoordinatesAndDuplicateIdentity() {
        XCTAssertEqual(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 1.1, y: 0, timestamp: 10, phase: .moved)]), previousSequence: nil), .failure(.invalidCoordinate))
        XCTAssertEqual(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .moved), Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .ended)]), previousSequence: nil), .failure(.duplicateIdentity))
    }

    func testRejectsNegativePathIndex() {
        XCTAssertEqual(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: -1, fingerID: 1, x: 0, y: 0, timestamp: 10, phase: .moved)]), previousSequence: nil), .failure(.invalidIdentity))
    }
    func testRejectsNonMonotonicAndInconsistentFrames() {
        XCTAssertEqual(FrameValidator.validate(frame(sequence: 4), previousSequence: 4), .failure(.invalidSequence))
        XCTAssertEqual(FrameValidator.validate(frame(contacts: [Contact(deviceID: 1, pathIndex: 1, fingerID: 1, x: 0, y: 0, timestamp: 11, phase: .moved)]), previousSequence: nil), .failure(.inconsistentTimestamp))
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
}
