import Foundation

/// Locates the bundled offline web renderer assets. Shared by app + Quick Look extension.
enum WebResources {
    static func indexURL(in bundle: Bundle = .main) -> URL? {
        directory(in: bundle)?.appendingPathComponent("index.html")
    }
    static func directory(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "web", withExtension: nil)
    }
    /// JS-safe JSON string literal for `markdown` (for evaluateJavaScript injection).
    static func jsLiteral(_ markdown: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: markdown, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "\"\"" }
        return s
    }
}
