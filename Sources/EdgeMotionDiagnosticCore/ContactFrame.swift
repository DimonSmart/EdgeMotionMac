import Foundation
import EdgeMotionDiagnosticBridge

public enum ContactPhase: Equatable, Sendable { case began, moved, ended }

public struct Contact: Equatable, Sendable {
    public let deviceID: Int64
    public let pathIndex: Int
    public let fingerID: Int
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval
    public let phase: ContactPhase
}

public struct ContactFrame: Equatable, Sendable {
    public let contacts: [Contact]
    public let timestamp: TimeInterval
    public let sequence: Int64
}

public enum FrameValidationError: Error, Equatable, Sendable { case empty, tooManyContacts, invalidTimestamp, invalidSequence, inconsistentTimestamp, invalidIdentity, duplicateIdentity, invalidCoordinate }

public enum FrameValidator {
    public static func validate(_ frame: ContactFrame, previousSequence: Int64?) -> Result<Void, FrameValidationError> {
        guard !frame.contacts.isEmpty else { return .failure(.empty) }
        guard frame.contacts.count <= 16 else { return .failure(.tooManyContacts) }
        guard frame.timestamp.isFinite, frame.timestamp > 0 else { return .failure(.invalidTimestamp) }
        guard frame.sequence >= 0, previousSequence.map({ frame.sequence > $0 }) ?? true else { return .failure(.invalidSequence) }
        var identities = Set<String>()
        for contact in frame.contacts {
            guard contact.deviceID != 0, contact.pathIndex >= 0, contact.fingerID >= 0 else { return .failure(.invalidIdentity) }
            guard identities.insert("\(contact.deviceID):\(contact.pathIndex):\(contact.fingerID)").inserted else { return .failure(.duplicateIdentity) }
            guard contact.x.isFinite, contact.y.isFinite, (0...1).contains(contact.x), (0...1).contains(contact.y) else { return .failure(.invalidCoordinate) }
            guard abs(contact.timestamp - frame.timestamp) < 0.001 else { return .failure(.inconsistentTimestamp) }
        }
        return .success(())
    }
}

public enum DiagnosticState: Equatable, Sendable { case idle, active, disabled(String) }

public enum DiagnosticFrameAcceptance: Equatable, Sendable { case accepted, ignored, disabled(String) }

public enum DiagnosticTerminalOutcome: Equatable, Sendable {
    case stopped
    case disabled
}

/// Coordinates the diagnostic's one-way transition to a terminal outcome.
/// The hardware callback only records that validation has succeeded; terminal
/// effects remain the runner's responsibility on its processing queue.
public final class DiagnosticLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var hasValidFrame = false
    private var terminalOutcome: DiagnosticTerminalOutcome?

    public init() {}

    /// Returns true only for the first valid frame, which is the caller's cue
    /// to cancel its one-shot no-frame deadline.
    @discardableResult public func recordValidFrame() -> Bool {
        lock.withLock {
            guard terminalOutcome == nil, !hasValidFrame else { return false }
            hasValidFrame = true
            return true
        }
    }

    /// Atomically claims terminal completion for a non-timeout path.
    @discardableResult public func complete(_ outcome: DiagnosticTerminalOutcome) -> Bool {
        lock.withLock {
            guard terminalOutcome == nil else { return false }
            terminalOutcome = outcome
            return true
        }
    }

    /// Atomically claims the no-valid-frame timeout only when it is still valid.
    @discardableResult public func completeNoFrameTimeout() -> Bool {
        lock.withLock {
            guard terminalOutcome == nil, !hasValidFrame else { return false }
            terminalOutcome = .disabled
            return true
        }
    }

    public var outcome: DiagnosticTerminalOutcome? { lock.withLock { terminalOutcome } }
}

public final class DiagnosticSession: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: DiagnosticState = .idle
    private var currentLastSequence: Int64?
    public var state: DiagnosticState { lock.withLock { currentState } }
    public var lastSequence: Int64? { lock.withLock { currentLastSequence } }
    public init() {}
    /// Invalid data only changes state; it never reaches the output closure.
    @discardableResult public func accept(_ frame: ContactFrame, output: (ContactFrame) -> Void) -> DiagnosticFrameAcceptance {
        let result: DiagnosticFrameAcceptance = lock.withLock {
            guard case .active = currentState else { return .ignored }
            switch FrameValidator.validate(frame, previousSequence: currentLastSequence) {
            case .success:
                currentLastSequence = frame.sequence
                return .accepted
            case .failure(let error):
                let reason = "frame validation: \(error)"
                currentState = .disabled(reason)
                return .disabled(reason)
            }
        }
        if result == .accepted { output(frame) }
        return result
    }
    public func startIfReady(_ ready: Bool) { lock.withLock { currentState = ready ? .active : .disabled("backend unavailable"); currentLastSequence = nil } }
    public func disable(_ reason: String) { lock.withLock { currentState = .disabled(reason); currentLastSequence = nil } }
    public func stop() { lock.withLock { if case .active = currentState { currentState = .idle }; currentLastSequence = nil } }
}

public extension ContactFrame {
    static func fromBridge(_ frame: EMDecodedFrame) -> ContactFrame? {
        guard let pointer = frame.contacts, (1...16).contains(frame.contactCount) else { return nil }
        return ContactFrame(contacts: (0..<Int(frame.contactCount)).map { index in
            let c = pointer[index]
            return Contact(deviceID: c.deviceIdentifier, pathIndex: Int(c.pathIndex), fingerID: Int(c.fingerIdentifier), x: Double(c.normalizedX), y: Double(c.normalizedY), timestamp: c.timestamp, phase: c.phase == EMContactEnded ? .ended : (c.phase == EMContactBegan ? .began : .moved))
        }, timestamp: frame.timestamp, sequence: frame.sequence)
    }
}
