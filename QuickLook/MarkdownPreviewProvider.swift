import Cocoa
import Quartz
import UniformTypeIdentifiers
import os

/// Data-based Quick Look preview provider for Markdown (macOS 12+ via
/// `QLIsDataBasedPreview` in Info.plist). Renders to static HTML in-process with
/// JavaScriptCore and hands it to Quick Look's own HTML renderer — no WKWebView /
/// WebContent (which cannot spawn in the QL preview sandbox).
class MarkdownPreviewProvider: NSViewController, QLPreviewingController {
    private static let log = Logger(subsystem: "io.github.zzzyx28.mapledown.ql", category: "provider")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        Self.log.notice("providePreview: \(url.lastPathComponent, privacy: .public)")
        let bundle = Bundle(for: Self.self)

        return QLPreviewReply(dataOfContentType: .html,
                              contentSize: CGSize(width: 1000, height: 800)) { reply in
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent

            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let dir = url.deletingLastPathComponent()
            let dirAccessed = dir.startAccessingSecurityScopedResource()
            defer { if dirAccessed { dir.stopAccessingSecurityScopedResource() } }

            let text: String
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
            } else {
                text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            }
            // Same local-image treatment as the reader, so a Finder preview matches the document.
            // Cap each file so a huge asset can't blow the static HTML reply.
            let markdown = LocalImageEmbedder.embed(text) { path in
                guard let fileURL = LocalImageEmbedder.resolve(path, relativeTo: dir) else { return nil }
                return LocalImageEmbedder.dataURI(for: fileURL, maxBytes: 8_000_000)
            }
            let html = JSRenderer.htmlDocument(markdown: markdown, bundle: bundle)
            Self.log.notice("html bytes=\(html.utf8.count, privacy: .public)")
            return Data(html.utf8)
        }
    }
}
