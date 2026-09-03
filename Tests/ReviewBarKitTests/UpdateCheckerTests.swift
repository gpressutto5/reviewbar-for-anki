import Foundation
import Testing
@testable import ReviewBarKit

@Suite("AppVersion")
struct AppVersionTests {
    @Test("parses tags and bundle strings to the same value")
    func parsesBothForms() {
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        #expect(AppVersion("  v0.1.0 ") == AppVersion("0.1.0"))
    }

    @Test("missing components read as zero")
    func padsComponents() {
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1") == AppVersion("1.0.0"))
    }

    @Test("orders numerically, not lexicographically")
    func ordersNumerically() {
        // The whole reason this type exists: "0.10.0" < "0.9.0" as strings.
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("2.0.1")! > AppVersion("2.0.0")!)
    }

    @Test("a prerelease is older than the same numbers released")
    func prereleaseOrdering() {
        #expect(AppVersion("1.0.0-beta.1")! < AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.0-beta.1")! < AppVersion("1.0.0-beta.2")!)
        #expect(AppVersion("1.0.0")!.isPrerelease == false)
        #expect(AppVersion("1.0.0-rc1")!.isPrerelease)
    }

    @Test("build metadata is ignored")
    func ignoresBuildMetadata() {
        #expect(AppVersion("1.2.3+abc") == AppVersion("1.2.3"))
    }

    @Test("rejects nonsense")
    func rejectsNonsense() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("1.x.3") == nil)
        #expect(AppVersion("-1.0") == nil)
    }

    @Test("round-trips through its description")
    func roundTrips() {
        for text in ["1.2.3", "0.1.0", "1.0.0-beta.2"] {
            #expect(AppVersion(text)!.description == text)
        }
    }
}

@Suite("UpdateChecker")
@MainActor
struct UpdateCheckerTests {
    /// A defaults suite per test, so persistence is exercised without any two
    /// tests sharing state.
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    private func checker(feed: any ReleaseFeed,
                         current: String? = "1.0.0",
                         interval: TimeInterval = 86_400,
                         defaults: UserDefaults? = nil) -> UpdateChecker {
        UpdateChecker(feed: feed,
                      currentVersion: current.flatMap(AppVersion.init),
                      interval: interval,
                      defaults: defaults ?? self.defaults())
    }

    @Test("reports an available update when the release is newer")
    func reportsNewer() async {
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"))
        await checker.check()
        #expect(checker.status.availableRelease?.version == AppVersion("1.1.0"))
    }

    @Test("stays quiet when the release matches or trails the running build")
    func staysQuiet() async {
        for version in ["1.0.0", "0.9.0"] {
            let checker = checker(feed: MockReleaseFeed(version: version))
            await checker.check()
            #expect(checker.status == .upToDate)
        }
    }

    @Test("a build with no bundle version never claims to be out of date")
    func unsupportedWithoutBundleVersion() async {
        // How `swift run` launches the app: no Info.plist, so no version.
        let checker = checker(feed: MockReleaseFeed(version: "9.9.9"), current: nil)
        #expect(checker.status == .unsupported)
        await checker.check()
        #expect(checker.status == .unsupported)
        #expect(checker.isDue() == false)
    }

    @Test("a failed check surfaces the error and does not start the interval")
    func failureDoesNotStampTheClock() async {
        let checker = checker(feed: MockReleaseFeed(.failure(.rateLimited)))
        await checker.check()
        #expect(checker.status == .failed(.rateLimited))
        // Stamping on failure would buy a full day of silence for a blip.
        #expect(checker.lastCheckedAt == nil)
        #expect(checker.isDue())
    }

    @Test("skipping a version silences it until something newer appears")
    func skipSilencesOneVersion() async {
        let store = defaults()
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"), defaults: store)
        await checker.check()
        checker.skip(AppVersion("1.1.0")!)
        #expect(checker.status == .upToDate)

        await checker.check()
        #expect(checker.status == .upToDate)

        // A newer release supersedes the skip.
        let later = self.checker(feed: MockReleaseFeed(version: "1.2.0"), defaults: store)
        #expect(later.skippedVersion == AppVersion("1.1.0"))
        await later.check()
        #expect(later.status.availableRelease?.version == AppVersion("1.2.0"))
        #expect(later.skippedVersion == nil)
    }

    @Test("a forced check ignores a skip")
    func forceClearsSkip() async {
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"))
        await checker.check()
        checker.skip(AppVersion("1.1.0")!)
        #expect(checker.status == .upToDate)

        await checker.check(force: true)
        #expect(checker.status.availableRelease?.version == AppVersion("1.1.0"))
    }

    @Test("checks only once per interval")
    func honoursInterval() async {
        let now = Date()
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"), interval: 3600)
        #expect(checker.isDue(now: now))

        await checker.check(now: now)
        #expect(checker.isDue(now: now.addingTimeInterval(1800)) == false)
        #expect(checker.isDue(now: now.addingTimeInterval(3600)))
    }

    @Test("a clock that moved backwards does not silence the check")
    func toleratesBackwardsClock() async {
        let now = Date()
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"))
        await checker.check(now: now)
        // Same reason AppState.tick never trusts a sleep duration.
        #expect(checker.isDue(now: now.addingTimeInterval(-90_000)))
    }

    @Test("automatic checking can be turned off without disabling manual ones")
    func automaticToggle() async {
        let checker = checker(feed: MockReleaseFeed(version: "1.1.0"))
        checker.automaticallyChecks = false
        #expect(checker.isDue() == false)

        await checker.checkIfDue()
        #expect(checker.status == .idle)

        await checker.check()
        #expect(checker.status.availableRelease != nil)
    }

    @Test("the interval and the skip survive a relaunch")
    func persistsAcrossLaunches() async {
        let store = defaults()
        let first = checker(feed: MockReleaseFeed(version: "1.1.0"), defaults: store)
        first.automaticallyChecks = false
        await first.check()
        first.skip(AppVersion("1.1.0")!)

        let second = checker(feed: MockReleaseFeed(version: "1.1.0"), defaults: store)
        #expect(second.automaticallyChecks == false)
        #expect(second.skippedVersion == AppVersion("1.1.0"))
        #expect(second.lastCheckedAt != nil)
    }
}
