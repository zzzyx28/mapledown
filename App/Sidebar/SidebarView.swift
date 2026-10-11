import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarkdownEditorKit

/// Bumped whenever the watched folder changes on disk so the tree re-reads.
/// Both the root list and every expanded `FileRow` observe it. The change can come
/// from this tab, another tab, or an external app — the FSEvents watcher fires
/// regardless, which is what keeps sidebars across tabs synced to the filesystem.
final class FileTreeModel: ObservableObject {
    @Published var version = 0
    private lazy var watcher = DirectoryWatcher { [weak self] in self?.reload() }

    func reload() { version &+= 1 }

    /// Points the filesystem watcher at `url` (nil stops watching). The watcher
    /// no-ops when already on that path, so this is safe to call on every update.
    func watch(_ url: URL?) {
        if let url { watcher.start(url: url) } else { watcher.stop() }
    }
}

/// Drives keyboard control of the sidebar: which row is selected, which (if any)
/// is being renamed inline, and a pulse to pull keyboard focus into the list
/// (⌘⇧E). Mirrors the `FindController` pattern so the menu command can reach it.
final class SidebarController: ObservableObject {
    @Published var selection: URL?
    @Published var renamingURL: URL?
    @Published var renameText = ""
    /// Bumped to move keyboard focus into the list (⌘⇧E, or after a rename commits).
    @Published var focusPulse = 0
    /// Set by the key monitor (Space / ⌘↓) to ask SwiftUI to open a file.
    /// `focusDetail` distinguishes ⌘↓ (move focus to the file view) from Space
    /// (preview, keep focus in the sidebar). `token` makes a repeat
    /// of the same request still fire `onChange`.
    @Published var openRequest: OpenRequest?
    /// The List's backing outline view, captured by the keyboard bridge so the key
    /// monitor can tell whether *this* tab's sidebar is the first responder.
    weak var outlineView: NSView?

    struct OpenRequest: Equatable { let url: URL; let focusDetail: Bool; let token: Int }
    private var openToken = 0

    func focus() { focusPulse &+= 1 }
    func requestOpen(_ url: URL, focusDetail: Bool) {
        openToken &+= 1
        openRequest = OpenRequest(url: url, focusDetail: focusDetail, token: openToken)
    }
    func beginRename(_ url: URL) { selection = url; renamingURL = url }
    func endRename() { renamingURL = nil; focus() }

    /// Snapshots the sidebar scroll position so the tab an open switches to can restore it
    /// (a fresh tab's sidebar otherwise renders at the top). Call right before opening.
    func captureScroll(root: URL?) { SidebarScroll.capture(outline: outlineView, root: root) }
}

struct SidebarView: View {
    let rootURL: URL?
    let currentFile: URL?
    let outlineText: String?
    let outlineSync: ScrollSync?
    let onOutlineJump: (Int) -> Void
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var sidebar: SidebarController
    @ObservedObject var detailFocus: DetailFocusController
    /// Opens a chosen Markdown file through the document controller. Root-parking
    /// around the call stays in this view.
    let openFile: (URL) -> Void
    /// Show the small New File button in the section header. ContentView hides it (it has a
    /// full-size New File toolbar button); the folder-browser window keeps it.
    var showsNewFile = true
    /// Files stay visible. The outline is a pane under them, not a mode that replaces them.
    @AppStorage("sidebarShowsOutline") private var showsOutline = true

    init(rootURL: URL?, currentFile: URL?, outlineText: String? = nil,
         outlineSync: ScrollSync? = nil, onOutlineJump: @escaping (Int) -> Void = { _ in },
         tree: FileTreeModel, sidebar: SidebarController,
         detailFocus: DetailFocusController, openFile: @escaping (URL) -> Void,
         showsNewFile: Bool = true) {
        self.rootURL = rootURL
        self.currentFile = currentFile
        self.outlineText = outlineText
        self.outlineSync = outlineSync
        self.onOutlineJump = onOutlineJump
        self.tree = tree
        self.sidebar = sidebar
        self.detailFocus = detailFocus
        self.openFile = openFile
        self.showsNewFile = showsNewFile
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let rootURL {
                    if showsOutline, let outlineText, let outlineSync {
                        VSplitView {
                            fileBrowser(rootURL)
                                .frame(minHeight: 120)
                            OutlineBrowser(text: outlineText, sync: outlineSync, onJump: onOutlineJump)
                                .frame(minHeight: 120)
                        }
                    } else {
                        fileBrowser(rootURL)
                    }
                } else {
                    ContentUnavailableView("No Folder", systemImage: "folder",
                        description: Text("Open a Markdown file to browse its folder."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if outlineText != nil {
                Divider()
                HStack {
                    Button { showsOutline.toggle() } label: {
                        Label("Outline", systemImage: "list.bullet.indent")
                            .font(.caption)
                            .foregroundStyle(showsOutline ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showsOutline ? "Hide document outline" : "Show document outline")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 180)
        .onAppear {
            tree.watch(rootURL)
            if sidebar.selection == nil { sidebar.selection = currentFile }
        }
        .onChange(of: rootURL) { _, new in tree.watch(new) }
    }

    /// The folder tree. Kept separate so the outline pane can sit under it without
    /// taking over the sidebar's keyboard bridge.
    @ViewBuilder private func fileBrowser(_ rootURL: URL) -> some View {
        List(selection: $sidebar.selection) {
            Section {
                ForEach(FileEntry.children(of: rootURL)) { entry in
                    FileRow(entry: entry, root: rootURL, currentFile: currentFile,
                            tree: tree, sidebar: sidebar,
                            activateFile: { activate($0, focusDetail: true) })
                }
            } header: {
                HStack {
                    Text(rootURL.lastPathComponent.removingPercentEncoding ?? rootURL.lastPathComponent)
                    if showsNewFile {
                        Spacer()
                        Button { newFile(in: rootURL) } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .help("New Markdown File  (⌘N)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // AppKit bridge: `.focused()` on a List doesn't make its NSOutlineView
        // first responder on macOS, so ⌘⇧E wouldn't enable arrow keys. This
        // grabs first responder on `focusPulse` (native ↑↓←→) and runs a key
        // monitor for the custom space / ⌘↓ / Return actions the outline view
        // would otherwise swallow.
        .background(SidebarKeyboardBridge(controller: sidebar, pulse: sidebar.focusPulse))
        .background(SidebarScrollRestorer(root: rootURL))
        .onChange(of: sidebar.focusPulse) { _, _ in
            if sidebar.selection == nil {
                sidebar.selection = currentFile ?? FileEntry.children(of: rootURL).first?.url
            }
        }
        .onChange(of: sidebar.openRequest) { _, req in
            guard let req else { return }
            sidebar.openRequest = nil
            activate(req.url, focusDetail: req.focusDetail)
        }
        // Keep the visible selection on the file this tab is showing, so
        // switching tabs never leaves a stale row highlighted from another tab.
        .onChange(of: currentFile) { _, f in sidebar.selection = f }
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        tree.reload()
        sidebar.captureScroll(root: rootURL)
        openFile(url)
    }

    /// Opens / re-focuses for a sidebar row. `focusDetail` distinguishes ⌘↓ and click
    /// (move focus to the file view) from Space (preview — keep focus in the sidebar).
    /// Folders are left to the list's native ←/→ expand.
    private func activate(_ url: URL, focusDetail: Bool) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard !isDir.boolValue else { return }

        // Already the open file -> don't reopen, just move focus where asked.
        if currentFile?.standardizedFileURL == url.standardizedFileURL {
            if focusDetail { detailFocus.focus() } else { sidebar.focus() }
            return
        }
        // Space previews Markdown only. Opening another file type requires an
        // explicit double-click or ⌘↓, so a selection change cannot launch Finder
        // or an unrelated app.
        guard FileEntry.isMarkdown(url) else {
            if focusDetail { NSWorkspace.shared.open(url) }
            return
        }
        // Opening may switch to another tab; park the focus intent for the destination
        // ContentView to claim once it shows this file.
        OpenFocusRouter.shared.pending = PendingFocus(url: url, target: focusDetail ? .detail : .sidebar)
        // Park this sidebar's root so a file in a subfolder tabs into THIS window and keeps
        // the same tree, instead of re-rooting at the subfolder / opening a new window.
        if let rootURL { OpenRootRouter.shared.roots[url.standardizedFileURL] = rootURL }
        sidebar.captureScroll(root: rootURL)
        if OpenDocumentRouter.showExisting(url) { return }
        openFile(url)
    }
}

/// Headings for the current document, in the sidebar pane and the inspector.
/// The current section is bold in both View and Edit (both publish through `sync.line`).
/// The list reveals that row only when it has scrolled out of sight — a `ScrollViewReader`
/// `scrollTo` on this macOS `List` jumps the outline (and sometimes the split view) on
/// every section change, including the click that asked for the jump.
struct OutlineBrowser: View {
    let text: String
    @ObservedObject var sync: ScrollSync
    let onJump: (Int) -> Void

    var body: some View {
        let headings = Outline.headings(in: text)
        let currentLine = headings.last(where: { $0.line <= sync.line })?.line
        Group {
            if headings.isEmpty {
                VStack {
                    Text("No headings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(headings, id: \.line) { heading in
                        OutlineEntry(level: heading.level,
                                     title: heading.title,
                                     isCurrent: heading.line == currentLine) {
                            onJump(heading.line)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct OutlineEntry: View {
    let level: Int
    let title: String
    let isCurrent: Bool
    let action: () -> Void

    private var size: CGFloat { level >= 4 ? 11 : 13 }

    var body: some View {
        Button(action: action) {
            // Two different text views, not `.fontWeight` on one. A sidebar `List` keeps
            // the first weight it rendered, so the current section never went bold as you
            // scrolled in View or Edit.
            Group {
                if isCurrent {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(Color.primary)
                } else {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: size, weight: .regular))
                        .foregroundStyle(Color.secondary)
                }
            }
            .id(isCurrent)
            .lineLimit(1)
            .padding(.leading, CGFloat(level - 1) * 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(OutlineFollowAnchor(isCurrent: isCurrent).allowsHitTesting(false))
    }
}

/// Scrolls the current outline row into view once, and only if it isn't already visible.
/// Uses the row's own scroll view, so a section change doesn't jump the window.
private struct OutlineFollowAnchor: NSViewRepresentable {
    var isCurrent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let becameCurrent = isCurrent && !context.coordinator.wasCurrent
        context.coordinator.wasCurrent = isCurrent
        guard becameCurrent else { return }
        DispatchQueue.main.async {
            if view.window == nil {
                DispatchQueue.main.async { Self.revealIfNeeded(view) }
            } else {
                Self.revealIfNeeded(view)
            }
        }
    }

    final class Coordinator { var wasCurrent = false }

    private static func revealIfNeeded(_ view: NSView) {
        let target = sequence(first: view, next: { $0.superview }).first { $0 is NSTableRowView } ?? view
        guard let clip = target.enclosingScrollView?.contentView else { return }
        let rect = target.convert(target.bounds, to: clip)
        let visible = clip.bounds.insetBy(dx: 0, dy: 2)
        if visible.contains(CGPoint(x: rect.midX, y: rect.midY)) { return }
        target.scrollToVisible(target.bounds)
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let root: URL?
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var sidebar: SidebarController
    let activateFile: (URL) -> Void
    @ObservedObject private var expansion = SidebarExpansion.shared

    @State private var children: [FileEntry] = []
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { sidebar.renamingURL == entry.url }

    /// Disclosure state read from the shared store so it's one source of truth across tabs.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expansion.expanded.contains(entry.url) },
            set: { if $0 { expansion.expanded.insert(entry.url) } else { expansion.expanded.remove(entry.url) } }
        )
    }

    private func reloadChildrenIfExpanded() {
        children = expansion.expanded.contains(entry.url) ? FileEntry.children(of: entry.url) : []
    }

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(children) { FileRow(entry: $0, root: root, currentFile: currentFile, tree: tree, sidebar: sidebar, activateFile: activateFile) }
            } label: {
                if isRenaming {
                    renameField
                } else {
                    Label(entry.name, systemImage: "folder")
                        .lineLimit(1)
                }
            }
            .tag(entry.url)
            // Shared expansion -> load children when this folder becomes expanded (here or in
            // another tab), and on first appearance if it's already expanded.
            .onAppear { reloadChildrenIfExpanded() }
            .onChange(of: expansion.expanded) { _, _ in reloadChildrenIfExpanded() }
            .onChange(of: tree.version) { _, _ in reloadChildrenIfExpanded() }
            .contextMenu { rowMenu(newFileTarget: entry.url) }
        } else {
            Group {
                if isRenaming {
                    renameField
                } else if entry.isMarkdown {
                    fileLabel
                        .onTapGesture {
                            sidebar.selection = entry.url
                            activateFile(entry.url)
                        }
                        .help("Open Markdown")
                } else {
                    fileLabel
                        .onTapGesture {
                            sidebar.selection = entry.url
                            sidebar.focus()
                        }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(entry.url) }
                        .help("Double-click to open in the default app")
                }
            }
            .tag(entry.url)
            .fontWeight(isCurrent ? .semibold : .regular)
            .contextMenu { rowMenu(newFileTarget: entry.url.deletingLastPathComponent()) }
        }
    }

    private var fileLabel: some View {
        Label {
            Text(entry.name).lineLimit(1)
        } icon: {
            Image(systemName: entry.isMarkdown ? "doc.text" : "doc")
                .foregroundStyle(entry.isMarkdown ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Inline editor shown in place of the row label while renaming.
    private var renameField: some View {
        TextField("", text: $sidebar.renameText)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onAppear { sidebar.renameText = entry.name; renameFocused = true }
            .onSubmit { commitRename() }
            .onExitCommand { sidebar.endRename() }
    }

    /// `newFileTarget` is the folder a "New File" here lands in: the directory itself
    /// for a folder row, the containing folder for a file row.
    @ViewBuilder private func rowMenu(newFileTarget: URL) -> some View {
        Button("New File") { newFile(in: newFileTarget) }
        Button("Rename") { sidebar.beginRename(entry.url) }
        if !entry.isDirectory && !entry.isMarkdown {
            Button("Open in Default App") { NSWorkspace.shared.open(entry.url) }
        }
        if !entry.isDirectory && entry.isMarkdown {
            Button("Copy") { copyFileToPasteboard(entry.url) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            FileEntry.trash(entry.url)
            tree.reload()
        }
    }

    /// Places the file URL on the general pasteboard so Finder can paste the file item,
    /// matching Finder's ⌘C behavior rather than copying Markdown text.
    private func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private var isCurrent: Bool {
        guard let currentFile else { return false }
        return entry.url.standardizedFileURL == currentFile.standardizedFileURL
    }

    private func commitRename() {
        if let new = FileEntry.rename(entry.url, to: sidebar.renameText) {
            if sidebar.selection == entry.url { sidebar.selection = new }
            tree.reload()
        }
        sidebar.endRename()
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        if entry.isDirectory { expansion.expanded.insert(entry.url) }
        tree.reload()
        sidebar.selection = url
        activateFile(url)
    }

}

struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: URL { url }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn", "mkdn"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    var isMarkdown: Bool { FileEntry.isMarkdown(url) }

    static func children(of dir: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        return items.compactMap { url -> FileEntry? in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let isDir = vals?.isDirectory ?? false
            let name = vals?.name ?? url.lastPathComponent
            return FileEntry(url: url, name: name, isDirectory: isDir)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Creates a unique `Untitled[ N].md` in `dir` and returns it (nil on write failure).
    static func makeNewFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("Untitled.md")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Untitled \(i).md")
            i += 1
        }
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Renames `url` to `newName` within the same folder. Returns the new URL, or nil
    /// if the name is empty, contains a path separator, or collides with an existing item.
    ///
    /// Uses a *coordinated* move (NSFileCoordinator + `didMoveTo:`) rather than a bare
    /// `FileManager.moveItem`, so that if the file is open in a tab its NSDocument (a
    /// file presenter) follows to the new URL instead of dangling on the old path.
    static func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var moved = false
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: dest, options: .forReplacing,
                               error: &coordError) { src, dst in
            coordinator.item(at: src, willMoveTo: dst)
            do {
                try FileManager.default.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)   // notifies the open document
                moved = true
            } catch {
                moved = false
            }
        }
        return moved ? dest : nil
    }

    /// Moves `url` to the Trash (reversible, so no confirmation needed).
    static func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Bridges the SwiftUI sidebar to AppKit for keyboard control, working around two
/// macOS limitations of `List`:
///   1. `.focused()` won't make the backing `NSOutlineView` first responder, so
///      ⌘⇧E couldn't enable arrow-key navigation — `grabFocus()` does it directly.
///   2. A focused outline view swallows Space/Return, so SwiftUI `.onKeyPress`
///      never sees them — a local key monitor intercepts Space / ⌘↓ / Return and
///      routes them to the controller (open / begin-rename) before the view reacts.
/// The monitor is scoped to this tab via `controller.outlineView`, so other tabs'
/// monitors ignore the event. Mouse clicks are handled by each row's own URL;
/// inferring a URL from the selected row in a global event monitor is racy.
private struct SidebarKeyboardBridge: NSViewRepresentable {
    let controller: SidebarController
    let pulse: Int

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.lastPulse = pulse
        let v = NSView()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard pulse != context.coordinator.lastPulse else { return }
        context.coordinator.lastPulse = pulse
        context.coordinator.grabFocus(near: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private let controller: SidebarController
        private var monitor: Any?
        var lastPulse = -1

        init(controller: SidebarController) {
            self.controller = controller
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // `handle` returns nil to SWALLOW (e.g. ⌘↓ opens the file and must NOT
                // also let the outline view move the selection down). Don't fold that nil
                // into `?? event` — that would re-dispatch the swallowed key. Only fall
                // back to passing the event through when `self` is gone.
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Makes this tab's file-tree outline view first responder (deferred so a
        /// just-revealed sidebar has laid out). Captures the view so the monitor
        /// can scope to it. Retries once if the view isn't built yet.
        func grabFocus(near anchor: NSView, retry: Bool = true) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = anchor.window else { return }
                if let outline = Self.fileTable(near: anchor) {
                    self.controller.outlineView = outline
                    window.makeFirstResponder(outline)
                } else if retry {
                    self.grabFocus(near: anchor, retry: false)
                }
            }
        }

        /// The file tree, not the document-outline list under it or the inspector.
        /// Prefers the table whose frame contains the bridge; otherwise the nearest one.
        private static func fileTable(near anchor: NSView?) -> NSTableView? {
            guard let anchor, let root = anchor.window?.contentView else { return nil }
            // SwiftUI places this background view behind the file List. Its
            // bottom-left origin can sit next to the outline pane's table;
            // sample the center so a split sidebar never focuses the wrong List.
            let point = anchor.convert(
                CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
            var containing: (table: NSTableView, area: CGFloat)?
            var nearest: (table: NSTableView, distance: CGFloat)?
            func walk(_ view: NSView) {
                if let table = view as? NSTableView {
                    let rect = table.convert(table.bounds, to: nil)
                    if rect.insetBy(dx: -8, dy: -8).contains(point) {
                        let area = rect.width * rect.height
                        if containing == nil || area < containing!.area { containing = (table, area) }
                    }
                    let distance = hypot(rect.midX - point.x, rect.midY - point.y)
                    if nearest == nil || distance < nearest!.distance { nearest = (table, distance) }
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(root)
            return containing?.table ?? nearest?.table
        }

        /// Intercepts the custom keys only while this sidebar's outline view is the
        /// first responder and no inline rename is active. Returns nil to swallow.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let outline = controller.outlineView,
                  event.window?.firstResponder === outline,
                  controller.renamingURL == nil,
                  let sel = controller.selection else { return event }

            switch event.keyCode {
            case 36, 76:                     // Return / Enter -> rename
                controller.beginRename(sel)
                return nil
            case 49:                         // Space -> preview (keep focus in sidebar)
                controller.requestOpen(sel, focusDetail: false)
                return nil
            case 125 where event.modifierFlags.contains(.command):  // ⌘↓ -> open + focus file view
                controller.requestOpen(sel, focusDetail: true)
                return nil
            default:
                return event
            }
        }

    }
}
