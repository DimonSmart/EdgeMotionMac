import Foundation

public protocol UpdateInstallationEnvironment {
    var executablePath: String? { get }
    var pathValue: String { get }
    func isExecutableFile(_ path: String) -> Bool
    func installedVersion(at appPath: String) -> ReleaseVersion?
}

public struct SystemUpdateInstallationEnvironment: UpdateInstallationEnvironment {
    public init() {}
    public var executablePath: String? { Bundle.main.executableURL?.path }
    public var pathValue: String { ProcessInfo.processInfo.environment["PATH"] ?? "" }
    public func isExecutableFile(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    public func installedVersion(at appPath: String) -> ReleaseVersion? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let properties = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = properties as? [String: Any],
              values["CFBundleIdentifier"] as? String == "io.github.dimonsmart.EdgeMotion",
              values["CFBundleExecutable"] as? String == "EdgeMotion",
              let version = values["CFBundleShortVersionString"] as? String else { return nil }
        return ReleaseVersion(version)
    }
}

public struct HomebrewUpdateInstaller {
    public static let appPath = "/Applications/EdgeMotion.app"
    public static let executablePath = "/Applications/EdgeMotion.app/Contents/MacOS/EdgeMotion"
    public static let caskName = "edgemotion"
    private let runner: UpdateCommandRunning
    private let environment: UpdateInstallationEnvironment

    public init(runner: UpdateCommandRunning = LocalUpdateCommandRunner(),
                environment: UpdateInstallationEnvironment = SystemUpdateInstallationEnvironment()) {
        self.runner = runner
        self.environment = environment
    }

    private func findBrew() -> String? {
        let paths = environment.pathValue.split(separator: ":").map { String($0) + "/brew" }
        let candidates = paths + ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates where candidate.hasPrefix("/") && environment.isExecutableFile(candidate) {
            return URL(fileURLWithPath: candidate).standardizedFileURL.path
        }
        return nil
    }

    public func availability() async -> UpdateAvailability {
        guard environment.executablePath == Self.executablePath else {
            return .unavailable("Automatic update requires /Applications/EdgeMotion.app installed with Homebrew.")
        }
        guard let brew = findBrew() else { return .unavailable("Homebrew was not found.") }
        let installed = await runner.run(brew, ["list", "--cask", "--versions", Self.caskName], cancellable: true)
        if Task.isCancelled { return .unavailable("Cancelled") }
        guard installed.exitCode == 0,
              installed.output.split(whereSeparator: \.isNewline).contains(where: { $0.split(separator: " ").first == Substring(Self.caskName) }) else {
            return .unavailable("EdgeMotion is not installed through its Homebrew Cask.")
        }
        return .available(brew)
    }

    public func install(expected: ReleaseVersion,
                        progress: @escaping (UpdateProgress) -> Void) async -> UpdateInstallResult {
        progress(.checkingHomebrew)
        guard case .available(let brew) = await availability() else {
            return Task.isCancelled ? .cancelled : .failed("This EdgeMotion copy is not managed by Homebrew.")
        }
        if Task.isCancelled { return .cancelled }

        progress(.refreshingMetadata)
        let refresh = await runner.run(brew, ["update"], cancellable: true)
        if Task.isCancelled { return .cancelled }
        guard refresh.exitCode == 0 else { return .failed("Homebrew metadata update failed.") }

        progress(.checkingPackage)
        let info = await runner.run(brew, ["info", "--cask", "--json=v2", Self.caskName], cancellable: true)
        if Task.isCancelled { return .cancelled }
        guard info.exitCode == 0, let available = Self.parseCaskVersion(info.output) else {
            return .failed("Unable to determine Homebrew Cask version.")
        }
        guard available >= expected else { return .packageNotPublished }

        // After this boundary Homebrew must finish without cancellation.
        if Task.isCancelled { return .cancelled }
        progress(.installing)
        let upgrade = await runner.run(brew,
            ["upgrade", "--cask", "--no-quit", "--appdir=/Applications", Self.caskName], cancellable: false)
        if upgrade.exitCode != 0 &&
            !upgrade.output.localizedCaseInsensitiveContains("already up-to-date") &&
            !upgrade.error.localizedCaseInsensitiveContains("already up-to-date") {
            return .failed("Homebrew could not install the update.")
        }
        progress(.verifying)
        guard let installed = environment.installedVersion(at: Self.appPath), installed >= expected else {
            return .failed("Update installed, but the application version could not be verified.")
        }

        progress(.removingQuarantine)
        let xattr = await runner.run("/usr/bin/xattr",
            ["-dr", "com.apple.quarantine", Self.appPath], cancellable: false)
        let check = await runner.run("/usr/bin/xattr",
            ["-r", "-l", Self.appPath], cancellable: false)
        guard xattr.exitCode == 0, check.exitCode == 0,
              !check.output.contains("com.apple.quarantine") else {
            return .failed("EdgeMotion was updated but macOS quarantine could not be removed. Run: xattr -dr com.apple.quarantine /Applications/EdgeMotion.app")
        }
        return .installed(installed)
    }

    public static func parseCaskVersion(_ json: String) -> ReleaseVersion? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let cask = casks.first(where: { $0["token"] as? String == caskName }),
              let string = cask["version"] as? String else { return nil }
        return ReleaseVersion(string)
    }
}
