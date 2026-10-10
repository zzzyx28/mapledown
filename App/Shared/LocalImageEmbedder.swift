import Foundation

/// Rewrites local Markdown and HTML images to data URIs so a sandboxed renderer
/// (the app's WKWebView, and Quick Look's static HTML) can show files that sit
/// next to the document. Remote, `data:`, and `file:` URLs are left untouched.
enum LocalImageEmbedder {
    static func resolve(_ path: String, relativeTo dir: URL) -> URL? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !p.hasPrefix("http"), !p.hasPrefix("data:"), !p.hasPrefix("file:")
        else { return nil }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
    }

    /// `nil` when the file is missing, unreadable, or larger than `maxBytes`.
    static func dataURI(for fileURL: URL, maxBytes: Int = .max) -> String? {
        let key = fileURL.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: key),
              let size = attrs[.size] as? Int,
              size <= maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let ext = fileURL.pathExtension.lowercased()
        let mime = ["jpeg": "image/jpeg", "jpg": "image/jpeg", "gif": "image/gif",
                    "svg": "image/svg+xml", "webp": "image/webp"][ext] ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// `uriForPath` receives the raw path from the markup and returns a data URI, or nil to
    /// keep the original reference (the rendered page then shows its missing-image placeholder).
    static func embed(_ markdown: String, uriForPath: (String) -> String?) -> String {
        var result = markdown
        if let re = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
            let ns = result as NSString
            for match in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let path = ns.substring(with: match.range(at: 2))
                guard let uri = uriForPath(path) else { continue }
                let alt = ns.substring(with: match.range(at: 1))
                result.replaceSubrange(Range(match.range(at: 0), in: result)!, with: "![\(alt)](\(uri))")
            }
        }
        if let re = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*(["'])(.*?)\1"#,
                                             options: [.caseInsensitive]) {
            let ns = result as NSString
            for match in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let path = ns.substring(with: match.range(at: 2))
                guard let uri = uriForPath(path) else { continue }
                result.replaceSubrange(Range(match.range(at: 2), in: result)!, with: uri)
            }
        }
        return result
    }
}
