import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import MarkdownEditorKit

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        // The folder the sidebar browses for this tab. Normally the file's parent, but a
        // file opened from a subfolder inherits the source tab's root (parked in
        // OpenRootRouter), so it tabs into the same window and keeps the same tree.
        let inherited = fileURL.flatMap { OpenRootRouter.shared.roots[$0.standardizedFileURL] }
        _browsingRoot = State(initialValue: inherited ?? fileURL?.deletingLastPathComponent())
    }

    @State private var mode: EditorMode = .view
    @State private var browsingRoot: URL?
    @ObservedObject private var sidebarVis = SidebarVisibility.shared
    @StateObject private var find = FindController()
    // @State, NOT @StateObject: sync.line publishes on every scroll tick, and ContentView
    // must not re-render for that (only OutlineInspector observes it, for the current-
    // section highlight). ContentView merely *reads* sync.target() during mode switches.
    @State private var sync = ScrollSync()
    @StateObject private var tree = FileTreeModel()
    @StateObject private var sidebar = SidebarController()
    @StateObject private var detailFocus = DetailFocusController()
    @StateObject private var selection = SelectionController()
    @StateObject private var quickOpen = QuickOpenController()
    @StateObject private var fileSync = FileSync()
    @StateObject private var editCursor = EditCursorStore()
    @StateObject private var editBuffer = EditorBuffer()
    @ObservedObject private var fontScale = FontScale.shared
    @ObservedObject private var fullWidth = FullWidthMode.shared
    @ObservedObject private var outlineVis = OutlineVisibility.shared
    @ObservedObject private var lint = LintSettings.shared
    @StateObject private var viewerHandle = ViewerHandle()
    @State private var hoveredLink = ""
    // Outline-panel jump (A2): a bumped token carries the target source line to the active mode.
    @State private var outlineJumpToken = 0
    @State private var outlineJumpLine: Int?

    private var sidebarVisible: Binding<Bool> {
        Binding(
            get: { sidebarVis.columnVisibility != .detailOnly },
            set: { show in
                withAnimation(.easeInOut(duration: 0.25)) {
                    sidebarVis.columnVisibility = show ? .all : .detailOnly
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVis.columnVisibility) {
            SidebarView(rootURL: browsingRoot, currentFile: fileURL,
                        outlineText: document.text, outlineSync: sync,
                        onOutlineJump: jumpToOutline,
                        tree: tree, sidebar: sidebar, detailFocus: detailFocus,
                        openFile: { MarkdownDocumentOpener.open($0) },
                        showsNewFile: false)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            detail
                .toolbar { toolbarContent }
                .inspector(isPresented: $outlineVis.isVisible) {
                    OutlineBrowser(text: document.text, sync: sync, onJump: jumpToOutline)
                    .inspectorColumnWidth(min: 180, ideal: 220, max: 360)
                }
        }
        .sheet(isPresented: Binding(get: { quickOpen.isVisible },
                                    set: { if !$0 { quickOpen.hide() } })) {
            QuickOpenPalette(controller: quickOpen, onOpen: openFromQuickOpen)
        }
        .focusedSceneValue(\.editorMode, $mode)
        .focusedSceneValue(\.sidebarVisible, sidebarVisible)
        .focusedSceneValue(\.findController, find)
        .focusedSceneValue(\.newFileAction, createNewFile)
        .focusedSceneValue(\.focusSidebarAction, focusSidebar)
        .focusedSceneValue(\.quickOpenAction, { quickOpen.show(root: browsingRoot) })
        .focusedSceneValue(\.openFolderAction, openOtherFolder)
        // Print / Export are wired only in view mode (they drive the rendered web view); in
        // edit mode the action is nil, which disables the File-menu items (D1).
        .focusedSceneValue(\.printAction, mode == .view ? printDocument : nil)
        .focusedSceneValue(\.exportPDFAction, mode == .view ? exportPDF : nil)
        .focusedSceneValue(\.headingJump, jumpRelativeHeading)
        .background(WindowAccessor(rootKey: browsingRoot?.standardizedFileURL.path ?? "none",
                                   fileURL: fileURL, sidebar: sidebar))
        // Toggling to the rendered view focuses it so arrow keys scroll immediately.
        // (The raw editor self-focuses on entry.) Only fires on an actual ⌘E toggle,
        // not on a fresh tab/Space-preview where mode starts at .view.
        .onChange(of: mode) { _, m in
            selection.clear()   // stale count from the outgoing view shouldn't linger
            hoveredLink = ""    // the link-hover pill belongs to the rendered view only
            if m == .view { detailFocus.focus() }
        }
        // DocumentGroup can reuse a window's view state when another file is opened into
        // it. A mode chosen for the previous document should not make the new Markdown
        // file start in raw source; every newly opened file starts in the rendered view.
        .onChange(of: fileURL) { _, newURL in
            guard newURL != nil else { return }
            mode = .view
            if let newURL {
                let file = newURL.standardizedFileURL
                browsingRoot = OpenRootRouter.shared.roots.removeValue(forKey: file)
                    ?? newURL.deletingLastPathComponent()
                sidebar.selection = newURL
                fileSync.start(url: newURL)
            }
        }
        // A sidebar-initiated open can land in this tab (new or already-open); claim
        // the parked focus intent once we're showing that file.
        .onAppear {
            claimPendingFocus()
            sidebar.selection = fileURL
            if let f = fileURL?.standardizedFileURL { OpenRootRouter.shared.roots[f] = nil }
            fileSync.currentText = { document.text }
            fileSync.applyReload = { document.text = $0 }
            fileSync.start(url: fileURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            claimPendingFocus()
        }
    }

    /// If a sidebar open parked a focus intent for this tab's file, apply it (focus the
    /// sidebar for a Space-preview, or the detail view for ⌘↓ / click) and clear it.
    private func claimPendingFocus() {
        guard let p = OpenFocusRouter.shared.pending, let f = fileURL,
              f.standardizedFileURL == p.url.standardizedFileURL else { return }
        OpenFocusRouter.shared.pending = nil
        DispatchQueue.main.async {
            switch p.target {
            case .sidebar: sidebar.focus()
            case .detail: detailFocus.focus()
            }
        }
    }

    /// Creates a new markdown file in the open file's folder and opens it as a tab.
    private func createNewFile() {
        guard let dir = fileURL?.deletingLastPathComponent(),
              let url = FileEntry.makeNewFile(in: dir) else { return }
        if let root = browsingRoot { OpenRootRouter.shared.roots[url.standardizedFileURL] = root }
        tree.reload()
        sidebar.captureScroll(root: browsingRoot)
        if OpenDocumentRouter.showExisting(url) { return }
        MarkdownDocumentOpener.open(url)
    }

    /// ⌘⇧O: pick a folder, then raise the quick-open palette rooted there. Opening a file
    /// from a different folder roots its (new) window at that folder, not the current one.
    private func openOtherFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to browse"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        quickOpen.show(root: folder)
    }

    /// Opens a file chosen from the ⌘O palette (markdown opens as a tab; anything else is
    /// handed to its default app), carrying the sidebar scroll position into the new tab.
    private func openFromQuickOpen(_ url: URL) {
        quickOpen.hide()
        guard FileEntry.isMarkdown(url) else { NSWorkspace.shared.open(url); return }
        // Root the destination at the palette's folder (the picked one for ⌘⇧O, else this tab's).
        open(url, rootedAt: quickOpen.root ?? browsingRoot)
    }

    /// Opens a markdown file in MapleDown from an in-document link, rooted at this tab's folder.
    private func openInApp(_ url: URL) { open(url, rootedAt: browsingRoot) }

    // MARK: - Task checkboxes (A3)

    /// A rendered task checkbox was clicked: flip its marker on the given source line. The
    /// binding change re-renders the view (scroll preserved by renderMarkdown's ratio keep).
    private func toggleTask(_ line: Int) {
        if let updated = TaskList.toggleLine(in: document.text, line: line) {
            document.text = updated
        }
    }

    // MARK: - Image paste & drop policy (B4)

    /// Assets live in `<docDir>/assets/`; pasted bitmaps are named `<docBasename>-<stamp>.png`
    /// (‑2, ‑3 on collision) and dropped/pasted image files are referenced relatively (copied
    /// into assets/ if they live outside the document folder). Returns nil when there's no
    /// on-disk document folder yet (untitled) — image insertion is simply unavailable then.
    private func makeImagePolicy() -> ImagePolicy? {
        guard let docDir = fileURL?.deletingLastPathComponent() else { return nil }
        let basename = fileURL?.deletingPathExtension().lastPathComponent ?? "image"
        return ImagePolicy(
            saveImageData: { data, ext in
                saveImageData(data, ext: ext, docDir: docDir, basename: basename)
            },
            resolveImageFile: { url in
                resolveImageFile(url, docDir: docDir)
            }
        )
    }

    /// Write pasted bitmap bytes to `assets/<basename>-<stamp>.<ext>` and return the
    /// markdown-safe relative path, or nil on write failure.
    private func saveImageData(_ data: Data, ext: String, docDir: URL, basename: String) -> String? {
        let assets = ensureAssets(docDir)
        let stamp = Self.stampFormatter.string(from: Date())
        let name = ImagePolicy.uniqueName(base: "\(basename)-\(stamp)", ext: ext) {
            FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path)
        }
        let dest = assets.appendingPathComponent(name)
        guard (try? data.write(to: dest)) != nil else { return nil }
        return ImagePolicy.encodeForMarkdown("assets/\(name)")
    }

    /// Resolve a dropped/pasted image FILE to a markdown-safe path: relative if it already
    /// lives under the document folder, otherwise copied into assets/ first. nil on failure.
    private func resolveImageFile(_ url: URL, docDir: URL) -> String? {
        let std = url.standardizedFileURL
        let dir = docDir.standardizedFileURL
        let dirPath = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        if std.path.hasPrefix(dirPath) {
            let rel = String(std.path.dropFirst(dirPath.count))
            return ImagePolicy.encodeForMarkdown(rel)
        }
        let assets = ensureAssets(docDir)
        let ext = std.pathExtension.isEmpty ? "png" : std.pathExtension
        let name = ImagePolicy.uniqueName(base: std.deletingPathExtension().lastPathComponent, ext: ext) {
            FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path)
        }
        let dest = assets.appendingPathComponent(name)
        guard (try? FileManager.default.copyItem(at: std, to: dest)) != nil else { return nil }
        return ImagePolicy.encodeForMarkdown("assets/\(name)")
    }

    /// `<docDir>/assets/`, created on demand.
    private func ensureAssets(_ docDir: URL) -> URL {
        let assets = docDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        return assets
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Opens a markdown file in MapleDown as a tab in `root`'s window group, reusing the current
    /// tab if it's already that file. Files sharing `root` tab together; a different root
    /// opens its own window (see WindowAccessor.rootKey).
    private func open(_ url: URL, rootedAt root: URL?) {
        if fileURL?.standardizedFileURL == url.standardizedFileURL { detailFocus.focus(); return }
        OpenFocusRouter.shared.pending = PendingFocus(url: url, target: .detail)
        if let root { OpenRootRouter.shared.roots[url.standardizedFileURL] = root }
        sidebar.captureScroll(root: browsingRoot)
        if OpenDocumentRouter.showExisting(url) { return }
        MarkdownDocumentOpener.open(url)
    }

    /// ⌘⇧E toggle: if the sidebar already holds keyboard focus, bounce focus to the
    /// detail view; otherwise reveal the sidebar (if collapsed) and focus it.
    private func focusSidebar() {
        if let ov = sidebar.outlineView, ov.window?.firstResponder === ov {
            detailFocus.focus()
            return
        }
        if sidebarVis.columnVisibility == .detailOnly {
            withAnimation(.easeInOut(duration: 0.25)) { sidebarVis.columnVisibility = .all }
        }
        sidebar.focus()
    }

    private func jumpToOutline(_ line: Int) {
        let target = max(0, line)
        // Bold this heading immediately. View mode's scroll report can arrive a beat
        // later and name the previous block; edit mode's kit jump uses
        // scrollRangeToVisible, which leaves the heading at the bottom so the top
        // line (what the outline treats as current) stays on the previous section.
        sync.report(line: target, from: mode)
        outlineJumpLine = target
        outlineJumpToken &+= 1
        guard mode == .edit else { return }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                EditorOutlineJump.pinLineToTop(target)
                DispatchQueue.main.async {
                    self.sync.report(line: target, from: .edit)
                }
            }
        }
    }

    /// ⌃⌥↑ / ⌃⌥↓. Previous snaps to the heading of the section on screen, then walks up.
    private func jumpRelativeHeading(_ delta: Int) {
        let lines = Outline.headings(in: document.text).map(\.line)
        guard let line = HeadingNavigation.targetLine(in: lines, current: sync.line, delta: delta) else { return }
        jumpToOutline(line)
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if fileSync.conflict != nil {
                ExternalChangeBar(onReload: { fileSync.reload() }, onKeep: { fileSync.keepMine() })
                Divider()
            }
            if find.isVisible {
                FindBar(find: find, canReplace: mode == .edit)
                Divider()
            }
            modeView
            // Edit mode always shows the count. View mode shows reading time for a
            // non-empty document, and the selection count while text is selected.
            if mode == .edit || selection.count > 0 || !document.text.isEmpty {
                Divider()
                SelectionCountBar(mode: mode, text: document.text, selectedCount: selection.count)
            }
        }
    }

    @ViewBuilder private var modeView: some View {
        switch mode {
        case .view:
            MarkdownWebView(markdown: document.text, find: find, sync: sync,
                            initialLine: sync.target(for: .view), focusPulse: detailFocus.pulse,
                            fontScale: fontScale.scale, fullWidth: fullWidth.isFullWidth, selection: selection,
                            docDirectory: fileURL?.deletingLastPathComponent(), onOpenFile: openInApp,
                            onToggleTask: toggleTask,
                            onHoverLink: { hoveredLink = $0 },
                            jumpToken: outlineJumpToken, jumpLine: outlineJumpLine,
                            viewerHandle: viewerHandle)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) {
                    if !hoveredLink.isEmpty { LinkHoverPill(href: hoveredLink) }
                }
        case .edit:
            MarkdownSourceEditor(
                text: $document.text,
                config: EditorConfig(fontScale: fontScale.scale, fullWidth: fullWidth.isFullWidth,
                                      lintEnabled: lint.isEnabled),
                find: find,
                initialLine: sync.target(for: .edit),
                focusPulse: detailFocus.pulse,
                cursor: editCursor,
                buffer: editBuffer,
                imagePolicy: makeImagePolicy(),
                jumpRequest: outlineJumpLine.map { (outlineJumpToken, $0) },
                onEvent: { event in
                    switch event {
                    case .scrolled(let topLine): sync.report(line: topLine, from: .edit)
                    case .selection(let count): selection.report(count)
                    }
                }
            )
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: createNewFile) {
                Image(systemName: "square.and.pencil")
            }
            .help("New Markdown File  (⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { fullWidth.isFullWidth },
                                 set: { _ in fullWidth.toggle() })) {
                Image(systemName: "arrow.left.and.right")
            }
            .help("Toggle Full Width  (⇧⌘F)")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $mode) {
                Image(systemName: "eye").tag(EditorMode.view)
                Image(systemName: "pencil").tag(EditorMode.edit)
            }
            .pickerStyle(.segmented)
            .help("Toggle View / Edit  (⌘E)")
        }
        // Share the document file itself (D1). ShareLink renders as a native toolbar share
        // button; hidden for an untitled (no-URL) document.
        if let fileURL {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share")
            }
        }
    }

    // MARK: - Print / Export PDF (D1)

    /// Print the RENDERED document. Only reachable in view mode (the menu item is disabled in
    /// edit mode), so the live rendered web view is always present — no fragile render-then-print.
    private func printDocument() {
        guard let webView = viewerHandle.webView, let window = webView.window else { return }
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        info.horizontalPagination = .fit           // scale to page width, never clip
        info.verticalPagination = .automatic       // paginate long documents
        info.isHorizontallyCentered = false
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Export the rendered document to PDF via a save panel (default name = doc basename.pdf).
    /// View-mode only, matching Print.
    private func exportPDF() {
        guard let webView = viewerHandle.webView else { return }
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            guard case .success(let data) = result else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue =
                (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".pdf"
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        }
    }
}

/// Banner shown when the open file changed on disk while the buffer also has unsaved edits.
/// Reload adopts the disk version; Keep Mine ignores it (the next save overwrites disk).
private struct ExternalChangeBar: View {
    let onReload: () -> Void
    let onKeep: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This file changed on disk.").font(.caption)
            Spacer(minLength: 0)
            Button("Reload", action: onReload)
            Button("Keep Mine", action: onKeep)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Trailing readout. Edit mode shows words, characters, and reading time. View mode
/// shows reading time for the document, plus a selection count while text is selected.
/// CJK ideographs count as words so a Chinese note's reading time is not "1 word".
private struct SelectionCountBar: View {
    let mode: EditorMode
    let text: String
    let selectedCount: Int
    @State private var counts: DocumentStats?

    var body: some View {
        HStack {
            Spacer()
            Text(readout)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        // Counting walks the whole document. Keep it off the key-event path and
        // coalesce a burst of edits into one pass after typing pauses.
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = text
            let updated = await Task.detached(priority: .utility) {
                DocumentStats.measure(snapshot)
            }.value
            guard !Task.isCancelled else { return }
            counts = updated
        }
    }

    private var readout: String {
        guard let counts else { return "Counting…" }
        let words = counts.words
        let wordLabel = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        if mode == .view {
            var s = "\(counts.readingLabel) · \(wordLabel)"
            if selectedCount > 0 { s += " · \(selectedCount) selected" }
            return s
        }
        let chars = counts.characters
        var s = "\(wordLabel) · \(chars.formatted()) character\(chars == 1 ? "" : "s") · \(counts.readingLabel)"
        if selectedCount > 0 { s += " · \(selectedCount) selected" }
        return s
    }
}

/// Word and reading-time counts. Latin words break on whitespace. Each CJK ideograph
/// counts as one word (about 400 per minute); Latin prose uses 220 words per minute.
private struct DocumentStats: Sendable {
    var latinWords: Int
    var cjkCharacters: Int
    var characters: Int

    var words: Int { latinWords + cjkCharacters }

    var readingLabel: String {
        let minutes = Double(latinWords) / 220 + Double(cjkCharacters) / 400
        if words == 0 { return "0 min read" }
        if minutes < 0.5 { return "< 1 min read" }
        let n = max(1, Int(minutes.rounded()))
        return "\(n) min read"
    }

    static func measure(_ text: String) -> DocumentStats {
        var latin = 0
        var cjk = 0
        var inLatin = false
        for ch in text {
            if ch.isWhitespace {
                if inLatin { latin += 1; inLatin = false }
                continue
            }
            if isIdeograph(ch) {
                if inLatin { latin += 1; inLatin = false }
                cjk += 1
            } else {
                inLatin = true
            }
        }
        if inLatin { latin += 1 }
        return DocumentStats(latinWords: latin, cjkCharacters: cjk, characters: text.count)
    }

    private static func isIdeograph(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF:
                return true
            default:
                return false
            }
        }
    }
}

/// Safari-style link-hover status pill (A7): the href under the pointer, bottom-leading over
/// the rendered view. Non-interactive so it never intercepts clicks. Shown only when non-empty.
private struct LinkHoverPill: View {
    let href: String
    var body: some View {
        Text(href)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.bar, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// Bridges to the hosting NSWindow once it exists. Forces additional documents to
/// open as tabs (not separate windows) and persists the window size across launches.
/// Note: NSWindow `frameAutosaveName` is intentionally NOT used — it disables window
/// tabbing — so size persistence is done manually via UserDefaults.
private struct WindowAccessor: NSViewRepresentable {
    /// Files sharing this key (their parent folder) tab together; different keys open new windows.
    let rootKey: String
    let fileURL: URL?
    let sidebar: SidebarController

    func makeCoordinator() -> Coordinator {
        Coordinator(rootKey: rootKey, fileURL: fileURL, sidebar: sidebar)
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let v = WindowReaderView()
        let coord = context.coordinator
        v.onWindow = { window in coord.attach(window) }
        return v
    }
    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.update(fileURL: fileURL)
    }
    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Fires `onWindow` exactly when the view is placed into its hosting window.
    final class WindowReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private weak var attachedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window !== attachedWindow {
                attachedWindow = window
                onWindow?(window)
            }
        }
    }

    final class Coordinator {
        private static let sizeKey = "mapledown.windowSize"
        private static let registry = NSHashTable<NSWindow>.weakObjects()
        private let rootKey: String
        private var fileURL: URL?
        private weak var window: NSWindow?
        private weak var sidebar: SidebarController?
        private var token: NSObjectProtocol?
        private var keyToken: NSObjectProtocol?

        init(rootKey: String, fileURL: URL?, sidebar: SidebarController) {
            self.rootKey = rootKey
            self.fileURL = fileURL
            self.sidebar = sidebar
        }

        private var tabID: NSWindow.TabbingIdentifier { "mapledown::\(rootKey)" }

        /// Last user-chosen window size, or a sensible default if none cached yet.
        private static func cachedSize() -> NSSize {
            if let d = UserDefaults.standard.dictionary(forKey: sizeKey),
               let w = d["w"] as? Double, let h = d["h"] as? Double, w > 300, h > 200 {
                return NSSize(width: w, height: h)
            }
            return NSSize(width: 1200, height: 820)
        }

        func attach(_ window: NSWindow) {
            if self.window === window { return }
            detach()
            self.window = window
            window.tabbingMode = .preferred
            window.tabbingIdentifier = tabID

            // An existing MapleDown window for the SAME root is the tab host. Look past our
            // weak registry to every app window, so a momentary registry miss during
            // rapid opening can't spawn a stray un-tabbed window — that stray window was
            // what knocked a single Magnet-snapped window out of its arrangement.
            let host = existingHost(excluding: window)
            Self.registry.add(window)

            if let host {
                // Tab into the existing group and adopt its exact frame, so adding a tab
                // never moves or resizes the window the user (or Magnet) positioned.
                let hostFrame = host.frame
                if window.tabGroup !== host.tabGroup {
                    host.addTabbedWindow(window, ordered: .above)
                }
                window.setFrame(hostFrame, display: false)
                window.makeKeyAndOrderFront(nil)
                // AppKit/SwiftUI sometimes runs a post-tab layout pass that nudges the
                // group off its Magnet snap; re-assert the frame once it settles.
                DispatchQueue.main.async { [weak host, weak window] in
                    guard let host, let window else { return }
                    let f = host.frame
                    if window.frame != f { window.setFrame(f, display: false) }
                }
            } else {
                // First window of this root -> cached size (or default fallback), centered
                // on the active screen instead of inheriting AppKit's edge-aligned origin.
                var f = window.frame
                f.size = Self.cachedSize()
                window.setFrame(f, display: true)
                window.center()
            }

            // persist size on resize
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                guard let s = window?.frame.size else { return }
                UserDefaults.standard.set(["w": Double(s.width), "h": Double(s.height)], forKey: Self.sizeKey)
            }
            keyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sidebar?.selection = self.fileURL
            }
        }

        func update(fileURL newURL: URL?) {
            guard newURL != fileURL else { return }
            fileURL = newURL
        }

        /// An existing live MapleDown window sharing this tab id — registry first, then a
        /// sweep of all app windows in case the registry hasn't caught up yet.
        private func existingHost(excluding window: NSWindow) -> NSWindow? {
            let match: (NSWindow) -> Bool = {
                $0 !== window && $0.isVisible && $0.tabbingIdentifier == self.tabID
            }
            return Self.registry.allObjects.first(where: match) ?? NSApp.windows.first(where: match)
        }

        func detach() {
            if let token { NotificationCenter.default.removeObserver(token) }
            if let keyToken { NotificationCenter.default.removeObserver(keyToken) }
            token = nil
            keyToken = nil
            window = nil
        }
    }
}
