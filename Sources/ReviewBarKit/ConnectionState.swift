import Foundation

/// App-level view of the AnkiConnect link.
public enum ConnectionState: Equatable, Sendable {
    case unknown
    case connected(apiVersion: Int)
    /// TCP-level failure: Anki not running, AnkiConnect missing, or Anki died.
    case unreachable
    case incompatibleVersion(Int)
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Anki may be closed or dead — the one state with a recovery action
    /// ("Open Anki") behind it.
    public var isUnreachable: Bool { self == .unreachable }

    public var statusText: String {
        switch self {
        case .unknown: "Checking…"
        case .connected: "Connected to Anki"
        case .unreachable: "Anki isn't available"
        case .incompatibleVersion(let v): "Unsupported AnkiConnect (version \(v))"
        case .error(let message): "Couldn't reach Anki: \(message)"
        }
    }

    /// Classify a thrown error into a connection state.
    public static func from(_ error: any Error) -> ConnectionState {
        switch error {
        case AnkiConnectError.unreachable: .unreachable
        case AnkiConnectError.incompatibleVersion(let v): .incompatibleVersion(v)
        case AnkiConnectError.api(let message): .error(message)
        case AnkiConnectError.malformedResponse: .error("Unexpected response")
        default: .error(error.localizedDescription)
        }
    }
}

/// Computes the menu-bar due count: top-level decks only, since Anki's
/// per-deck counts already include subdecks.
public enum DueCount {
    public static func topLevelDecks(from names: [String]) -> [String] {
        names.filter { !$0.contains("::") }
    }

    public static func total(from stats: [DeckStats]) -> Int {
        stats.reduce(0) { $0 + $1.dueTotal }
    }

    /// Restrict "Review Now" (and the due count feeding the badge and nudge
    /// gate) to the user's chosen top-level decks. An empty scope means all
    /// decks; a scope matching nothing — every chosen deck renamed or deleted —
    /// also falls back to all rather than silently counting and reviewing
    /// nothing forever.
    public static func scoped(_ topLevel: [String], to scope: Set<String>) -> [String] {
        guard !scope.isEmpty else { return topLevel }
        let selected = topLevel.filter { scope.contains($0) }
        return selected.isEmpty ? topLevel : selected
    }
}
