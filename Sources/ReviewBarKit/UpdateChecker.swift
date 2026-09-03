import Foundation

/// Where the update check has got to. `.unsupported` is its own case rather
/// than an error: a `swift run` build has no bundle version to compare, and
/// telling a developer their build is out of date would be noise.
public enum UpdateStatus: Sendable, Equatable {
    case unsupported
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case failed(ReleaseFeedError)

    public var availableRelease: ReleaseInfo? {
        if case .available(let release) = self { return release }
        return nil
    }
}

/// Checks GitHub for a newer release and remembers the answer.
///
/// ReviewBar cannot install an update itself — Sparkle, the usual way to do
/// that, ships only as a framework, and library validation (which hardened
/// runtime turns on and notarization requires) refuses to load a framework
/// that doesn't share the app's Team ID. So this tells the user and opens the
/// release page, and stays useful as the fallback once Sparkle is added on top
/// of a Developer ID build.
///
/// It owns no timer: `AppState.tick()` drives it, like everything else with a
/// schedule in this app.
@MainActor
@Observable
public final class UpdateChecker {
    /// One day. The check is a courtesy, and GitHub's unauthenticated API
    /// allows 60 requests an hour per IP — there is nothing to gain by asking
    /// more often, and a menu-bar app that outlives reboots would burn it.
    public static let defaultInterval: TimeInterval = 86_400

    public private(set) var status: UpdateStatus
    public private(set) var lastCheckedAt: Date?
    /// A version the user asked not to be told about again. Cleared once
    /// something newer than it appears.
    public private(set) var skippedVersion: AppVersion?

    /// Whether the tick loop checks on its own. A manual `check(force:)` still
    /// works when this is off, which is why the menu keeps a "Check Now".
    public var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            defaults.set(automaticallyChecks, forKey: Self.automaticKey)
        }
    }

    public let currentVersion: AppVersion?

    private let feed: any ReleaseFeed
    private let interval: TimeInterval
    private let defaults: UserDefaults
    private var isChecking = false

    private static let lastCheckedKey = "updateLastCheckedAt"
    private static let skippedKey = "updateSkippedVersion"
    private static let automaticKey = "updateAutomaticallyChecks"

    public init(feed: any ReleaseFeed,
                currentVersion: AppVersion? = AppVersion.current(),
                interval: TimeInterval = UpdateChecker.defaultInterval,
                defaults: UserDefaults = .standard) {
        self.feed = feed
        self.currentVersion = currentVersion
        self.interval = interval
        self.defaults = defaults
        self.status = currentVersion == nil ? .unsupported : .idle
        self.lastCheckedAt = defaults.object(forKey: Self.lastCheckedKey) as? Date
        self.skippedVersion = (defaults.string(forKey: Self.skippedKey))
            .flatMap(AppVersion.init)
        self.automaticallyChecks = defaults.object(forKey: Self.automaticKey) == nil
            ? true
            : defaults.bool(forKey: Self.automaticKey)
    }

    /// True when enough time has passed for an automatic check. Computed from
    /// `now` rather than a countdown, so it survives sleep and clock changes
    /// the same way the reminder scheduler does.
    public func isDue(now: Date = Date()) -> Bool {
        guard automaticallyChecks, currentVersion != nil else { return false }
        guard let lastCheckedAt else { return true }
        // A last-checked stamp in the future means the clock moved backwards;
        // treat it as due rather than going quiet until it catches up.
        if lastCheckedAt > now { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// Called from the app's tick loop; does nothing until a check is due.
    public func checkIfDue(now: Date = Date()) async {
        guard isDue(now: now) else { return }
        await check(now: now)
    }

    /// Ask now. `force` also clears a skip, so "Check for Updates…" from the
    /// menu always gives an answer rather than silently honouring a skip the
    /// user has forgotten about.
    public func check(force: Bool = false, now: Date = Date()) async {
        guard let currentVersion else { return }
        guard !isChecking else { return }
        isChecking = true
        status = .checking
        defer { isChecking = false }

        if force { clearSkip() }

        do {
            let release = try await feed.latestRelease()
            // Stamp only on success: a failed check shouldn't buy a full
            // interval of silence.
            lastCheckedAt = now
            defaults.set(now, forKey: Self.lastCheckedKey)

            // Something newer than the skipped version supersedes the skip.
            if let skipped = skippedVersion, release.version > skipped {
                clearSkip()
            }
            if release.version > currentVersion, release.version != skippedVersion {
                status = .available(release)
            } else {
                status = .upToDate
            }
        } catch let error as ReleaseFeedError {
            status = .failed(error)
        } catch {
            status = .failed(.unreachable(error.localizedDescription))
        }
    }

    /// Stop mentioning this version. The next release supersedes it.
    public func skip(_ version: AppVersion) {
        skippedVersion = version
        defaults.set(version.description, forKey: Self.skippedKey)
        if status.availableRelease?.version == version {
            status = .upToDate
        }
    }

    private func clearSkip() {
        skippedVersion = nil
        defaults.removeObject(forKey: Self.skippedKey)
    }
}
