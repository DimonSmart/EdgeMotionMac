import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EdgeMotionUpdateCore

private struct StubFetcher: ReleaseDataFetching {
    let status: Int
    let body: String
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "EdgeMotion/0.1.0")
        return (Data(body.utf8), status)
    }
}

private struct StubEnvironment: UpdateInstallationEnvironment {
    var executablePath: String? = HomebrewUpdateInstaller.executablePath
    var pathValue: String = ""
    var installed: ReleaseVersion? = ReleaseVersion("0.1.1")
    func isExecutableFile(_ path: String) -> Bool { path == "/opt/homebrew/bin/brew" }
    func installedVersion(at appPath: String) -> ReleaseVersion? { installed }
}

private actor StubCommands: UpdateCommandRunning {
    var commands: [[String]] = []
    var availableVersion = "0.1.1"
    var quarantined = false
    func run(_ executable: String, _ arguments: [String], cancellable: Bool) async -> UpdateCommandResult {
        commands.append([executable] + arguments)
        if arguments.starts(with: ["list", "--cask"]) {
            return UpdateCommandResult(exitCode: 0, output: "edgemotion 0.1.0\n")
        }
        if arguments.starts(with: ["info", "--cask"]) {
            return UpdateCommandResult(exitCode: 0, output: "{\"casks\":[{\"token\":\"edgemotion\",\"version\":\"\(availableVersion)\"}]}")
        }
        if arguments.contains("-r") && arguments.contains("-l") {
            return UpdateCommandResult(exitCode: 0, output: quarantined ? "com.apple.quarantine: flag" : "")
        }
        return UpdateCommandResult(exitCode: 0)
    }
    func calledUpgrade() -> Bool { commands.contains { $0.contains("upgrade") } }
    func calls() -> [[String]] { commands }
    func setQuarantined(_ value: Bool) { quarantined = value }
}

final class EdgeMotionUpdateTests: XCTestCase {
    private func release(_ tag: String, url: String? = nil, prerelease: Bool = false) -> String {
        "{\"tag_name\":\"\(tag)\",\"html_url\":\"\(url ?? "https://github.com/DimonSmart/EdgeMotionMac/releases/tag/\(tag)")\",\"draft\":false,\"prerelease\":\(prerelease)}"
    }

    func testReleaseVersionComparisonAndInvalidValues() {
        XCTAssertTrue(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.99")!)
        XCTAssertEqual(ReleaseVersion("v1.2.3+build")?.description, "1.2.3")
        for input in ["", "development", "v1.2", "v1.2.3-beta", "v1..2", "v1.2.-1", "v999999999999999999999.1.2"] {
            XCTAssertNil(ReleaseVersion(input), input)
        }
    }

    func testGitHubReleaseComparisonAndValidation() async {
        let newer = GitHubReleaseChecker(fetcher: StubFetcher(status: 200, body: release("v0.2.0")))
        let newerResult = await newer.check(currentVersion: "0.1.0")
        XCTAssertEqual(newerResult,
                       .available(ReleaseVersion("0.2.0")!, URL(string: "https://github.com/DimonSmart/EdgeMotionMac/releases/tag/v0.2.0")!))
        let older = GitHubReleaseChecker(fetcher: StubFetcher(status: 200, body: release("v0.0.9")))
        let olderResult = await older.check(currentVersion: "0.1.0")
        XCTAssertEqual(olderResult, .upToDate(ReleaseVersion("0.0.9")!))
        let invalid = GitHubReleaseChecker(fetcher: StubFetcher(status: 200, body: release("v0.2.0", url: "https://example.org/evil")))
        let invalidResult = await invalid.check(currentVersion: "0.1.0")
        XCTAssertEqual(invalidResult, .unavailable)
        let pre = GitHubReleaseChecker(fetcher: StubFetcher(status: 200, body: release("v0.2.0", prerelease: true)))
        let prereleaseResult = await pre.check(currentVersion: "0.1.0")
        XCTAssertEqual(prereleaseResult, .unavailable)
    }

    func testCannotAutoUpdateManualCopy() async {
        let environment = StubEnvironment(executablePath: "/tmp/EdgeMotion.app/Contents/MacOS/EdgeMotion")
        let commands = StubCommands()
        let installer = HomebrewUpdateInstaller(runner: commands, environment: environment)
        let availability = await installer.availability()
        XCTAssertEqual(availability, .unavailable("Automatic update requires /Applications/EdgeMotion.app installed with Homebrew."))
        let upgraded = await commands.calledUpgrade()
        XCTAssertFalse(upgraded)
    }

    func testHomebrewUpdateAndVerification() async {
        let commands = StubCommands()
        let installer = HomebrewUpdateInstaller(runner: commands, environment: StubEnvironment())
        let availability = await installer.availability()
        XCTAssertEqual(availability, .available("/opt/homebrew/bin/brew"))
        let result = await installer.install(expected: ReleaseVersion("0.1.1")!) { _ in }
        XCTAssertEqual(result, .installed(ReleaseVersion("0.1.1")!))
        let calls = await commands.calls()
        XCTAssertTrue(calls.contains { $0.contains("upgrade") && $0.contains("--no-quit") })
        XCTAssertTrue(calls.contains { $0.contains("-dr") && $0.contains("com.apple.quarantine") })
    }

    func testReleaseBeforeCaskUpdateDoesNotUpgrade() async {
        let commands = StubCommands()
        let installer = HomebrewUpdateInstaller(runner: commands, environment: StubEnvironment())
        let result = await installer.install(expected: ReleaseVersion("0.1.2")!) { _ in }
        XCTAssertEqual(result, .packageNotPublished)
        let upgraded = await commands.calledUpgrade()
        XCTAssertFalse(upgraded)
    }

    func testMissingInstalledVersionFailsSafely() async {
        let commands = StubCommands()
        let installer = HomebrewUpdateInstaller(runner: commands, environment: StubEnvironment(installed: nil))
        let result = await installer.install(expected: ReleaseVersion("0.1.1")!) { _ in }
        if case .failed = result {} else { XCTFail("Expected verification failure") }
    }

    func testQuarantineFailureDoesNotReportSuccess() async {
        let commands = StubCommands()
        await commands.setQuarantined(true)
        let installer = HomebrewUpdateInstaller(runner: commands, environment: StubEnvironment())
        let result = await installer.install(expected: ReleaseVersion("0.1.1")!) { _ in }
        if case .failed(let message) = result { XCTAssertTrue(message.contains("quarantine")) }
        else { XCTFail("Expected quarantine failure") }
    }
}
