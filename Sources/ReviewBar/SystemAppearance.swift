import AppKit
import ReviewBarKit

/// The macOS light/dark appearance, observed live. The review panel forces
/// `darkAqua` on itself, so nothing inside it can read the system scheme
/// through SwiftUI's environment — this asks `NSApp` instead.
@MainActor
@Observable
final class SystemAppearance {
    private(set) var isDark: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        isDark = Self.isDark(NSApp.effectiveAppearance)
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            let dark = Self.isDark(app.effectiveAppearance)
            Task { @MainActor [weak self] in self?.isDark = dark }
        }
    }

    /// Whether a card under the given theme renders with a light document.
    func rendersLight(_ appearance: CardAppearance) -> Bool {
        switch appearance {
        case .dark: false
        case .light: true
        case .system: !isDark
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
