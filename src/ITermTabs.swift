import AppKit
import Foundation

// MARK: - Save and restore iTerm tabs across an iTerm restart
//
// docs/restart-iterm-keep-tabs.html is the design. Every clo session runs in the default tmux
// server, which outlives iTerm, and iTerm shows each through `tmux -CC`. Save records every iTerm
// window and its tabs in order; Restore attaches each tmux tab again in that order, and opens a
// shell with notes in place of a plain tab, whose process cannot come back. Restart does Save,
// quits iTerm, waits for the tmux clients to clear and Restores.
//
// The parsing, planning and the order of the steps are pure or run on stand-in steps, so the
// self-test checks them on fixed text with no iTerm and no tmux (`itermTabsProblems`).

let itermBundleId = "com.googlecode.iterm2"

/// One iTerm tab as Save records it.
struct SavedTab: Codable, Equatable {
    /// "tmux" (a `tmux -CC` tab of the default server), "plain" (a shell or program iTerm runs),
    /// or "other" (a tmux tab whose pane the default server does not list).
    var kind: String
    var name: String
    var profile: String
    var session: String?
    var folder: String?
    var command: String?
    /// The file holding this plain tab's notes: what ran and its last screen lines.
    var notes: String?
}

/// One iTerm window as Save records it: its tabs in order.
struct SavedWindow: Codable, Equatable {
    var hotkey: Bool
    var profile: String
    var tabs: [SavedTab]
}

/// The whole record Save writes and Restore reads.
struct SavedTabs: Codable, Equatable {
    var savedAt: String
    var windows: [SavedWindow]
}

/// One tab of the listing script's output, before tmux panes are mapped to sessions.
struct ListedTab: Equatable {
    var pane: String?
    var tty: String
    var profile: String
    var sessionId: String
    var name: String
}

/// One window of the listing script's output.
struct ListedWindow: Equatable {
    var hotkey: Bool
    var tabs: [ListedTab]
}

/// The AppleScript that lists every iTerm window, hotkey window first, and each tab's current
/// session: its tmux pane (`tmuxWindowPane`, empty for a plain tab), tty, profile, unique id and
/// name. One line per window (`W`) and per tab (`T`), fields split by tabs, the name last so a
/// tab inside it cannot shift the other fields. Two passes over `windows`, hotkey then the rest,
/// inline: iTerm cannot hand out a window reference for keeping in a list (`contents of` an item of
/// `windows` fails with -1728), and `tabs of` a window passed to a handler comes back empty. The
/// separators are made outside the `tell`, where `tab` would name iTerm's tab class, not the character.
let itermListingScript = """
    set TB to character id 9
    set LF to character id 10
    tell application id "\(itermBundleId)"
      set out to ""
      repeat with pass from 1 to 2
        repeat with w in windows
          set hk to is hotkey window of w
          if (pass is 1 and hk) or (pass is 2 and not hk) then
            set out to out & "W" & TB & (hk as text) & LF
            repeat with t in tabs of w
              set s to current session of t
              set p to ""
              try
                set p to ((variable named "tmuxWindowPane") of s) as text
              end try
              set out to out & "T" & TB & p & TB & (tty of s) & TB & (profile name of s) & TB & (unique id of s) & TB & (name of s) & LF
            end repeat
          end if
        end repeat
      end repeat
      return out
    end tell
    """

/// The windows and tabs of the listing script's output. A pane that is not a number (unset,
/// `missing value`) is no pane: the tab is plain.
func parseITermListing(_ text: String) -> [ListedWindow] {
    var windows: [ListedWindow] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(raw)
        if line.hasPrefix("W\t") {
            windows.append(ListedWindow(hotkey: line.dropFirst(2).trimmingCharacters(in: .whitespaces) == "true", tabs: []))
        } else if line.hasPrefix("T\t"), !windows.isEmpty {
            let parts = line.dropFirst(2).split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { continue }
            let pane = parts[0].trimmingCharacters(in: .whitespaces)
            windows[windows.count - 1].tabs.append(ListedTab(
                pane: !pane.isEmpty && pane.allSatisfy(\.isNumber) ? pane : nil,
                tty: parts[1], profile: parts[2], sessionId: parts[3], name: parts[4]))
        }
    }
    return windows
}

/// What `list-panes -a -F` prints for `tmuxSessionsByPane(in:)`.
let tmuxPaneSessionFormat = "#{pane_id}\t#{session_name}"

/// The tmux session of each pane, by pane number without its `%`.
func tmuxSessionsByPane(in text: String) -> [String: String] {
    var sessions: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0].hasPrefix("%") { sessions[String(parts[0].dropFirst())] = parts[1] }
    }
    return sessions
}

/// The tmux sessions iTerm shows now, from a listing and the pane map.
func shownTmuxSessions(_ windows: [ListedWindow], panes: [String: String]) -> Set<String> {
    Set(windows.flatMap(\.tabs).compactMap { $0.pane }.compactMap { panes[$0] })
}

/// The foreground process of a tty from `ps -t <tty> -o pid=,stat=,command=`: the last process in
/// the foreground group (`+` in its state) that is not `login`. `shell` is true when it is a shell
/// waiting at its prompt, which has no command worth naming.
func foregroundProcess(in text: String) -> (pid: Int32, command: String, shell: Bool)? {
    var found: (pid: Int32, command: String, shell: Bool)?
    for line in text.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, let pid = Int32(parts[0]), parts[1].contains("+") else { continue }
        let command = parts[2].trimmingCharacters(in: .whitespaces)
        let program = (command.split(separator: " ").first.map(String.init) ?? command)
        if (program as NSString).lastPathComponent == "login" { continue }
        let base = (program.hasPrefix("-") ? String(program.dropFirst()) : (program as NSString).lastPathComponent)
        found = (pid, command, ["zsh", "bash", "fish", "sh", "tcsh", "ksh"].contains(base))
    }
    return found
}

/// The working directory in `lsof -a -p <pid> -d cwd -Fn` output.
func lsofDirectory(in text: String) -> String? {
    text.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
}

/// The notes a plain tab's shell prints when it is opened again: each line a `#` comment.
func plainTabNotes(name: String, command: String?, screen: String, savedAt: String, lines: Int = 40) -> String {
    var screenLines = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
    while let last = screenLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { screenLines.removeLast() }
    var out = "# Tab \"\(name)\", saved \(savedAt) before iTerm2 restarted\n"
    out += "# was running: \(command ?? "nothing (the shell was at its prompt)")\n"
    if !screenLines.isEmpty {
        out += "# its last screen lines:\n"
        out += screenLines.suffix(lines).map { "#   " + $0 }.joined(separator: "\n") + "\n"
    }
    return out
}

/// The record Save writes, from a listing: each tab's pane mapped to its session, and each plain
/// tab given its details by `plain(tab, index)`, which returns its folder, command and notes path.
func savedTabs(_ windows: [ListedWindow], panes: [String: String], savedAt: String,
               plain: (ListedTab, Int) -> (folder: String?, command: String?, notes: String?)) -> SavedTabs {
    var index = 0
    return SavedTabs(savedAt: savedAt, windows: windows.map { window in
        SavedWindow(hotkey: window.hotkey, profile: window.tabs.first?.profile ?? hotkeyProfileName, tabs: window.tabs.map { tab in
            if let pane = tab.pane {
                if let session = panes[pane] { return SavedTab(kind: "tmux", name: tab.name, profile: tab.profile, session: session) }
                return SavedTab(kind: "other", name: tab.name, profile: tab.profile)
            }
            index += 1
            let details = plain(tab, index)
            return SavedTab(kind: "plain", name: tab.name, profile: tab.profile, folder: details.folder, command: details.command, notes: details.notes)
        })
    })
}

/// One step of a restore, in its window's order.
enum RestoreAction: Equatable {
    case attach(session: String, profile: String)
    case shell(folder: String?, notes: String?, profile: String)

    var profile: String {
        switch self {
        case .attach(_, let profile), .shell(_, _, let profile): return profile
        }
    }
}

/// What a restore will do, per window, and what it leaves out with why.
struct RestorePlan: Equatable {
    var windows: [(hotkey: Bool, profile: String, actions: [RestoreAction])]
    var skipped: [String]

    static func == (a: RestorePlan, b: RestorePlan) -> Bool {
        a.skipped == b.skipped && a.windows.count == b.windows.count
            && zip(a.windows, b.windows).allSatisfy { $0.hotkey == $1.hotkey && $0.profile == $1.profile && $0.actions == $1.actions }
    }
}

/// The plan for a record: every tab in its saved order, whatever the record's age. A tmux tab whose
/// session has ended, or that iTerm already shows, is skipped; a tab of another tmux server cannot
/// be found again. A window left with nothing to do is dropped.
func restorePlan(_ saved: SavedTabs, live: Set<String>, shown: Set<String>) -> RestorePlan {
    var skipped: [String] = []
    var windows: [(hotkey: Bool, profile: String, actions: [RestoreAction])] = []
    for window in saved.windows {
        var actions: [RestoreAction] = []
        for tab in window.tabs {
            switch tab.kind {
            case "tmux":
                guard let session = tab.session else { continue }
                if !live.contains(session) { skipped.append("\(session): ended") }
                else if shown.contains(session) { skipped.append("\(session): already shown") }
                else { actions.append(.attach(session: session, profile: tab.profile)) }
            case "plain":
                actions.append(.shell(folder: tab.folder, notes: tab.notes, profile: tab.profile))
            default:
                skipped.append("\(tab.name): a tmux tab of another server")
            }
        }
        if !actions.isEmpty { windows.append((window.hotkey, window.profile, actions)) }
    }
    return RestorePlan(windows: windows, skipped: skipped)
}

/// A shell-quoted word.
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// An AppleScript string literal.
func appleScriptString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The command a restored tab starts with. Screen text never goes into it: a plain tab's notes
/// are read from their file with `cat`.
func restoreCommand(_ action: RestoreAction) -> String {
    switch action {
    case .attach(let session, _):
        return "tmux -CC attach-session -t \(shellQuote("=" + session))"
    case .shell(let folder, let notes, _):
        var command = folder.map { "cd \(shellQuote($0)) 2>/dev/null || cd" } ?? "cd"
        if let notes = notes { command += "; cat \(shellQuote(notes)) 2>/dev/null" }
        return command
    }
}

/// The command iTerm is given for a new tab or window: an interactive login shell runs it, then
/// replaces itself with a plain login shell so the tab outlives it (as `runInNewTab` does).
func tabStartCommand(_ command: String) -> String {
    let shell = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_shell) } ?? "/bin/zsh"
    return "\(shell) -lic \(shellQuote("\(command); exec \(shell) -l"))"
}

/// What a restore does to iTerm, so its order can be checked without one. Window ids are iTerm's.
struct TabRestoreSteps {
    /// The hotkey window's id, made with this profile when there is none.
    var hotkeyWindow: (_ profile: String) -> String?
    /// A new window with this profile, its first tab starting this command; its id.
    var newWindow: (_ profile: String, _ command: String) -> String?
    var selectLastTab: (_ window: String) -> Void
    var newTab: (_ window: String, _ profile: String, _ command: String) -> Bool
    var shownSessions: () -> Set<String>
    var pause: (Double) -> Void
    var log: (String) -> Void
    var report: (String, Double) -> Void
    var waitSeconds = 20
}

/// Opens every planned tab in order. Before each new tab the window's last tab is selected, since
/// iTerm puts a new tab after the current one; an attach waits until iTerm shows its session before
/// the next tab, so tmux tabs, which iTerm appends at the end, keep their saved order.
@discardableResult
func runTabRestore(_ plan: RestorePlan, _ steps: TabRestoreSteps) -> String {
    var opened = 0
    var notShown: [String] = []
    var failed: [String] = []
    func waitShown(_ action: RestoreAction) {
        guard case .attach(let session, _) = action else { steps.pause(0.5); return }
        for _ in 0..<max(1, steps.waitSeconds * 2) {
            if steps.shownSessions().contains(session) { return }
            steps.pause(0.5)
        }
        notShown.append(session)
        steps.log("\(session): no tab after \(steps.waitSeconds) s")
    }
    let total = plan.windows.reduce(0) { $0 + $1.actions.count }
    steps.report("Restoring \(total) iTerm tab\(total == 1 ? "" : "s")", 60)
    for window in plan.windows {
        var id: String?
        var rest = window.actions[...]
        if window.hotkey {
            id = steps.hotkeyWindow(window.profile)
        } else if let first = rest.first {
            id = steps.newWindow(first.profile, restoreCommand(first))
            if id != nil { rest = rest.dropFirst(); opened += 1; waitShown(first) }
        }
        guard let window = id else {
            failed.append("a \(window.hotkey ? "hotkey" : "normal") window could not be made")
            steps.log("restore: window could not be made; \(window.actions.count) tabs not opened")
            continue
        }
        for action in rest {
            steps.selectLastTab(window)
            if steps.newTab(window, action.profile, restoreCommand(action)) {
                opened += 1
                waitShown(action)
            } else {
                failed.append(restoreCommand(action))
            }
        }
    }
    var message = "Restored \(opened) of \(total) iTerm tab\(total == 1 ? "" : "s")"
    if !notShown.isEmpty { message += "; no tab appeared for " + notShown.joined(separator: ", ") }
    if !failed.isEmpty { message += "; not opened: " + failed.joined(separator: "; ") }
    if !plan.skipped.isEmpty { message += "; skipped " + plan.skipped.joined(separator: ", ") }
    steps.log("restore: \(message)")
    steps.report(message, 30)
    return message
}

/// iTerm's answer to a quit request.
enum QuitAnswer { case quitting, cancelled, noAnswer }

/// What a restart of iTerm does to the outside world, so its order can be checked without any.
struct ITermRestartSteps {
    var itermPid: () -> pid_t?
    var requestQuit: () -> QuitAnswer
    var tmuxClients: () -> Int
    var liveSessions: () -> Set<String>
    var launchITerm: () -> Void
    var itermAnswers: () -> Bool
    var restore: () -> String
    var pause: (Double) -> Void
    var log: (String) -> Void
    var report: (String, Double) -> Void
    var exitWaitSeconds = 30
    var clientWaitSeconds = 15
    var launchWaitSeconds = 60
}

/// Quits iTerm, waits for that copy to exit and for tmux to drop its clients, checks the saved
/// sessions still run, then restores into iTerm: the one a session's hook may have launched again
/// meanwhile, or one opened here. Nothing is restored after a cancelled quit or a lost tmux server.
@discardableResult
func runITermRestart(sessions: Set<String>, _ steps: ITermRestartSteps) -> String {
    func stop(_ message: String) -> String { steps.log("restart-iterm: \(message)"); steps.report(message, 30); return message }
    if let old = steps.itermPid() {
        steps.report("Quitting iTerm2; answer its prompt if it asks", 120)
        let answer = steps.requestQuit()
        steps.log("restart-iterm: quit answered \(answer)")
        if answer == .cancelled { return stop("iTerm2's quit was cancelled; nothing was restored") }
        var gone = false
        for _ in 0..<max(1, steps.exitWaitSeconds * 2) where !gone {
            gone = steps.itermPid() != old
            if !gone { steps.pause(0.5) }
        }
        if !gone { return stop("iTerm2 did not quit\(answer == .noAnswer ? " (its quit prompt is still open?)" : ""); nothing was restored") }
    }
    var clear = false
    for _ in 0..<max(1, steps.clientWaitSeconds * 2) where !clear {
        clear = steps.tmuxClients() == 0
        if !clear { steps.pause(0.5) }
    }
    if !clear { steps.log("restart-iterm: tmux still has clients after \(steps.clientWaitSeconds) s (another terminal?); restoring anyway") }
    let live = steps.liveSessions()
    if !sessions.isEmpty && sessions.isDisjoint(with: live) {
        return stop("None of the saved tmux sessions is running: the tmux server is gone, so nothing was restored")
    }
    if steps.itermPid() == nil { steps.log("restart-iterm: opening iTerm2"); steps.launchITerm() }
    else { steps.log("restart-iterm: iTerm2 was opened again meanwhile; restoring into it") }
    var answers = false
    for _ in 0..<max(1, steps.launchWaitSeconds) where !answers {
        answers = steps.itermPid() != nil && steps.itermAnswers()
        if !answers { steps.pause(1) }
    }
    if !answers { return stop("iTerm2 did not answer after reopening; run Restore iTerm Tabs once it is up") }
    return steps.restore()
}

// MARK: Live steps

/// Where Save writes its record, and the folder of the plain tabs' notes.
let savedTabsFolder = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/CC Sessions")
let savedTabsPath = (savedTabsFolder as NSString).appendingPathComponent("iterm-tabs.json")
let savedTabNotesFolder = (savedTabsFolder as NSString).appendingPathComponent("iterm-tabs")

/// A command's standard output, or "" when it fails.
func commandOutput(_ path: String, _ arguments: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return "" }
    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    task.waitUntilExit()
    return String(data: data ?? Data(), encoding: .utf8) ?? ""
}

/// The pid of the running iTerm, nil when none runs.
func runningITermPid() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: itermBundleId).first { !$0.isTerminated }?.processIdentifier
}

/// The iTerm listing, or nil when iTerm does not run or does not answer. Never launches iTerm.
func currentITermListing() -> [ListedWindow]? {
    guard runningITermPid() != nil else { return nil }
    let text = runScript(itermListingScript, label: "iterm tabs: list")
    return text.isEmpty ? nil : parseITermListing(text)
}

/// A session's visible text, unlogged: it can hold secrets.
func itermSessionContents(_ uniqueId: String) -> String {
    let script = """
        tell application id "\(itermBundleId)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if unique id of s is \(appleScriptString(uniqueId)) then return contents of s
              end repeat
            end repeat
          end repeat
          return ""
        end tell
        """
    return runScript(script, label: "iterm tabs: screen of a plain tab", logOutput: false)
}

/// Saves every iTerm window and tab in order; returns the report line, or the reason it could not.
func saveITermTabs() -> (record: SavedTabs?, message: String) {
    guard runningITermPid() != nil else { return (nil, "iTerm2 is not running: nothing saved") }
    guard let windows = currentITermListing(), !windows.isEmpty, windows.contains(where: { !$0.tabs.isEmpty }) else {
        return (nil, "Could not read iTerm2's tabs: its AppleScript failed or listed none (cc-sessions.log has what it returned). Nothing was saved and iTerm2 was left running")
    }
    let panes = tmuxSessionsByPane(in: tmuxOutput(["list-panes", "-a", "-F", tmuxPaneSessionFormat]) ?? "")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    try? fm.createDirectory(atPath: savedTabNotesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for old in (try? fm.contentsOfDirectory(atPath: savedTabNotesFolder)) ?? [] where old.hasSuffix(".txt") {
        try? fm.removeItem(atPath: (savedTabNotesFolder as NSString).appendingPathComponent(old))
    }
    let record = savedTabs(windows, panes: panes, savedAt: savedAt) { tab, index in
        let tty = (tab.tty as NSString).lastPathComponent
        let process = foregroundProcess(in: commandOutput("/bin/ps", ["-t", tty, "-o", "pid=,stat=,command="]))
        let folder = process.flatMap { lsofDirectory(in: commandOutput("/usr/sbin/lsof", ["-a", "-p", String($0.pid), "-d", "cwd", "-Fn"])) }
        let command = process.flatMap { $0.shell ? nil : $0.command }
        let notes = (savedTabNotesFolder as NSString).appendingPathComponent("tab-\(index).txt")
        let text = plainTabNotes(name: tab.name, command: command, screen: itermSessionContents(tab.sessionId), savedAt: savedAt)
        let written = fm.createFile(atPath: notes, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        return (folder, command, written ? notes : nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(record), fm.createFile(atPath: savedTabsPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
        return (nil, "Could not write \(savedTabsPath)")
    }
    let tabs = record.windows.flatMap(\.tabs)
    let tmux = tabs.filter { $0.kind == "tmux" }.count, plain = tabs.filter { $0.kind == "plain" }.count, other = tabs.count - tmux - plain
    var message = "Saved \(tmux) tmux tab\(tmux == 1 ? "" : "s") and \(plain) plain tab\(plain == 1 ? "" : "s") in \(record.windows.count) window\(record.windows.count == 1 ? "" : "s")"
    if other > 0 { message += "; \(other) tmux tab\(other == 1 ? "" : "s") of another server cannot be restored" }
    log("iterm tabs: \(message)")
    return (record, message)
}

/// The saved record, nil when there is none or it does not read.
func loadSavedITermTabs() -> SavedTabs? {
    fm.contents(atPath: savedTabsPath).flatMap { try? JSONDecoder().decode(SavedTabs.self, from: $0) }
}

/// The tmux sessions iTerm shows now.
func liveShownTmuxSessions() -> Set<String> {
    let panes = tmuxSessionsByPane(in: tmuxOutput(["list-panes", "-a", "-F", tmuxPaneSessionFormat]) ?? "")
    return shownTmuxSessions(currentITermListing() ?? [], panes: panes)
}

/// The tmux sessions running now.
func liveTmuxSessions() -> Set<String> {
    Set((tmuxOutput(["list-sessions", "-F", "#{session_name}"]) ?? "").split(separator: "\n").map(String.init))
}

/// The restore steps that drive the real iTerm.
func liveTabRestoreSteps(report: @escaping (String, Double) -> Void) -> TabRestoreSteps {
    TabRestoreSteps(
        hotkeyWindow: { profile in
            let script = """
                tell application id "\(itermBundleId)"
                  repeat with w in windows
                    if is hotkey window of w then return (id of w) as text
                  end repeat
                  try
                    set w to (create hotkey window with profile \(appleScriptString(profile)))
                    return (id of w) as text
                  end try
                  return ""
                end tell
                """
            let id = runScript(script, label: "iterm tabs: hotkey window")
            return id.isEmpty ? nil : id
        },
        newWindow: { profile, command in
            let script = """
                tell application id "\(itermBundleId)"
                  set w to (create window with profile \(appleScriptString(profile)) command \(appleScriptString(tabStartCommand(command))))
                  return (id of w) as text
                end tell
                """
            let id = runScript(script, label: "iterm tabs: new window")
            return id.isEmpty ? nil : id
        },
        selectLastTab: { window in
            runScript("tell application id \"\(itermBundleId)\" to tell window id \(window) to select last tab", label: "iterm tabs: select last tab")
        },
        newTab: { window, profile, command in
            let script = """
                tell application id "\(itermBundleId)"
                  tell window id \(window) to create tab with profile \(appleScriptString(profile)) command \(appleScriptString(tabStartCommand(command)))
                  return "ok"
                end tell
                """
            return runScript(script, label: "iterm tabs: new tab") == "ok"
        },
        shownSessions: { liveShownTmuxSessions() },
        pause: { usleep(UInt32($0 * 1_000_000)) },
        log: { log("iterm tabs: \($0)") },
        report: report)
}

/// Restores the saved record into the running iTerm; returns the report line.
func restoreITermTabs(report: @escaping (String, Double) -> Void) -> String {
    guard let saved = loadSavedITermTabs() else { return "No saved iTerm tabs: choose Save iTerm Tabs first" }
    guard runningITermPid() != nil else { return "iTerm2 is not running: open it, then Restore iTerm Tabs" }
    let plan = restorePlan(saved, live: liveTmuxSessions(), shown: liveShownTmuxSessions())
    let message = runTabRestore(plan, liveTabRestoreSteps(report: report))
    if plan.windows.contains(where: \.hotkey) {
        let reveal = """
            tell application id "\(itermBundleId)"
              repeat with w in windows
                if is hotkey window of w then
                  reveal hotkey window
                  exit repeat
                end if
              end repeat
            end tell
            """
        runScript(reveal, label: "iterm tabs: reveal hotkey window")
    }
    return message
}

/// The restart steps that drive the real iTerm and tmux.
func liveITermRestartSteps(report: @escaping (String, Double) -> Void) -> ITermRestartSteps {
    ITermRestartSteps(
        itermPid: { runningITermPid() },
        requestQuit: {
            // The quit waits on iTerm's own prompt, which the owner answers; -128 is a Cancel,
            // -1712 a prompt left open past the limit.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "with timeout of 600 seconds\ntell application id \"\(itermBundleId)\" to quit\nend timeout"]
            let err = Pipe()
            task.standardOutput = FileHandle.nullDevice
            task.standardError = err
            guard (try? task.run()) != nil else { return .noAnswer }
            let stderr = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
            task.waitUntilExit()
            log("restart-iterm: quit exit \(task.terminationStatus) err=\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            if stderr.contains("-128") { return .cancelled }
            if stderr.contains("-1712") { return .noAnswer }
            return .quitting
        },
        tmuxClients: { (tmuxOutput(["list-clients", "-F", "#{client_tty}"]) ?? "").split(separator: "\n").count },
        liveSessions: { liveTmuxSessions() },
        launchITerm: { _ = commandOutput("/usr/bin/open", ["-a", "iTerm"]) },
        itermAnswers: { !runScript("tell application id \"\(itermBundleId)\" to (count of windows) as text", label: "restart-iterm: answers").isEmpty },
        restore: { restoreITermTabs(report: report) },
        pause: { usleep(UInt32($0 * 1_000_000)) },
        log: { log($0) },
        report: report)
}

// MARK: Self-test

/// The checks of Save's parsing, the restore plan and the order of restore and restart steps,
/// on fixed text and stand-in steps: nothing here reaches iTerm or tmux.
func itermTabsProblems() -> [String] {
    var problems: [String] = []
    let listing = """
        W\ttrue
        T\t20\t\tHotkey Window\tA1\tclaude
        T\t\t/dev/ttys012\tHotkey Window\tA2\tmas (mas)
        T\tmissing value\t/dev/ttys013\tHotkey Window\tA3\tname\twith a tab
        T\t23\t\tHotkey Window\tA4\tother claude
        T\t99\t\tHotkey Window\tA5\tforeign
        W\tfalse
        T\t26\t\tDefault\tB1\tbuild

        """
    let windows = parseITermListing(listing)
    if windows.count != 2 || windows[0].tabs.count != 5 || windows[1].tabs.count != 1 || !windows[0].hotkey || windows[1].hotkey {
        problems.append("iTerm listing was read as \(windows)")
    }
    if windows.first?.tabs[2].pane != nil || windows.first?.tabs[2].name != "name\twith a tab" { problems.append("an unset pane or a tab in a name was misread: \(String(describing: windows.first?.tabs[2]))") }
    let panes = tmuxSessionsByPane(in: "%20\tproj-a\n%23\tproj-b\n%26\tproj-c\nbroken\n")
    if panes != ["20": "proj-a", "23": "proj-b", "26": "proj-c"] { problems.append("pane sessions were read as \(panes)") }
    if shownTmuxSessions(windows, panes: panes) != ["proj-a", "proj-b", "proj-c"] { problems.append("shown sessions were \(shownTmuxSessions(windows, panes: panes))") }
    let ps = """
          501 Ss   /usr/bin/login -fpl someone /Applications/iTerm.app/Contents/MacOS/ShellLauncher
          502 S    -zsh
          530 S+   sudo mas install 497799835
          531 S+   mas install 497799835
        """
    if foregroundProcess(in: ps)?.command != "mas install 497799835" || foregroundProcess(in: ps)?.shell != false { problems.append("the foreground process was \(String(describing: foregroundProcess(in: ps)))") }
    if foregroundProcess(in: "  502 Ss+  -zsh\n")?.shell != true { problems.append("a shell at its prompt was not seen as one") }
    if lsofDirectory(in: "p531\nfcwd\nn/Users/someone/dev\n") != "/Users/someone/dev" { problems.append("lsof's directory was not read") }
    let notes = plainTabNotes(name: "mas", command: "mas install 1", screen: "line one\nline 'two'\n\n\n", savedAt: "T")
    if !notes.contains("# was running: mas install 1") || !notes.contains("#   line 'two'") || notes.hasSuffix("#   \n") {
        problems.append("plain tab notes were \(notes)")
    }
    if !plainTabNotes(name: "x", command: nil, screen: "", savedAt: "T").contains("nothing (the shell was at its prompt)") { problems.append("an idle shell's notes did not say so") }
    let record = savedTabs(windows, panes: panes, savedAt: "T") { _, i in ("/dir\(i)", i == 1 ? "mas install 1" : nil, "/notes/tab-\(i).txt") }
    let kinds = record.windows.flatMap(\.tabs).map(\.kind)
    if kinds != ["tmux", "plain", "plain", "tmux", "other", "tmux"] { problems.append("saved tab kinds were \(kinds)") }
    if record.windows[0].tabs[1].folder != "/dir1" || record.windows[0].tabs[2].notes != "/notes/tab-2.txt" || record.windows[1].profile != "Default" {
        problems.append("plain tab details or window profile were not saved: \(record)")
    }
    if let data = try? JSONEncoder().encode(record), (try? JSONDecoder().decode(SavedTabs.self, from: data)) != record { problems.append("the record did not survive a round trip") }

    // An old record is used whatever its age; ended and shown sessions are skipped, foreign tabs reported.
    let plan = restorePlan(SavedTabs(savedAt: "2001-01-01T00:00:00Z", windows: record.windows), live: ["proj-a", "proj-c"], shown: ["proj-c"])
    let wantFirst: [RestoreAction] = [.attach(session: "proj-a", profile: "Hotkey Window"),
                                      .shell(folder: "/dir1", notes: "/notes/tab-1.txt", profile: "Hotkey Window"),
                                      .shell(folder: "/dir2", notes: "/notes/tab-2.txt", profile: "Hotkey Window")]
    if plan.windows.count != 1 || plan.windows[0].actions != wantFirst || !plan.windows[0].hotkey {
        problems.append("restore plan was \(plan.windows)")
    }
    if plan.skipped != ["proj-b: ended", "foreign: a tmux tab of another server", "proj-c: already shown"] { problems.append("restore skipped \(plan.skipped)") }
    if restoreCommand(.attach(session: "a'b", profile: "")) != "tmux -CC attach-session -t '=a'\\''b'" { problems.append("attach command was \(restoreCommand(.attach(session: "a'b", profile: "")))") }
    if restoreCommand(.shell(folder: "/x y", notes: "/n.txt", profile: "")) != "cd '/x y' 2>/dev/null || cd; cat '/n.txt' 2>/dev/null" {
        problems.append("plain tab command was \(restoreCommand(.shell(folder: "/x y", notes: "/n.txt", profile: "")))")
    }
    if appleScriptString("a\"b\\c") != "\"a\\\"b\\\\c\"" { problems.append("AppleScript string was \(appleScriptString("a\"b\\c"))") }

    // Restore order: the last tab is selected before every new tab, an attach waits for its tab,
    // a normal window starts with its first tab's command.
    func restore(_ plan: RestorePlan, showAfter: Int?) -> (calls: [String], result: String) {
        var calls: [String] = [], polls = 0, opened: Set<String> = []
        let steps = TabRestoreSteps(
            hotkeyWindow: { calls.append("hotkey \($0)"); return "1" },
            newWindow: { profile, command in calls.append("window \(profile): \(command)"); if command.hasPrefix("tmux") { opened.insert(command) }; return "2" },
            selectLastTab: { calls.append("select \($0)") },
            newTab: { window, _, command in calls.append("tab \(window): \(command)"); if command.hasPrefix("tmux") { opened.insert(command) }; return true },
            shownSessions: {
                polls += 1
                guard let after = showAfter, polls >= after else { return [] }
                return Set(opened.compactMap { $0.components(separatedBy: "'=").last?.replacingOccurrences(of: "'", with: "") })
            },
            pause: { _ in }, log: { _ in }, report: { _, _ in }, waitSeconds: 2)
        let result = runTabRestore(plan, steps)
        return (calls, result)
    }
    let two = RestorePlan(windows: [
        (true, "H", [.attach(session: "a", profile: "H"), .shell(folder: "/d", notes: nil, profile: "H")]),
        (false, "D", [.attach(session: "c", profile: "D"), .attach(session: "e", profile: "D")])], skipped: [])
    let ordered = restore(two, showAfter: 1)
    let want = ["hotkey H", "select 1", "tab 1: tmux -CC attach-session -t '=a'", "select 1", "tab 1: cd '/d' 2>/dev/null || cd",
                "window D: tmux -CC attach-session -t '=c'", "select 2", "tab 2: tmux -CC attach-session -t '=e'"]
    if ordered.calls != want { problems.append("restore order was \(ordered.calls)") }
    if !ordered.result.hasPrefix("Restored 4 of 4") { problems.append("a full restore reported \(ordered.result)") }
    let never = restore(RestorePlan(windows: [(true, "H", [.attach(session: "a", profile: "H")])], skipped: ["b: ended"]), showAfter: nil)
    if !never.result.contains("no tab appeared for a") || !never.result.contains("skipped b: ended") { problems.append("a tab that never appeared was reported as \(never.result)") }

    // Restart: a cancelled quit restores nothing; a lost server restores nothing; an iTerm opened
    // again by a hook is used, not opened twice; tmux clients are waited for.
    func restart(quit: QuitAnswer, exits: Bool, relaunchedByHook: Bool, live: Set<String>, clientsAfter: Int) -> (calls: [String], result: String) {
        var calls: [String] = [], pid: pid_t? = 100, clientPolls = 0
        let steps = ITermRestartSteps(
            itermPid: { pid },
            requestQuit: { calls.append("quit"); if quit == .quitting && exits { pid = relaunchedByHook ? 200 : nil }; return quit },
            tmuxClients: { clientPolls += 1; calls.append("clients"); return clientPolls >= clientsAfter ? 0 : 1 },
            liveSessions: { live },
            launchITerm: { calls.append("launch"); pid = 300 },
            itermAnswers: { true },
            restore: { calls.append("restore"); return "restored" },
            pause: { _ in }, log: { _ in }, report: { _, _ in }, exitWaitSeconds: 1, clientWaitSeconds: 2, launchWaitSeconds: 2)
        let result = runITermRestart(sessions: ["a", "b"], steps)
        return (calls, result)
    }
    let normal = restart(quit: .quitting, exits: true, relaunchedByHook: false, live: ["a", "b"], clientsAfter: 2)
    if normal.calls != ["quit", "clients", "clients", "launch", "restore"] { problems.append("iTerm restart order was \(normal.calls)") }
    let hook = restart(quit: .quitting, exits: true, relaunchedByHook: true, live: ["a"], clientsAfter: 1)
    if hook.calls.contains("launch") || !hook.calls.contains("restore") { problems.append("an iTerm opened again by a hook was not reused: \(hook.calls)") }
    let cancelled = restart(quit: .cancelled, exits: false, relaunchedByHook: false, live: ["a", "b"], clientsAfter: 1)
    if cancelled.calls != ["quit"] || !cancelled.result.contains("cancelled") { problems.append("a cancelled quit went on: \(cancelled.calls)") }
    let stuck = restart(quit: .noAnswer, exits: false, relaunchedByHook: false, live: ["a", "b"], clientsAfter: 1)
    if stuck.calls.contains("restore") || !stuck.result.contains("did not quit") { problems.append("an iTerm that did not quit was restored into: \(stuck.calls)") }
    let lost = restart(quit: .quitting, exits: true, relaunchedByHook: false, live: [], clientsAfter: 1)
    if lost.calls.contains("restore") || lost.calls.contains("launch") || !lost.result.contains("tmux server is gone") { problems.append("a lost tmux server still restored: \(lost.calls)") }
    return problems
}
