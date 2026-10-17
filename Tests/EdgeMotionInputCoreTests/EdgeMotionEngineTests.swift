import XCTest
import EdgeMotionCore
@testable import EdgeMotionInputCore

final class EdgeMotionEngineTests: XCTestCase {
    private func contact(
        device: Int64 = 1,
        path: Int = 4,
        finger: Int = 9,
        x: Double,
        y: Double = 0.5,
        time: TimeInterval,
        phase: ContactPhase = .moved
    ) -> Contact {
        Contact(deviceID: device, pathIndex: path, fingerID: finger, x: x, y: y, timestamp: time, phase: phase)
    }

    private func frame(_ contact: Contact, sequence: Int64) -> ContactFrame {
        ContactFrame(contacts: [contact], timestamp: contact.timestamp, sequence: sequence)
    }

    func testActiveMotionUsesElapsedTimeNotTimerFrequency() throws {
        var configuration = EdgeMotionConfiguration()
        configuration.holdDelay = 0
        configuration.maximumSpeed = 100
        let engine = EdgeMotionEngine(configuration: configuration)

        engine.accept(frame(contact(x: 0.30, time: 1), sequence: 1))
        engine.accept(frame(contact(x: 0.01, time: 1.1), sequence: 2), cursorVelocity: CursorDelta(x: -100, y: 0))
        XCTAssertNil(engine.tick(at: 1.1))
        XCTAssertEqual(engine.state, .active)
        let firstDelta = try XCTUnwrap(engine.tick(at: 1.2))
        XCTAssertEqual(firstDelta.x, -10, accuracy: 0.000_001)
        XCTAssertEqual(firstDelta.y, 0, accuracy: 0.000_001)
        let secondDelta = try XCTUnwrap(engine.tick(at: 1.45))
        XCTAssertEqual(secondDelta.x, -25, accuracy: 0.000_001)
        XCTAssertEqual(secondDelta.y, 0, accuracy: 0.000_001)
    }

    func testMotionSpeedMatchesObservedCursorSpeedWithoutAcceleration() throws {
        var configuration = EdgeMotionConfiguration()
        configuration.holdDelay = 0
        configuration.maximumSpeed = 100

        let slow = EdgeMotionEngine(configuration: configuration)
        slow.accept(frame(contact(x: 0.08, time: 0), sequence: 1))
        slow.accept(frame(contact(x: 0.06, time: 0.1), sequence: 2), cursorVelocity: CursorDelta(x: -20, y: 0))
        XCTAssertNil(slow.tick(at: 0.1))
        let slowDelta = try XCTUnwrap(slow.tick(at: 0.2))

        let fast = EdgeMotionEngine(configuration: configuration)
        fast.accept(frame(contact(x: 0.08, time: 0), sequence: 1))
        fast.accept(frame(contact(x: 0.04, time: 0.1), sequence: 2), cursorVelocity: CursorDelta(x: -40, y: 0))
        XCTAssertNil(fast.tick(at: 0.1))
        let fastDelta = try XCTUnwrap(fast.tick(at: 0.2))

        XCTAssertLessThan(abs(slowDelta.x), abs(fastDelta.x))
        XCTAssertEqual(slowDelta.x, -2, accuracy: 0.000_001)
        XCTAssertEqual(fastDelta.x, -4, accuracy: 0.000_001)
    }

    func testArbitrarilySlowApproachFromInsideActivates() {
        var configuration = EdgeMotionConfiguration()
        configuration.holdDelay = 0
        let engine = EdgeMotionEngine(configuration: configuration)

        engine.accept(frame(contact(x: 0.5, time: 0), sequence: 1))
        engine.accept(frame(contact(x: 0.06005, time: 0.5), sequence: 2))
        engine.accept(frame(contact(x: 0.06, time: 1), sequence: 3), cursorVelocity: CursorDelta(x: -0.1, y: 0))
        XCTAssertNil(engine.tick(at: 1))
        XCTAssertEqual(engine.state, .active)
    }

    func testTouchingInAnEdgeCornerDoesNotActivateFromJitter() {
        var configuration = EdgeMotionConfiguration()
        configuration.holdDelay = 0
        let engine = EdgeMotionEngine(configuration: configuration)

        engine.accept(frame(contact(x: 0.02, y: 0.02, time: 0, phase: .began), sequence: 1))
        engine.accept(frame(contact(x: 0.01, y: 0.01, time: 0.1), sequence: 2))
        XCTAssertNil(engine.tick(at: 0.1))
        XCTAssertEqual(engine.state, .tracking)
    }

    func testChangingOnlyOneObservedIdentifierDoesNotSuppressSequence() {
        let engine = EdgeMotionEngine()
        engine.accept(frame(contact(path: 4, finger: 9, x: 0.30, time: 1), sequence: 1))
        engine.accept(frame(contact(path: 5, finger: 9, x: 0.01, time: 2), sequence: 2))
        XCTAssertNotEqual(engine.state, .suppressed)
    }

    func testChangingBothIdentifiersOrDeviceSuppressesSequence() {
        let engine = EdgeMotionEngine()
        engine.accept(frame(contact(path: 4, finger: 9, x: 0.30, time: 1), sequence: 1))
        engine.accept(frame(contact(path: 5, finger: 10, x: 0.01, time: 2), sequence: 2))
        XCTAssertEqual(engine.state, .suppressed)

        let other = EdgeMotionEngine()
        other.accept(frame(contact(x: 0.30, time: 1), sequence: 1))
        other.accept(frame(contact(device: 2, x: 0.01, time: 2), sequence: 2))
        XCTAssertEqual(other.state, .suppressed)
    }
}
