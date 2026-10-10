import SwiftUI
import AppKit

/// Receives folder-open events the document machinery can't (a folder isn't a
/// `FileDocument`): Finder "Open With", `open -a MapleDown <dir>`, drag-onto-icon. Folders
/// get a sidebar-only browser window; everything else is handed to the normal document
/// pipeline so plain `.md` opening keeps working unchanged.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard WelcomeWindowController.isArmed,
                  let window = note.object as? NSWindow,
                  !WelcomeWindowController.isWelcome(window),
                  !(window is NSPanel) else { return }
            WelcomeWindowController.close()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  !WelcomeWindowController.isWelcome(window),
                  !(window is NSPanel),
                  !WelcomeWindowController.isQuitting else { return }
            DispatchQueue.main.async {
                let documentVisible = NSDocumentController.shared.documents.contains { doc in
                    doc.windowControllers.contains { $0.window?.isVisible == true }
                }
                let otherVisible = NSApp.windows.contains { candidate in
                    candidate.isVisible && !(candidate is NSPanel)
                        && !WelcomeWindowController.isWelcome(candidate)
                }
                if !documentVisible && !otherVisible {
                    WelcomeWindowController.show()
                }
            }
        }
        DispatchQueue.main.async {
            WelcomeWindowController.shared.showIfLaunchingIdle()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeWindowController.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WelcomeWindowController.isQuitting = true
        let documents = NSDocumentController.shared
        guard documents.hasEditedDocuments else { return .terminateNow }
        // NSDocumentController no longer implements applicationShouldTerminate(_:).
        // Review unsaved files ourselves, then reply once the user decides.
        documents.reviewUnsavedDocuments(
            withAlertTitle: nil,
            cancellable: true,
            delegate: self,
            didReviewAllSelector: #selector(AppDelegate.documentController(_:didReviewAll:contextInfo:)),
            contextInfo: nil)
        return .terminateLater
    }

    @objc func documentController(
        _ documentController: NSDocumentController,
        didReviewAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        if !didReviewAll {
            WelcomeWindowController.isQuitting = false
        }
        NSApp.reply(toApplicationShouldTerminate: didReviewAll)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WelcomeWindowController.noteOpeningURLs()
        for url in urls {
            if isDirectory(url) {
                FolderBrowserWindowController.show(folder: url)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// One browser window per folder (reused if the same folder is reopened). Built as a
/// plain AppKit window hosting SwiftUI — a fileless window can't be a DocumentGroup scene,
/// and an AppKit window is deterministic even at cold launch.
final class FolderBrowserWindowController: NSWindowController {
    private static var open: [URL: FolderBrowserWindowController] = [:]

    static func show(folder: URL) {
        let key = folder.standardizedFileURL
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = folder.lastPathComponent
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: FolderBrowser(folder: folder))

        let controller = FolderBrowserWindowController(window: win)
        open[key] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: win, queue: .main) { _ in open[key] = nil }
        win.makeKeyAndOrderFront(nil)
    }
}

/// Sidebar browsing `folder`, empty detail until a file is picked. Reuses `SidebarView`;
/// chosen markdown opens via `NSDocumentController` (its own document window/tab, rooted
/// at this folder by `SidebarView`'s existing root-parking).
private struct FolderBrowser: View {
    let folder: URL
    @StateObject private var tree = FileTreeModel()
    @StateObject private var sidebar = SidebarController()
    @StateObject private var detailFocus = DetailFocusController()

    var body: some View {
        NavigationSplitView {
            SidebarView(rootURL: folder, currentFile: nil,
                        tree: tree, sidebar: sidebar, detailFocus: detailFocus,
                        openFile: { url in
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                        })
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            ContentUnavailableView("No File Selected", systemImage: "doc.text",
                description: Text("Select a Markdown file to open it."))
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
