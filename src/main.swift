// Agent Bar Hopping — every Claude Code session's status line in one window.
//
// The status line spools its render arguments on each redraw; `cc-statusline.js
// live` turns that spool into drawn rows plus parsed fields. This app watches the
// spool directory and re-runs that command when it changes, so the window
// repaints exactly as often as the bars do and never on a timer of its own —
// apart from a slow tick that ages the countdowns and retires ended sessions.
//
// Rendering stays in the Node renderer rather than being reimplemented here:
// one definition of what a bar looks like, shared with the terminal.

import AppKit
import Foundation

// MARK: - Paths

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser

/// An XDG base dir from the environment, else the conventional location under $HOME.
func xdgDir(_ key: String, fallback: String) -> URL {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty {
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
    }
    return home.appendingPathComponent(fallback)
}

let cacheDir: URL = {
    if let v = ProcessInfo.processInfo.environment["CC_STATUSLINE_CACHE_DIR"], !v.isEmpty {
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
    }
    return xdgDir("XDG_CACHE_HOME", fallback: ".cache").appendingPathComponent("cc-statusline")
}()
let spoolDir = cacheDir.appendingPathComponent("live")
let logURL = home.appendingPathComponent("Library/Logs/agent-bar-hopping.log")

/// The checkout this bundle was built from; bundle.sh writes it into Info.plist.
let repoDir: URL = {
    if let p = Bundle.main.object(forInfoDictionaryKey: "CCStatuslineRepo") as? String, !p.isEmpty {
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    return home.appendingPathComponent("dev/cc-statusline")
}()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Model

struct Limit: Decodable {
    let percent: Double?
    let resets_at: Double?
}

struct CacheState: Decodable {
    let warm: Bool
    let expires_at: Double?
    let ttl: String?
    let rebuild: Double?
}

struct GitState: Decodable {
    let branch: String?
    let ahead: Int?
    let behind: Int?
    let staged: Int?
    let unstaged: Int?
    let untracked: Int?
    let conflicts: Int?
    let action: String?
}

struct Summary: Decodable {
    let session_id: String?
    let model: String?
    let effort: String?
    let started_at: Double?
    let context: Double?
    let five_hour: Limit?
    let seven_day: Limit?
    let fable: Limit?
    let fable_error: String?
    let cache: CacheState?
    let topic: String?
    let topic_is_new: Bool?
    let cwd: String?
    let git: GitState?
}

/// The drawn segments of a session's first row, each with its escapes intact.
struct Segments: Decodable {
    let model: String?
    let effort: String?
    let started: String?
    let context: String?
    let five_hour: String?
    let seven_day: String?
    let fable: String?
    let cache: String?
}

struct Session: Decodable {
    let updated_at: Double
    /// The later of the last redraw and the last transcript write: a busy
    /// session can go minutes without redrawing.
    let active_at: Double?
    let tty: String?
    let rows: [String]
    let summary: Summary
    let segments: Segments
}

struct Snapshot: Decodable {
    let live: [Session]
    let history: [Session]
}

// MARK: - Reading the spool

/// Runs `cc-statusline.js live` and decodes its one JSON document. The script is
/// the only thing that knows how a row is drawn, so the app never parses a bar.
func readSnapshot(columns: Int) -> Snapshot? {
    let script = repoDir.appendingPathComponent("cc-statusline.js")
    guard fm.isExecutableFile(atPath: script.path) else {
        log("cc-statusline.js not executable at \(script.path)")
        return nil
    }

    let task = Process()
    task.executableURL = script
    task.arguments = ["live", "--columns", String(columns)]
    // Launched from Finder the app inherits launchd's bare PATH, which has no
    // node: the script's `env node` line then fails with 127. Put the usual
    // shims back, as the other local apps' launchers do.
    var env = ProcessInfo.processInfo.environment
    let shims = [
        "\(home.path)/.local/bin", "\(home.path)/.asdf/shims", "/opt/homebrew/bin", "/usr/local/bin",
        "\(home.path)/bin", "/usr/bin", "/bin",
    ]
    env["PATH"] = (shims + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
    task.environment = env
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
    } catch {
        log("spawn failed: \(error.localizedDescription)")
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        let hint = task.terminationStatus == 127 ? " (node not found on PATH)" : ""
        log("cc-statusline.js live exited \(task.terminationStatus)\(hint)")
        return nil
    }
    do {
        return try JSONDecoder().decode(Snapshot.self, from: data)
    } catch {
        log("decode failed: \(error)")
        return nil
    }
}

// MARK: - Colours, matching the status line's own

enum Palette {
    static let background = NSColor(srgbRed: 0.078, green: 0.086, blue: 0.106, alpha: 1)
    static let panel = NSColor(srgbRed: 0.106, green: 0.114, blue: 0.137, alpha: 1)
    static let text = NSColor(srgbRed: 0.843, green: 0.855, blue: 0.878, alpha: 1)
    static let dim = NSColor(srgbRed: 0.490, green: 0.510, blue: 0.561, alpha: 1)
    static let frame = NSColor(srgbRed: 0.259, green: 0.271, blue: 0.314, alpha: 1)
    static let yellow = NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 1)
    static let red = NSColor(srgbRed: 0.878, green: 0.424, blue: 0.459, alpha: 1)

    /// The status line's own thresholds: faint under 75, yellow from 75, red from 92.
    static func threshold(_ percent: Double?) -> NSColor {
        guard let p = percent else { return dim }
        if p >= 92 { return red }
        if p >= 75 { return yellow }
        return text
    }
}

let barFont: NSFont = {
    for name in ["FiraCode Nerd Font Mono", "FiraCodeNFM-Reg", "FiraCode Nerd Font", "Menlo"] {
        if let f = NSFont(name: name, size: 12) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}()

// MARK: - ANSI to attributed text

/// Turns the escapes the renderer emits into attributes: bold, faint, red,
/// yellow, and the 24-bit grey of the arrows and diamonds.
func attributed(ansi: String, font: NSFont) -> NSAttributedString {
    let out = NSMutableAttributedString()
    var bold = false
    var faint = false
    var colour: NSColor? = nil
    var chunk = ""

    func flush() {
        guard !chunk.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font,
            .foregroundColor: colour ?? (faint ? Palette.dim : Palette.text),
        ]
        if colour == nil && faint { attrs[.foregroundColor] = Palette.dim }
        out.append(NSAttributedString(string: chunk, attributes: attrs))
        chunk = ""
    }

    var rest = Substring(ansi)
    while let esc = rest.firstIndex(of: "\u{1b}") {
        chunk += rest[rest.startIndex..<esc]
        rest = rest[rest.index(after: esc)...]
        guard rest.first == "[", let m = rest.firstIndex(of: "m") else { continue }
        let codes = rest[rest.index(after: rest.startIndex)..<m].split(separator: ";").map { Int($0) ?? 0 }
        rest = rest[rest.index(after: m)...]
        flush()
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0: bold = false; faint = false; colour = nil
            case 1: bold = true
            case 2: faint = true
            case 31: colour = Palette.red
            case 33: colour = Palette.yellow
            case 38 where i + 4 < codes.count && codes[i + 1] == 2:
                colour = NSColor(
                    srgbRed: CGFloat(codes[i + 2]) / 255, green: CGFloat(codes[i + 3]) / 255,
                    blue: CGFloat(codes[i + 4]) / 255, alpha: 1)
                i += 4
            default: break
            }
            i += 1
        }
    }
    chunk += rest
    flush()
    return out
}

// MARK: - Formatting for the grid

func ago(_ epochMs: Double) -> String {
    let s = max(0, Int(Date().timeIntervalSince1970 - epochMs / 1000))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func until(_ epochMs: Double?) -> String {
    guard let ms = epochMs else { return "" }
    let s = Int(ms / 1000 - Date().timeIntervalSince1970)
    if s <= 0 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return String(format: "%.1fh", Double(s) / 3600) }
    return String(format: "%.1fd", Double(s) / 86400)
}

func share(_ percent: Double?) -> String {
    guard let p = percent else { return "—" }
    let r = Int(p.rounded())
    return r >= 100 ? "1.0" : String(format: ".%02d", max(0, r))
}

func cacheText(_ c: CacheState?) -> String {
    guard let c = c else { return "—" }
    if !c.warm {
        guard let rebuild = c.rebuild else { return "cold" }
        return "cold · \(tokens(rebuild))"
    }
    guard let expires = c.expires_at else { return "warm" }
    return until(expires)
}

func tokens(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1000 { return "\(Int((n / 1000).rounded()))k" }
    return "\(Int(n))"
}

func gitText(_ g: GitState?) -> String {
    guard let g = g, let branch = g.branch else { return "—" }
    var out = ""
    if let a = g.ahead, a > 0 { out += "⇡\(a) " }
    if let b = g.behind, b > 0 { out += "⇣\(b) " }
    if (g.conflicts ?? 0) > 0 { out += "~" }
    if (g.staged ?? 0) + (g.unstaged ?? 0) + (g.untracked ?? 0) > 0 { out += "*" }
    out += branch
    if let action = g.action, !action.isEmpty { out += " (\(action))" }
    return out
}

/// The share of a cache's life already spent, so the cell colours like a bar.
func cacheElapsed(_ c: CacheState?) -> Double? {
    guard let c = c else { return nil }
    guard c.warm else { return 100 }
    guard let expires = c.expires_at, let ttl = c.ttl else { return nil }
    let unit = ttl.last
    let value = Double(ttl.dropLast()) ?? 0
    let ttlMs = value * (unit == "h" ? 3_600_000 : unit == "m" ? 60000 : 1000)
    guard ttlMs > 0 else { return nil }
    let left = expires - Date().timeIntervalSince1970 * 1000
    return 100 * (1 - max(0, left) / ttlMs)
}

// MARK: - Jumping to a session's terminal

/// Brings the iTerm2 tab whose session owns this tty to the front. iTerm exposes
/// `tty` on every session, so the lookup is exact rather than a guess from titles.
func focusTerminal(tty: String) {
    let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select t
                  select s
                  -- A hidden hotkey window ignores `select` and reveals itself,
                  -- bringing iTerm forward; `activate` on top of that can make
                  -- iTerm open a fresh tab, so each case gets one or the other.
                  if is hotkey window of w then
                    reveal hotkey window
                  else
                    select w
                    activate
                  end if
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "not found"
        """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    let out = Pipe()
    let err = Pipe()
    task.standardOutput = out
    task.standardError = err
    do {
        try task.run()
    } catch {
        log("focus \(tty): \(error.localizedDescription)")
        return
    }
    // Apple Events can be refused silently; whatever osascript says is logged.
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    log(
        "focus \(tty): exit \(task.terminationStatus) out=\(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) "
            + "err=\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")

    // The script selects the tab, but a hotkey window hides again unless iTerm
    // is the active app — and AppleScript's own `activate` makes iTerm open a
    // fresh tab when the hotkey window is hidden. Activating the process
    // directly does neither.
    if let iterm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first {
        iterm.activate(options: [.activateAllWindows])
    } else {
        log("focus \(tty): iTerm2 is not running")
    }
}

/// A cell that acts on a click and says so with the cursor.
final class ClickableCell: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 1, let onClick = onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        discardCursorRects()
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// A short highlight, so a copy that changes nothing on screen is still felt.
    func flash() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 0.22).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Window

final class SessionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let statusLabel = NSTextField(labelWithString: "")
    private let quotaBar = NSTextField(labelWithString: "")
    private let gridScroll = NSScrollView()
    private let table = NSTableView()

    private var rows: [(session: Session, past: Bool)] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var paintedOnce = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1560, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Agent Bar Hopping"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.background
        window.center()
        window.setFrameAutosaveName("AgentBarHopping")
        super.init(window: window)
        build()
        startWatching()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor

        statusLabel.textColor = Palette.dim
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // The account-wide quotas, once, above a table whose rows may run long.
        quotaBar.translatesAutoresizingMaskIntoConstraints = false
        quotaBar.maximumNumberOfLines = 2
        quotaBar.lineBreakMode = .byTruncatingTail

        buildColumns()
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Palette.background
        table.gridColor = Palette.frame
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        // Two lines in every cell: what the status line draws, and what it means.
        table.rowHeight = ceil(barFont.boundingRectForFont.height) + 16 + 12
        table.usesAlternatingRowBackgroundColors = false
        // A selected row has AppKit rewrite the fonts and colours of the labels
        // inside it. Nothing here needs a selected state, and the text stays
        // selectable for copying a session id.
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.target = self
        table.doubleAction = nil
        // The default spacing plus per-cell padding is most of the row's width.
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        gridScroll.documentView = table
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(statusLabel)
        content.addSubview(quotaBar)
        content.addSubview(gridScroll)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            quotaBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            quotaBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            quotaBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            gridScroll.topAnchor.constraint(equalTo: quotaBar.bottomAnchor, constant: 12),
            gridScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

    }

    private struct Column {
        let key: String
        let title: String
        let width: CGFloat
    }

    // Widths are the content's, not round numbers: the row has twelve columns and
    // every spare point pushes the last one off the screen.
    // Widths are the content's, not round numbers: every spare point pushes the
    // last column off the screen. The account-wide quotas are not here — they are
    // the same for every session, so they live in the bar above the table.
    private let columns: [Column] = [
        Column(key: "topic", title: "Doing", width: 300),
        Column(key: "cwd", title: "Directory", width: 164),
        Column(key: "git", title: "Branch", width: 132),
        Column(key: "model", title: "Model", width: 78),
        Column(key: "effort", title: "Effort", width: 66),
        Column(key: "started", title: "Started", width: 96),
        Column(key: "context", title: "Context", width: 100),
        Column(key: "cache", title: "Cache", width: 140),
        Column(key: "age", title: "Last Seen", width: 84),
    ]

    private func buildColumns() {
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 16
            // The centred columns centre their header too, or the two disagree.
            if spec.key == "model" || spec.key == "effort" {
                column.headerCell.alignment = .center
            }
            // Each column sorts by what it means, not by the text it shows:
            // model by capability, effort by level, cache by time left.
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key, ascending: true)
            table.addTableColumn(column)
        }
    }

    // MARK: Loading

    /// The width the whole row would be drawn at. The grid shows segments rather
    /// than rows, so this only decides how the unused `rows` come back.
    private func rowColumns() -> Int { 120 }

    func reload() {
        let cols = rowColumns()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = readSnapshot(columns: cols)
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: Snapshot?) {
        guard let snapshot = snapshot else {
            statusLabel.stringValue = "cc-statusline not reachable — see \(logURL.path)"
            return
        }
        if !paintedOnce {
            paintedOnce = true
            log("first paint: \(snapshot.live.count) live, \(snapshot.history.count) finished")
        }
        rows = snapshot.live.map { ($0, false) } + snapshot.history.map { ($0, true) }
        statusLabel.stringValue = "\(snapshot.live.count) live · \(snapshot.history.count) finished"
        drawQuotaBar(snapshot)
        sortRows()
        table.reloadData()
    }

    // MARK: Watching

    private func startWatching() {
        try? fm.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        let fd = open(spoolDir.path, O_EVTONLY)
        guard fd >= 0 else {
            log("cannot watch \(spoolDir.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source

        // Countdowns keep running while nothing redraws, and a session only
        // becomes "finished" with the passage of time.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reload() }
    }

    /// A redraw writes one file, but the watcher fires more than once for it.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Grid

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let (session, past) = rows[row]
        let s = session.summary
        let seg = session.segments

        // Every cell is a stack: the status line's own drawing on top, the value
        // spelled out underneath.
        let top: NSAttributedString
        let bottom: String
        // A background tint for the columns where the number is a temperature.
        var heat: NSColor? = nil
        switch key {
        case "topic":
            // The dot carries the live/ended state; a column of its own was a sliver.
            let dot = mono(past ? "○  " : "●  ", past ? Palette.frame : Palette.yellow)
            let title = NSMutableAttributedString(attributedString: dot)
            title.append(prose(s.topic ?? "—", (s.topic_is_new ?? false) ? Palette.yellow : Palette.text))
            top = title
            bottom = s.session_id ?? ""
        case "cwd":
            top = prose(s.cwd ?? "—", Palette.text)
            bottom = session.tty.map { $0.replacingOccurrences(of: "/dev/", with: "") } ?? ""
        case "git":
            top = mono(gitText(s.git), Palette.text)
            bottom = gitWords(s.git)
        case "model":
            top = drawn(seg.model)
            bottom = s.model ?? ""
        case "effort":
            top = drawn(seg.effort)
            bottom = s.effort ?? ""
        case "started":
            top = drawn(seg.started)
            bottom = s.started_at.map { "\(ago($0)) ago" } ?? ""
        case "context":
            top = drawn(seg.context)
            bottom = percent(s.context)
        case "cache":
            top = drawn(seg.cache)
            bottom = cacheWords(s.cache)
            heat = cacheHeat(s.cache)
        case "age":
            top = mono("\(ago(session.active_at ?? session.updated_at)) ago", Palette.dim)
            bottom = ""
        default:
            top = NSAttributedString(string: "")
            bottom = ""
        }

        let stack = NSMutableAttributedString(attributedString: past ? faded(top) : top)
        if !bottom.isEmpty {
            // The session id is meant to be copied into `claude --resume`, so it
            // is monospaced and never shortened.
            let font: NSFont =
                key == "topic"
                ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) : NSFont.systemFont(ofSize: 11)
            stack.append(
                NSAttributedString(
                    string: "\n" + bottom,
                    attributes: [.font: font, .foregroundColor: past ? Palette.frame : Palette.dim]))
        }

        // Model and effort are shapes, not sentences: they read better centred.
        let centred = key == "model" || key == "effort"
        if centred {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            stack.addAttribute(
                .paragraphStyle, value: style, range: NSRange(location: 0, length: stack.length))
        }

        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = stack
        // Selectable text steals the click and re-styles itself when focused, so
        // the cells act on a click instead of letting text be dragged over.
        field.isSelectable = false
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.alignment = centred ? .center : .left
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = ClickableCell()
        if let heat = heat, !past {
            cell.wantsLayer = true
            cell.layer?.backgroundColor = heat.cgColor
        }
        if key == "topic", let id = s.session_id {
            field.toolTip = "Click to copy the session id"
            cell.onClick = { [weak cell] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
                cell?.flash()
            }
        } else if key == "cwd", let tty = session.tty, !past {
            // The directory cell names the terminal under it; clicking goes there.
            field.toolTip = "Show \(tty) in iTerm"
            cell.onClick = { focusTerminal(tty: tty) }
        }
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: centred ? 2 : 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: centred ? -2 : -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The quotas every session shares, taken from the session that redrew last:
    /// they are account-wide, so one reading serves the whole window.
    private func drawQuotaBar(_ snapshot: Snapshot) {
        let newest = (snapshot.live + snapshot.history).max { $0.updated_at < $1.updated_at }
        let fableSource = (snapshot.live + snapshot.history)
            .filter { $0.segments.fable != nil }
            .max { $0.updated_at < $1.updated_at }

        let line = NSMutableAttributedString()
        func part(_ title: String, _ ansi: String?, _ words: String) {
            guard let ansi = ansi, !ansi.isEmpty else { return }
            if line.length > 0 {
                line.append(
                    NSAttributedString(
                        string: "      ", attributes: [.font: barFont, .foregroundColor: Palette.frame]))
            }
            line.append(
                NSAttributedString(
                    string: title + "  ",
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.dim]))
            line.append(attributed(ansi: ansi, font: barFont))
            if !words.isEmpty {
                line.append(
                    NSAttributedString(
                        string: "  " + words,
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dim]))
            }
        }

        part("5-hour quota", newest?.segments.five_hour, limitWords(newest?.summary.five_hour))
        part("7-day quota", newest?.segments.seven_day, limitWords(newest?.summary.seven_day))
        part("Fable quota", fableSource?.segments.fable, limitWords(fableSource?.summary.fable))
        quotaBar.attributedStringValue = line.length > 0
            ? line
            : NSAttributedString(
                string: "no quota reading yet",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.frame])
    }

    // MARK: Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    /// Each column sorts by its meaning: a model by how capable it is, an effort
    /// by its level, a cache by the time it has left. Live sessions stay above
    /// finished ones whatever the sort.
    private func sortRows() {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else { return }
        let ascending = descriptor.ascending

        func rank(_ entry: (session: Session, past: Bool)) -> (Double, String) {
            let s = entry.session.summary
            switch key {
            case "topic": return (0, (s.topic ?? "~").lowercased())
            case "cwd": return (0, (s.cwd ?? "~").lowercased())
            case "git": return (0, (s.git?.branch ?? "~").lowercased())
            case "model": return (modelRank(s.model), (s.model ?? "").lowercased())
            case "effort": return (effortRank(s.effort), s.effort ?? "")
            case "started": return (s.started_at ?? 0, "")
            case "context": return (s.context ?? -1, "")
            case "cache": return (cacheLeft(s.cache), "")
            case "age": return (entry.session.active_at ?? entry.session.updated_at, "")
            default: return (0, "")
            }
        }

        rows.sort { a, b in
            if a.past != b.past { return !a.past }
            let (an, at) = rank(a)
            let (bn, bt) = rank(b)
            if an != bn { return ascending ? an < bn : an > bn }
            if at != bt { return ascending ? at < bt : at > bt }
            return a.session.updated_at > b.session.updated_at
        }
    }

    /// Haiku, Sonnet, Opus, Fable: the tiers in order of capability.
    private func modelRank(_ model: String?) -> Double {
        switch (model ?? "").lowercased() {
        case "haiku": return 1
        case "sonnet": return 2
        case "opus": return 3
        case "fable": return 4
        default: return 0
        }
    }

    private func effortRank(_ effort: String?) -> Double {
        switch (effort ?? "").lowercased() {
        case "low": return 1
        case "medium": return 2
        case "high": return 3
        case "xhigh": return 4
        case "max": return 5
        default: return 0
        }
    }

    /// Seconds of cache life left; a cold cache has none.
    private func cacheLeft(_ cache: CacheState?) -> Double {
        guard let cache = cache, cache.warm, let expires = cache.expires_at else { return -1 }
        return max(0, expires / 1000 - Date().timeIntervalSince1970)
    }

    private func mono(_ text: String, _ colour: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: barFont, .foregroundColor: colour])
    }

    private func prose(_ text: String, _ colour: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: colour])
    }

    /// A segment exactly as the status line draws it, escapes and all.
    private func drawn(_ ansi: String?) -> NSAttributedString {
        guard let ansi = ansi, !ansi.isEmpty else { return mono("—", Palette.frame) }
        return attributed(ansi: ansi, font: barFont)
    }

    /// Finished sessions keep their shapes but recede.
    private func faded(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            let colour = (value as? NSColor) ?? Palette.text
            out.addAttribute(.foregroundColor, value: colour.withAlphaComponent(0.45), range: range)
        }
        return out
    }

    /// The cache's own temperature, read literally: a freshly written cache is
    /// hot, it cools as its life is spent, and a cold one is blue — the colour
    /// the status line already gives it.
    private func cacheHeat(_ cache: CacheState?) -> NSColor? {
        guard let cache = cache else { return nil }
        guard cache.warm else {
            return NSColor(srgbRed: 0.38, green: 0.55, blue: 0.92, alpha: 0.30)
        }
        guard let elapsed = cacheElapsed(cache) else { return nil }
        let spent = min(1, max(0, elapsed / 100))
        // 14° red-orange when fresh, through amber, to 205° blue at expiry.
        let hue = (14 + 191 * pow(spent, 1.25)) / 360
        // Hottest and coldest read strongest; the middle is quietest.
        let strength = 0.12 + 0.16 * abs(spent - 0.5) * 2
        return NSColor(hue: hue, saturation: 0.78, brightness: 0.95, alpha: strength)
    }

    /// The context window has no reset, and the bar above already carries the
    /// share, so the line under it says how much room is left.
    private func percent(_ value: Double?) -> String {
        guard let v = value else { return "" }
        return "\(Int((100 - v).rounded()))% free"
    }

    /// When the quota comes back. The share is already on the bar above it.
    private func limitWords(_ limit: Limit?) -> String {
        guard let limit = limit, limit.percent != nil else { return "" }
        let left = until(limit.resets_at)
        return left.isEmpty ? "" : "resets in \(left)"
    }

    private func cacheWords(_ cache: CacheState?) -> String {
        guard let cache = cache else { return "" }
        guard cache.warm else {
            guard let rebuild = cache.rebuild else { return "cold" }
            return "cold · \(tokens(rebuild)) to rebuild"
        }
        guard let expires = cache.expires_at else { return "warm" }
        return "warm · \(until(expires)) left"
    }

    /// The branch symbols spelled out: what ⇡1 ~ * actually stand for.
    private func gitWords(_ git: GitState?) -> String {
        guard let g = git else { return "" }
        var parts: [String] = []
        if let a = g.ahead, a > 0 { parts.append("\(a) ahead") }
        if let b = g.behind, b > 0 { parts.append("\(b) behind") }
        if let c = g.conflicts, c > 0 { parts.append("\(c) conflicted") }
        let changed = (g.staged ?? 0) + (g.unstaged ?? 0)
        if changed > 0 { parts.append("\(changed) changed") }
        if let u = g.untracked, u > 0 { parts.append("\(u) untracked") }
        if let action = g.action, !action.isEmpty { parts.append(action) }
        return parts.isEmpty ? "clean" : parts.joined(separator: " · ")
    }

    /// The share, with how long until it resets when that is known.
    private func limitCell(_ limit: Limit?) -> String {
        guard let limit = limit, limit.percent != nil else { return "—" }
        let reset = until(limit.resets_at)
        return reset.isEmpty ? share(limit.percent) : "\(share(limit.percent)) \(reset)"
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: SessionsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        controller = SessionsWindow()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Without a menu the key equivalents do not exist, so ⌘Q and ⌘C do nothing.
func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "About Agent Bar Hopping",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
        withTitle: "Hide Agent Bar Hopping", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
        withTitle: "Quit Agent Bar Hopping", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
        withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(
        withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    NSApp.mainMenu = main
    NSApp.windowsMenu = windowMenu
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
