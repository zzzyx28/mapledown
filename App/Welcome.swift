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

/// One welcome window for the process: the SwiftUI "welcome" scene. Document
/// windows take over once the reader picks a file; closing the last document
/// brings this back. Closing the welcome window itself leaves the app running.
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    static var isArmed = false
    static var isQuitting = false
    private var openingURLs = false
    private var openWelcome: (() -> Void)?

    static func bindOpen(_ action: @escaping () -> Void) {
        shared.openWelcome = action
    }

    static func show() { shared.present() }
    static func close() {
        for window in NSApp.windows where isWelcome(window) { window.orderOut(nil) }
    }
    static func isWelcome(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "mapledown.welcome" { return true }
        guard !(window is NSPanel) else { return false }
        // The tagger runs after the window exists. The launch scene is 440pt wide
        // and titled MapleDown; document windows are larger and titled with a file.
        return window.title == "MapleDown" && abs(window.frame.width - 440) < 24
    }
    static func noteOpeningURLs() {
        shared.openingURLs = true
    }

    /// Dock reopen can restore the SwiftUI scene and also ask us to show a window.
    /// Keep the one the user is looking at and hide any other welcome.
    static func collapseDuplicates(preferring key: NSWindow? = nil) {
        let visible = NSApp.windows.filter { $0.isVisible && isWelcome($0) }
        guard visible.count > 1 else { return }
        let primary = visible.first { $0 === key } ?? visible[0]
        for extra in visible where extra !== primary { extra.orderOut(nil) }
    }

    func showAfterOpenFailure() {
        openingURLs = false
        showIfLaunchingIdle()
    }

    private init() {}

    private func present() {
        let welcomes = NSApp.windows.filter { Self.isWelcome($0) }
        if let primary = welcomes.first(where: { $0.identifier?.rawValue == "mapledown.welcome" }) ?? welcomes.first {
            for extra in welcomes where extra !== primary { extra.orderOut(nil) }
            if primary.isMiniaturized { primary.deminiaturize(nil) }
            primary.makeKeyAndOrderFront(nil)
            NSApp.activate()
            Self.scheduleCollapse(preferring: primary)
            return
        }
        openWelcome?()
        NSApp.activate()
        Self.scheduleCollapse()
    }

    private static func scheduleCollapse(preferring key: NSWindow? = nil) {
        DispatchQueue.main.async {
            collapseDuplicates(preferring: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                collapseDuplicates(preferring: key)
            }
        }
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
            $0.isVisible && !Self.isWelcome($0) && !($0 is NSPanel)
        }
        let welcomeVisible = NSApp.windows.contains { $0.isVisible && Self.isWelcome($0) }
        if NSDocumentController.shared.documents.isEmpty && !otherWindowVisible && !welcomeVisible {
            present()
        }
        Self.isArmed = true
    }
}

/// Captures SwiftUI's openWindow action so a Dock click can reopen the same
/// welcome scene instead of allocating a second window.
struct WelcomeOpenBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                WelcomeWindowController.bindOpen { open(id: "welcome") }
            }
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
