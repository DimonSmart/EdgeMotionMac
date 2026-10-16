import Foundation
import EdgeMotionDiagnosticCore

public struct EdgeMotionConfiguration: Sendable {
    public var edgeWidth = 0.06
    public var hysteresis = 0.015
    public var holdDelay: TimeInterval = 0.1
    public var minimumOutwardVelocity = 0.20
    public var initialSpeed: Double = 180
    public var maximumSpeed: Double = 750
    public var accelerationRamp: TimeInterval = 0.9

    public init() {}
}

public enum EdgeMotionState: Equatable, Sendable { case idle, tracking, armed, active, suppressed }
public struct CursorDelta: Equatable, Sendable { public let x: Double; public let y: Double }

/// Pure state machine: platform input and Quartz output stay outside this type.
public final class EdgeMotionEngine: @unchecked Sendable {
    public private(set) var state: EdgeMotionState = .idle
    public var configuration: EdgeMotionConfiguration
    private var trackedPathIndex: Int?
    private var trackedFingerID: Int?
    private var lastContact: Contact?
    private var lastTimestamp: TimeInterval?
    private var direction = CursorDelta(x: 0, y: 0)
    private var armedAt: TimeInterval?
    private var activeAt: TimeInterval?

    public init(configuration: EdgeMotionConfiguration = .init()) { self.configuration = configuration }

    public func accept(_ frame: ContactFrame) {
        guard frame.contacts.count == 1, let contact = frame.contacts.first, contact.phase != .ended else {
            reset(suppress: !frame.contacts.isEmpty)
            return
        }
        if state == .suppressed { return }
        if let trackedPathIndex, let trackedFingerID,
           trackedPathIndex != contact.pathIndex && trackedFingerID != contact.fingerID {
            reset(suppress: true)
            return
        }
        if self.trackedPathIndex == nil {
            state = .tracking
        }
        // The private API exposes two observed identifiers. Either may be
        // transient on the first frames, so only a change in both identifies a
        // replacement contact; retain the newest observed pair otherwise.
        trackedPathIndex = contact.pathIndex
        trackedFingerID = contact.fingerID

        let velocity = calculateVelocity(for: contact)
        lastContact = contact
        lastTimestamp = frame.timestamp
        guard let edgeDirection = outwardEdgeDirection(for: contact), isStillInsideActivationZone(contact) else {
            if state == .armed { state = .tracking; armedAt = nil }
            if state == .active, isOutsideHysteresis(contact) { reset(suppress: false) }
            return
        }
        let outward = velocity.x * edgeDirection.x + velocity.y * edgeDirection.y
        if state == .tracking, outward >= configuration.minimumOutwardVelocity {
            direction = normalized(velocity, fallback: edgeDirection)
            armedAt = frame.timestamp
            state = .armed
        } else if state == .armed, outward <= -configuration.minimumOutwardVelocity {
            state = .tracking; armedAt = nil
        }
    }

    public func tick(at timestamp: TimeInterval) -> CursorDelta? {
        guard state == .armed || state == .active, let armedAt else { return nil }
        guard let contact = lastContact, !isOutsideHysteresis(contact) else { reset(suppress: false); return nil }
        if state == .armed {
            guard timestamp - armedAt >= configuration.holdDelay else { return nil }
            state = .active; activeAt = timestamp
        }
        let elapsed = max(0, timestamp - (activeAt ?? timestamp))
        let progress = min(1, elapsed / configuration.accelerationRamp)
        let speed = configuration.initialSpeed + (configuration.maximumSpeed - configuration.initialSpeed) * progress
        // The display timer supplies ~1/60-second ticks; the exact elapsed time
        // is deliberately carried by the caller in later integration work.
        return CursorDelta(x: direction.x * speed / 60, y: -direction.y * speed / 60)
    }

    public func stop() { reset(suppress: false) }

    private func calculateVelocity(for contact: Contact) -> CursorDelta {
        guard let previous = lastContact, let previousTime = lastTimestamp else { return CursorDelta(x: 0, y: 0) }
        let dt = contact.timestamp - previousTime
        guard dt > 0 else { return CursorDelta(x: 0, y: 0) }
        return CursorDelta(x: (contact.x - previous.x) / dt, y: (contact.y - previous.y) / dt)
    }

    private func outwardEdgeDirection(for contact: Contact) -> CursorDelta? {
        var x = 0.0; var y = 0.0
        if contact.x <= configuration.edgeWidth { x -= 1 }
        if contact.x >= 1 - configuration.edgeWidth { x += 1 }
        if contact.y <= configuration.edgeWidth { y -= 1 }
        if contact.y >= 1 - configuration.edgeWidth { y += 1 }
        return (x == 0 && y == 0) ? nil : normalized(CursorDelta(x: x, y: y), fallback: CursorDelta(x: 0, y: 0))
    }

    private func isStillInsideActivationZone(_ contact: Contact) -> Bool { outwardEdgeDirection(for: contact) != nil }
    private func isOutsideHysteresis(_ contact: Contact) -> Bool {
        let e = configuration.edgeWidth + configuration.hysteresis
        return contact.x > e && contact.x < 1 - e && contact.y > e && contact.y < 1 - e
    }
    private func normalized(_ value: CursorDelta, fallback: CursorDelta) -> CursorDelta {
        let magnitude = hypot(value.x, value.y)
        return magnitude > 0 ? CursorDelta(x: value.x / magnitude, y: value.y / magnitude) : fallback
    }
    private func reset(suppress: Bool) {
        state = suppress ? .suppressed : .idle
        trackedPathIndex = nil; trackedFingerID = nil
        lastContact = nil; lastTimestamp = nil; armedAt = nil; activeAt = nil
        direction = CursorDelta(x: 0, y: 0)
    }
}
