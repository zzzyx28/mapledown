import SwiftUI
import AppKit

/// Launch window when nothing is open. Two actions, and nothing else competing
/// with them: start a new Markdown document, or open one that already exists.
struct WelcomeView: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityLabel("MapleDown")
            Text("MapleDown")
                .font(.system(size: 28, weight: .semibold))
            VStack(spacing: 10) {
                Button(action: onNew) {
                    Text("新建 Markdown")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(action: onOpen) {
                    Text("打开已有 Markdown")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .frame(width: 240)
        }
        .padding(.horizontal, 48)
        .padding(.top, 56)
        .padding(.bottom, 40)
        .frame(width: 440, height: 400)
    }
}

/// One welcome window for the process. Document windows take over once the reader
/// picks a file; closing the last document brings this back. Closing the welcome
/// window itself leaves the app running (a dock click shows it again).
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()
    static var isArmed = false
    static var isQuitting = false
    private var openingURLs = false

    static func show() { shared.orderFront() }
    static func close() { shared.window?.orderOut(nil) }
    static func isWelcome(_ window: NSWindow) -> Bool { window === shared.window }
    static func noteOpeningURLs() { shared.openingURLs = true }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "MapleDown"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView(
            onNew: { WelcomeWindowController.shared.newMarkdown() },
            onOpen: { WelcomeWindowController.shared.openExisting() }
        ))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func orderFront() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func newMarkdown() {
        NSDocumentController.shared.newDocument(nil)
        window?.orderOut(nil)
    }

    private func openExisting() {
        NSDocumentController.shared.openDocument(nil)
        let opened = NSDocumentController.shared.documents.contains { $0.fileURL != nil }
        if opened { window?.orderOut(nil) }
    }

    /// Called once the app is up. A blank auto-created untitled document is closed
    /// so the welcome window is what you see. A restored unsaved document
    /// (`isDocumentEdited`) is left alone.
    func showIfLaunchingIdle() {
        guard !openingURLs else {
            Self.isArmed = true
            return
        }
        for doc in NSDocumentController.shared.documents where doc.fileURL == nil && !doc.isDocumentEdited {
            doc.close()
        }
        if NSDocumentController.shared.documents.isEmpty {
            orderFront()
        }
        Self.isArmed = true
    }
}
