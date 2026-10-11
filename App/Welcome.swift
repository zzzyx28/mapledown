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
    static func close() {
        for window in NSApp.windows where isWelcome(window) { window.orderOut(nil) }
    }
    static func isWelcome(_ window: NSWindow) -> Bool {
        window === shared.window || window.identifier?.rawValue == "mapledown.welcome"
    }
    static func noteOpeningURLs() {
        shared.openingURLs = true
    }

    func showAfterOpenFailure() {
        openingURLs = false
        showIfLaunchingIdle()
    }

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
        // The SwiftUI launch scene is already a welcome window. Focusing that
        // one avoids stacking a second, identical AppKit welcome beside it.
        if let existing = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && Self.isWelcome($0)
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func newMarkdown() {
        NSDocumentController.shared.newDocument(nil)
        Self.close()
    }

    func openExisting() {
        NSDocumentController.shared.openDocument(nil)
        let opened = NSDocumentController.shared.documents.contains { $0.fileURL != nil }
        if opened { Self.close() }
    }

    /// Called after AppKit's empty-launch request and after launch settles. A blank
    /// auto-created untitled document is closed; a restored unsaved one is left alone.
    func showIfLaunchingIdle() {
        guard !openingURLs else {
            Self.isArmed = true
            return
        }
        for doc in NSDocumentController.shared.documents where doc.fileURL == nil && !doc.isDocumentEdited {
            doc.close()
        }
        let otherWindowVisible = NSApp.windows.contains {
            $0.isVisible && !Self.isWelcome($0)
        }
        let welcomeVisible = NSApp.windows.contains { $0.isVisible && Self.isWelcome($0) }
        // An untagged SwiftUI welcome still counts as another visible window, so
        // this does not open the AppKit copy while the launch scene is on screen.
        if NSDocumentController.shared.documents.isEmpty && !otherWindowVisible && !welcomeVisible {
            orderFront()
        }
        Self.isArmed = true
    }
}

/// Marks the SwiftUI launch scene so the AppDelegate can treat it exactly like
/// the AppKit fallback Welcome window when a document becomes active.
struct WelcomeWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TagView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("mapledown.welcome")
        }
    }
}
