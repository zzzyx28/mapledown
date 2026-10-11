<div align="center">

[中文](README.zh-CN.md)

<img src="assets/icon.png" width="128" alt="MapleDown icon">

# MapleDown

**A light Markdown app for Mac. The page comes first.**

Open a file and read. Press `⌘E` when you want the source. Nothing else asks for your attention.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

<br>

<img src="assets/screenshot-view.png" width="860" alt="MapleDown in View: a quiet page, with the folder and outline beside it">

</div>

---

MapleDown is a native Mac app. It stays on your machine, does not sign you in, and does not phone home to render a page. Formulas, tables, and code are drawn locally. The window remembers its size. Light and dark follow the system.

Launch it with nothing open and you get two choices: start a new Markdown file, or open one you already have. Opening a file puts that page in front. Closing the last document brings the start screen back.

| Reading | Writing |
| :---: | :---: |
| <img src="assets/screenshot-view.png" alt="View mode"> | <img src="assets/screenshot-edit.png" alt="Edit mode"> |

**View** is the document: headings, math, tables, task lists, highlighted code, and a reading time. **Edit** is the text itself. Markdown warnings stay quiet until you want them, and you can hide them from the View menu.

The sidebar is the folder you are already in. Click a Markdown file to open it here; files in that folder become tabs, and a file from somewhere else opens in its own window. Other file types stay in the list until you double-click them, which opens them in their own app. Under the files, the outline follows the section you are reading. `⌃⌥↑` and `⌃⌥↓` move between headings.

In Finder, select a `.md` file and press <kbd>space</kbd>. Quick Look shows the same rendered page, including math.

## Install

Requires macOS 14 (Sonoma) or later.

Download the latest `.dmg` from **[Releases](https://github.com/zzzyx28/mapledown/releases)**, open it, and drag MapleDown to Applications.

The download is not notarized by Apple. If macOS stops the first launch, Control-click MapleDown and choose **Open**, or allow it in **System Settings → Privacy & Security**.

Open MapleDown once so Quick Look can register. To make it the default app for Markdown, right-click any `.md` file → **Get Info** → **Open with** → **MapleDown** → **Change All…**

To remove it, delete MapleDown from Applications, then change the Open With app for `.md` files if you had set it as the default.

## Shortcuts

| | |
|---|---|
| View / Edit | `⌘E` |
| Show or hide the sidebar | `⌘\` |
| Previous / next heading | `⌃⌥↑` / `⌃⌥↓` |
| Outline | `⌃⌘1` |
| Next / previous tab | `⌘⌥→` / `⌘⌥←` |
| Jump to a tab | `⌘1` … `⌘9` |
| New line below / above | `⌘↩` / `⇧⌘↩` |
| Move / duplicate a line | `⌥↑` `⌥↓` / `⌥⇧↑` `⌥⇧↓` |
| Delete a line | `⇧⌘K` |
| Comment or uncomment | `⌘/` |

## License

[MIT](LICENSE) © 2026 Zhengyx. MapleDown is derived from [Glim](https://github.com/yeduk3/Glim) by yeduk3, also MIT. Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
