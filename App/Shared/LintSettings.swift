import SwiftUI

/// App-wide Markdown warning toggle. The editor's linter is useful for unclosed fences
/// and broken headings, and noisy on ordinary prose (trailing spaces, a missing final
/// newline). Persisted so a reader can hide the bar without losing the feature.
final class LintSettings: ObservableObject {
    static let shared = LintSettings()

    private static let key = "leaflight.lintEnabled"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        }
    }

    func toggle() { isEnabled.toggle() }
}
