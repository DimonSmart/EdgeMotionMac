import Foundation
import EdgeMotionDiagnosticCore

public struct EdgeMotionConfiguration: Sendable {
    public var edgeWidth = 0.06
    public var hysteresis = 0.015
    public var holdDelay: TimeInterval = 0.1
    public var velocityLookback: TimeInterval = 0.5
    public var maximumSpeed: Double = 750

    public init() {}
}

public enum EdgeMotionState: Equatable, Sendable { case idle, tracking, armed, active, suppressed }
public struct CursorDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Pure state machine: platform input and Quartz output stay outside this type.
public final class EdgeMotionEngine: @unchecked Sendable {
    public private(set) var state: EdgeMotionState = .idle
    public var configuration: EdgeMotionConfiguration
    private var trackedDeviceID: Int64?
    private var trackedPathIndex: Int?
    private var trackedFingerID: Int?
    private var lastContact: Contact?
    private var recentContacts: [Contact] = []
    private var hasApproachedAnEdgeFromInside = false
    private var wasInsideActivationZone = false
    private var direction = CursorDelta(x: 0, y: 0)
    private var initialActiveSpeed = 0.0
    private var armedAt: TimeInterval?
    private var lastTickAt: TimeInterval?

    public init(configuration: EdgeMotionConfiguration = .init()) { self.configuration = configuration }

    public func accept(_ frame: ContactFrame, cursorVelocity: CursorDelta? = nil) {
        guard frame.contacts.count == 1, let contact = frame.contacts.first, contact.phase != .ended else {
            reset(suppress: !frame.contacts.isEmpty)
            return
        }
        if state == .suppressed { return }
        if let trackedDeviceID, trackedDeviceID != contact.deviceID {
            reset(suppress: true)
            return
        }
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
        trackedDeviceID = contact.deviceID
        trackedPathIndex = contact.pathIndex
        trackedFingerID = contact.fingerID

        let velocity = recentVelocity(including: contact)
        lastContact = contact
        guard let edgeDirection = outwardEdgeDirection(for: contact), isStillInsideActivationZone(contact) else {
            hasApproachedAnEdgeFromInside = true
            wasInsideActivationZone = false
            if state == .armed { state = .tracking; armedAt = nil }
            if state == .active, isOutsideHysteresis(contact) { reset(suppress: false) }
            return
        }
        let outward = velocity.x * edgeDirection.x + velocity.y * edgeDirection.y
        let enteredActivationZone = !wasInsideActivationZone
        wasInsideActivationZone = true
        if state == .tracking, hasApproachedAnEdgeFromInside, enteredActivationZone, outward > 0 {
            direction = normalized(velocity, fallback: edgeDirection)
            initialActiveSpeed = min(configuration.maximumSpeed, max(0, cursorVelocity.map { hypot($0.x, $0.y) } ?? 0))
            armedAt = frame.timestamp
            state = .armed
        } else if state == .armed, outward < 0 {
            state = .tracking; armedAt = nil
        }
    }

    public func tick(at timestamp: TimeInterval) -> CursorDelta? {
        guard state == .armed || state == .active, let armedAt else { return nil }
        guard let contact = lastContact, !isOutsideHysteresis(contact) else { reset(suppress: false); return nil }
        if state == .armed {
            guard timestamp - armedAt >= configuration.holdDelay else { return nil }
            state = .active
            lastTickAt = timestamp
            return nil
        }
        guard let previousTick = lastTickAt, timestamp >= previousTick else { return nil }
        let deltaTime = timestamp - previousTick
        lastTickAt = timestamp
        guard deltaTime > 0 else { return nil }
        return CursorDelta(x: direction.x * initialActiveSpeed * deltaTime, y: -direction.y * initialActiveSpeed * deltaTime)
    }

    public func stop() { reset(suppress: false) }

    private func recentVelocity(including contact: Contact) -> CursorDelta {
        recentContacts.append(contact)
        let earliestTimestamp = contact.timestamp - max(0, configuration.velocityLookback)
        recentContacts.removeAll { $0.timestamp < earliestTimestamp }
        guard let oldest = recentContacts.first else { return CursorDelta(x: 0, y: 0) }
        let dt = contact.timestamp - oldest.timestamp
        guard dt > 0 else { return CursorDelta(x: 0, y: 0) }
        return CursorDelta(x: (contact.x - oldest.x) / dt, y: (contact.y - oldest.y) / dt)
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
        trackedDeviceID = nil; trackedPathIndex = nil; trackedFingerID = nil
        lastContact = nil; recentContacts.removeAll(); hasApproachedAnEdgeFromInside = false; wasInsideActivationZone = false; armedAt = nil
        lastTickAt = nil
        initialActiveSpeed = 0
        direction = CursorDelta(x: 0, y: 0)
    }
}
