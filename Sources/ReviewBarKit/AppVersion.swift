import Foundation

/// A released version, parsed from a git tag (`v0.2.0`) or a bundle's
/// `CFBundleShortVersionString` (`0.2.0`) — the two must compare equal, which
/// is why the leading `v` is stripped rather than being part of the value.
///
/// Ordering is numeric per component, not lexicographic: `0.10.0` is newer than
/// `0.9.0`, which string comparison gets backwards. Missing components read as
/// zero, so `1.2` and `1.2.0` are the same version.
public struct AppVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    /// Numeric components, most significant first. Never empty.
    public let components: [Int]
    /// Anything after a `-`: `1.0.0-beta.2` has `"beta.2"`. A prerelease sorts
    /// *before* the same numbers without one, matching semver — otherwise
    /// shipping 1.0.0 after 1.0.0-beta.2 would look like a downgrade.
    public let prerelease: String?

    public var isPrerelease: Bool { prerelease != nil }

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        // Build metadata (`+abc`) is explicitly ignored when comparing.
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }

        let prereleaseText: String?
        if let dash = text.firstIndex(of: "-") {
            prereleaseText = String(text[text.index(after: dash)...])
            text = String(text[text.startIndex..<dash])
        } else {
            prereleaseText = nil
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
        prerelease = prereleaseText.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The running app's version, or nil when there is no bundle carrying one —
    /// which is how `swift run` launches us. Callers treat nil as "updates
    /// can't be reasoned about" rather than as version zero, so a development
    /// build never announces that it is out of date.
    public static func current(in bundle: Bundle = .main) -> AppVersion? {
        guard let string = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppVersion(string)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?): return false      // 1.0.0 is newer than 1.0.0-beta
        case (_?, nil): return true
        case (let left?, let right?): return left < right
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        let numbers = components.map(String.init).joined(separator: ".")
        return prerelease.map { "\(numbers)-\($0)" } ?? numbers
    }
}
