import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ReleaseDataFetching {
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
}

public final class URLSessionReleaseFetcher: ReleaseDataFetching {
    private let session: URLSession

    public init(timeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let cancellation = URLSessionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    guard let data = data, let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: (data, response.statusCode))
                }
                cancellation.register(task)
                task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class URLSessionCancellation {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func register(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

public struct GitHubReleaseChecker {
    public static let latestURL = URL(string: "https://api.github.com/repos/DimonSmart/EdgeMotionMac/releases/latest")!
    private let fetcher: ReleaseDataFetching

    public init(fetcher: ReleaseDataFetching = URLSessionReleaseFetcher()) {
        self.fetcher = fetcher
    }

    public func check(currentVersion: String) async -> UpdateCheckResult {
        guard let current = ReleaseVersion(currentVersion) else { return .unavailable }
        var request = URLRequest(url: Self.latestURL)
        request.setValue("EdgeMotion/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, status) = try await fetcher.fetch(request)
            guard status == 200 else { return .unavailable }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let latest = ReleaseVersion(release.tagName), !release.draft, !release.prerelease,
                  let url = URL(string: release.htmlURL),
                  url.scheme == "https", url.host == "github.com",
                  url.path == "/DimonSmart/EdgeMotionMac/releases/tag/v\(latest)" else {
                return .unavailable
            }
            return latest > current ? .available(latest, url) : .upToDate(latest)
        } catch {
            return .unavailable
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease
    }
}
