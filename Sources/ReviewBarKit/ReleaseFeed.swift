import Foundation

/// A published release, reduced to what the updater needs.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: AppVersion
    /// The release page to send the user to. Deliberately the human-readable
    /// page rather than a direct asset download: ReviewBar cannot install an
    /// update itself, so the page — with its install notes and the Gatekeeper
    /// workaround — is the honest destination.
    public let url: URL
    public let notes: String?

    public init(version: AppVersion, url: URL, notes: String? = nil) {
        self.version = version
        self.url = url
        self.notes = notes
    }
}

/// Where the newest published version comes from. A protocol so the update
/// logic can be tested without the network, matching `AnkiConnectClient`.
public protocol ReleaseFeed: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

public enum ReleaseFeedError: Error, Equatable, Sendable {
    case unreachable(String)
    case malformedResponse
    /// The endpoint answered, but not with a release — including GitHub's
    /// 404 for a repository that has never published one.
    case noRelease
    /// GitHub's unauthenticated hourly limit. Worth distinguishing: retrying
    /// sooner cannot help, so the UI stays quiet rather than showing an error.
    case rateLimited
}

/// Reads the newest release from GitHub's public API.
///
/// `/releases/latest` is the right endpoint rather than `/releases`: GitHub
/// already excludes drafts and prereleases from it, so a tagged beta never
/// prompts everyone to "update".
public struct GitHubReleaseFeed: ReleaseFeed {
    private let owner: String
    private let repository: String
    private let session: URLSession

    public init(owner: String, repository: String, timeout: TimeInterval = 15) {
        self.owner = owner
        self.repository = repository
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        // The check is a background courtesy; never let it hold up anything
        // or retry a stale answer out of the URL cache.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body, draft, prerelease
        }
    }

    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(
            url: URL(string:
                "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!)
        // GitHub rejects requests without a User-Agent, and the versioned
        // Accept header pins the response shape.
        request.setValue("ReviewBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseFeedError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 403, 429: throw ReleaseFeedError.rateLimited
            case 404: throw ReleaseFeedError.noRelease
            default: throw ReleaseFeedError.malformedResponse
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ReleaseFeedError.malformedResponse
        }
        guard payload.draft != true, payload.prerelease != true else {
            throw ReleaseFeedError.noRelease
        }
        guard let version = AppVersion(payload.tagName),
              let url = URL(string: payload.htmlUrl) else {
            throw ReleaseFeedError.malformedResponse
        }
        let notes = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseInfo(version: version, url: url,
                           notes: (notes?.isEmpty == false) ? notes : nil)
    }
}

/// Canned feed for tests and Anki-free UI work, mirroring
/// `MockAnkiConnectClient`.
public struct MockReleaseFeed: ReleaseFeed {
    private let result: Result<ReleaseInfo, ReleaseFeedError>

    public init(_ result: Result<ReleaseInfo, ReleaseFeedError>) {
        self.result = result
    }

    public init(version: String, url: String = "https://example.invalid/release") {
        self.init(.success(ReleaseInfo(version: AppVersion(version)!,
                                       url: URL(string: url)!)))
    }

    public func latestRelease() async throws -> ReleaseInfo {
        try result.get()
    }
}
