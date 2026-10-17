import Foundation
import EdgeMotionInputBridge

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

public extension ContactFrame {
    static func fromBridge(_ frame: EMDecodedFrame) -> ContactFrame? {
        guard let pointer = frame.contacts, (1...16).contains(frame.contactCount) else { return nil }
        return ContactFrame(contacts: (0..<Int(frame.contactCount)).map { index in
            let c = pointer[index]
            return Contact(deviceID: c.deviceIdentifier, pathIndex: Int(c.pathIndex), fingerID: Int(c.fingerIdentifier), x: Double(c.normalizedX), y: Double(c.normalizedY), timestamp: c.timestamp, phase: c.phase == EMContactEnded ? .ended : (c.phase == EMContactBegan ? .began : .moved))
        }, timestamp: frame.timestamp, sequence: frame.sequence)
    }
}
