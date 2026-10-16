import Foundation

public struct ReleaseVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ input: String) {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum UpdateCheckResult: Equatable {
    case upToDate(ReleaseVersion)
    case available(ReleaseVersion, URL)
    case unavailable
}

public enum UpdateAvailability: Equatable {
    case available(String)
    case unavailable(String)
}

public enum UpdateProgress: Equatable {
    case checkingHomebrew
    case refreshingMetadata
    case checkingPackage
    case installing
    case verifying
    case removingQuarantine

    public var allowsCancellation: Bool {
        switch self {
        case .checkingHomebrew, .refreshingMetadata, .checkingPackage: return true
        case .installing, .verifying, .removingQuarantine: return false
        }
    }

    public var message: String {
        switch self {
        case .checkingHomebrew: return "Checking Homebrew installation..."
        case .refreshingMetadata: return "Updating Homebrew metadata..."
        case .checkingPackage: return "Checking available package..."
        case .installing: return "Installing EdgeMotion..."
        case .verifying: return "Verifying installed version..."
        case .removingQuarantine: return "Preparing unsigned app for launch..."
        }
    }
}

public enum UpdateInstallResult: Equatable {
    case installed(ReleaseVersion)
    case cancelled
    case packageNotPublished
    case failed(String)
}
