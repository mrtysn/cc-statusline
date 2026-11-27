import AppKit
import Foundation

// MARK: - Save and restore iTerm tabs across an iTerm restart
//
// docs/restart-iterm-keep-tabs.html is the design. Every clo session runs in the default tmux
// server, and iTerm shows each through `tmux -CC`. Save records every iTerm window and its tabs in
// order, and for each tmux tab the Claude session it holds. Restore attaches a tab whose tmux
// session still runs (after an iTerm restart), resumes the Claude session of one that has ended
// (after a reboot or a lost tmux server) in the same position, and opens a shell with notes in
// place of a plain tab, whose process cannot come back. Restart does Save, quits iTerm, waits for
// the tmux clients to clear and Restores. The app also saves on its own when the tabs change.
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
    /// The Claude session a tmux tab held, nil for a tmux tab with none.
    var claude: SavedClaude? = nil
}

/// What a resume of a tab's Claude session needs, and the name it is reported by.
struct SavedClaude: Codable, Equatable {
    var id: String
    /// The folder it was launched in, which is where it resumes.
    var dir: String
    var cwd: String? = nil
    var model: String? = nil
    var effort: String? = nil
    var mode: String? = nil
    var name: String? = nil
    /// False for a session that never had a prompt: it has no transcript to resume.
    var prompted: Bool = true
}

/// One run of the machine: a reboot, a new tmux server or a new iTerm starts another.
struct TabGeneration: Equatable {
    /// The boot session's id (`kern.bootsessionuuid`): the boot time moves when the clock is set.
    var boot: String?
    var server: Int?
    var iterm: Int?
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
    var boot: String? = nil
    var server: Int? = nil
    var iterm: Int? = nil
    /// Restored in full: an automatic save may replace it.
    var released: Bool? = nil

    var generation: TabGeneration {
        get { TabGeneration(boot: boot, server: server, iterm: iterm) }
        set { boot = newValue.boot; server = newValue.server; iterm = newValue.iterm }
    }
    var tabs: [SavedTab] { windows.flatMap(\.tabs) }
    var hasClaudeTab: Bool { tabs.contains { $0.claude?.prompted == true } }
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
    if not (application id "\(itermBundleId)" is running) then return ""
    tell application id "\(itermBundleId)"
      -- A first line of its own, so no windows reads apart from a failed script.
      set out to "L" & LF
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
    var out = "# Tab \"\(name)\", saved \(savedAt) by CC Sessions\n"
    out += "# was running: \(command ?? "nothing (the shell was at its prompt)")\n"
    if !screenLines.isEmpty {
        out += "# its last screen lines:\n"
        out += screenLines.suffix(lines).map { "#   " + $0 }.joined(separator: "\n") + "\n"
    }
    return out
}

/// The record Save writes, from a listing: each tab's pane mapped to its session, with the Claude
/// session and folder known for it, and each plain tab given its details by `plain(tab, index)`,
/// which returns its folder, command and notes path.
func savedTabs(_ windows: [ListedWindow], panes: [String: String], savedAt: String,
               claude: [String: SavedClaude] = [:], folders: [String: String] = [:],
               plain: (ListedTab, Int) -> (folder: String?, command: String?, notes: String?)) -> SavedTabs {
    var index = 0
    return SavedTabs(savedAt: savedAt, windows: windows.map { window in
        SavedWindow(hotkey: window.hotkey, profile: window.tabs.first?.profile ?? hotkeyProfileName, tabs: window.tabs.map { tab in
            if let pane = tab.pane {
                if let session = panes[pane] {
                    return SavedTab(kind: "tmux", name: tab.name, profile: tab.profile, session: session, folder: folders[session], claude: claude[session])
                }
                return SavedTab(kind: "other", name: tab.name, profile: tab.profile)
            }
            index += 1
            let details = plain(tab, index)
            return SavedTab(kind: "plain", name: tab.name, profile: tab.profile, folder: details.folder, command: details.command, notes: details.notes)
        })
    })
}

/// One Claude session as the list knows it, live or finished.
struct SeenSession {
    var claude: SavedClaude
    var tty: String?
    var live: Bool
}

/// clo's record of what a tmux session held (`hooks/record-clo-session.zsh` in agents-shared).
struct CloRecord: Equatable {
    var id: String
    var folder: String
}

/// A record file's line: the Claude session id, a tab, the folder.
func parseCloRecord(_ text: String) -> CloRecord? {
    let parts = (text.split(separator: "\n").first.map(String.init) ?? "").split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    return CloRecord(id: parts[0], folder: parts[1])
}

/// The Claude session of each tmux session: the live one on one of its panes' ttys, else what
/// clo recorded for its name.
func claudeByTmuxSession(_ sessionsByTty: [String: String], seen: [SeenSession], clo: [String: CloRecord]) -> [String: SavedClaude] {
    var byId: [String: SavedClaude] = [:]
    for s in seen { byId[s.claude.id] = byId[s.claude.id] ?? s.claude }
    var result: [String: SavedClaude] = [:]
    for s in seen where s.live {
        if let tty = s.tty, let session = sessionsByTty[tty] { result[session] = s.claude }
    }
    for session in Set(sessionsByTty.values) where result[session] == nil {
        if let record = clo[session] { result[session] = byId[record.id] ?? SavedClaude(id: record.id, dir: record.folder) }
    }
    return result
}

/// The Claude session a saved tmux tab should bring back. clo's record comes first, since it
/// follows a `/clear` or a resume made after the save; a record of the same name from another
/// folder belongs to some other session. The details come from the save, else from the list.
func wantedClaude(_ tab: SavedTab, clo: [String: CloRecord], known: [String: SavedClaude]) -> SavedClaude? {
    let saved = tab.claude
    let record = tab.session.flatMap { clo[$0] }.flatMap { record -> CloRecord? in
        guard let saved = saved else { return record }
        return record.id == saved.id || record.folder == saved.dir || record.folder == saved.cwd ? record : nil
    }
    guard let id = record?.id ?? saved?.id else { return nil }
    if let saved = saved, saved.id == id { return saved }
    if let found = known[id] { return found }
    if var moved = saved { moved.id = id; moved.prompted = true; return moved }
    return record.map { SavedClaude(id: id, dir: $0.folder) }
}

/// One step of a restore, in its window's order.
enum RestoreAction: Equatable {
    case attach(session: String, profile: String)
    /// A Claude session whose tmux session ended: resumed in a tab at its position.
    case resume(SavedClaude, profile: String)
    case shell(folder: String?, notes: String?, profile: String)
    /// A tmux tab nothing can bring back: a shell in its folder that says why.
    case placeholder(session: String, folder: String?, why: String, profile: String)

    var profile: String {
        switch self {
        case .attach(_, let profile), .resume(_, let profile), .shell(_, _, let profile), .placeholder(_, _, _, let profile): return profile
        }
    }

    /// The tab's line in the plan and the result.
    var label: String {
        switch self {
        case .attach(let session, _): return session
        case .resume(let claude, _): return claude.name ?? String(claude.id.prefix(8))
        case .shell(let folder, _, _): return "plain tab in " + ((folder ?? "~") as NSString).abbreviatingWithTildeInPath
        case .placeholder(let session, _, let why, _): return "\(session) (\(why))"
        }
    }
}

/// What a restore will do, per window, and what it leaves out with why.
struct RestorePlan: Equatable {
    var windows: [(hotkey: Bool, profile: String, actions: [RestoreAction])]
    var skipped: [String]

    var actions: [RestoreAction] { windows.flatMap(\.actions) }

    static func == (a: RestorePlan, b: RestorePlan) -> Bool {
        a.skipped == b.skipped && a.windows.count == b.windows.count
            && zip(a.windows, b.windows).allSatisfy { $0.hotkey == $1.hotkey && $0.profile == $1.profile && $0.actions == $1.actions }
    }
}

/// What is running now, as a restore sees it.
struct RestoreWorld {
    /// The tmux sessions running now, and those iTerm shows.
    var live: Set<String> = []
    var shown: Set<String> = []
    /// Whether the tmux server is the one the record was saved from: only then does a name mean
    /// the same session.
    var sameServer = false
    /// The Claude session id each running tmux session holds.
    var idOfSession: [String: String] = [:]
    /// Each running Claude session id's tmux session, "" when it runs outside tmux.
    var running: [String: String] = [:]
    var clo: [String: CloRecord] = [:]
    /// Every session the list knows, by id.
    var known: [String: SavedClaude] = [:]
}

/// The world from what the list, tmux, clo and iTerm say.
func restoreWorld(_ record: SavedTabs, now: TabGeneration, live: Set<String>, shown: Set<String>,
                  sessionsByTty: [String: String], seen: [SeenSession], clo: [String: CloRecord]) -> RestoreWorld {
    var world = RestoreWorld(live: live, shown: shown, sameServer: record.server != nil && record.server == now.server && record.boot == now.boot, clo: clo)
    for s in seen { world.known[s.claude.id] = world.known[s.claude.id] ?? s.claude }
    for session in live {
        if let record = clo[session] { world.idOfSession[session] = record.id; world.running[record.id] = session }
    }
    for s in seen where s.live {
        let session = s.tty.flatMap { sessionsByTty[$0] }
        if let session = session { world.idOfSession[session] = s.claude.id }
        world.running[s.claude.id] = session ?? ""
    }
    return world
}

/// The plan for a record: every tab in its saved order, whatever the record's age. A tab iTerm
/// already shows is skipped; one whose tmux session runs is attached; one that ended has its
/// Claude session resumed, or attached where it runs now; a tab of another tmux server cannot be
/// found again. A window left with nothing to do is dropped.
func restorePlan(_ saved: SavedTabs, _ world: RestoreWorld) -> RestorePlan {
    var skipped: [String] = []
    var windows: [(hotkey: Bool, profile: String, actions: [RestoreAction])] = []
    var planned: Set<String> = []
    for window in saved.windows {
        var actions: [RestoreAction] = []
        func attach(_ session: String, _ profile: String) {
            if world.shown.contains(session) || planned.contains(session) { skipped.append("\(session): already shown"); return }
            planned.insert(session)
            actions.append(.attach(session: session, profile: profile))
        }
        for tab in window.tabs {
            switch tab.kind {
            case "tmux":
                guard let session = tab.session else { continue }
                let wanted = wantedClaude(tab, clo: world.clo, known: world.known)
                // A running session of this name is the saved one on the same server, or when it holds the same Claude session.
                if world.live.contains(session), world.sameServer || wanted == nil || world.idOfSession[session] == wanted?.id {
                    attach(session, tab.profile)
                    continue
                }
                guard let claude = wanted else {
                    actions.append(.placeholder(session: session, folder: tab.folder, why: "ended; it held no Claude session", profile: tab.profile))
                    continue
                }
                if let now = world.running[claude.id] {
                    if now.isEmpty { skipped.append("\(claude.name ?? session): already running outside tmux") } else { attach(now, tab.profile) }
                } else if planned.contains(claude.id) {
                    skipped.append("\(claude.name ?? session): already in the plan")
                } else if !claude.prompted {
                    actions.append(.placeholder(session: session, folder: claude.dir, why: "never had a prompt, so there is nothing to resume", profile: tab.profile))
                } else {
                    planned.insert(claude.id)
                    actions.append(.resume(claude, profile: tab.profile))
                }
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

/// What the owner is told before a restore: the counts, then a line per tab.
func restorePreview(_ plan: RestorePlan) -> (counts: String, lines: [String]) {
    var resumed = 0, attached = 0, plain = 0, lost = 0
    var lines: [String] = []
    for action in plan.actions {
        switch action {
        case .resume: resumed += 1; lines.append("resume: \(action.label)")
        case .attach: attached += 1; lines.append("reattach: \(action.label)")
        case .shell: plain += 1; lines.append("new shell: \(action.label)")
        case .placeholder: lost += 1; lines.append("cannot return: \(action.label)")
        }
    }
    lost += plan.skipped.filter { $0.hasSuffix("another server") }.count
    lines += plan.skipped.map { "skipped: \($0)" }
    var counts = "\(resumed) session\(resumed == 1 ? "" : "s") will be resumed, \(attached) reattached, \(lost) cannot return"
    if plain > 0 { counts += "; \(plain) plain tab\(plain == 1 ? "" : "s") come\(plain == 1 ? "s" : "") back as a shell" }
    return (counts + ".", lines)
}

/// A shell-quoted word.
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// An AppleScript string literal.
func appleScriptString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Attaches a tab to tmux session `session` through `clo --attach` where clo is installed: once
/// the session ends, the tab keeps "closed <name> · <session id> · <folder>" above a shell. Plain
/// `tmux -CC attach-session` otherwise. `command` skips the shell function `clo --init zsh` defines.
func attachShellCommand(_ session: String) -> String {
    "if command -v clo >/dev/null; then command clo --attach \(shellQuote(session)); else tmux -CC attach-session -t \(shellQuote("=" + session)); fi"
}

/// The command a restored tab starts with. Screen text never goes into it: a plain tab's notes
/// are read from their file with `cat`.
func restoreCommand(_ action: RestoreAction) -> String {
    func enter(_ folder: String?) -> String { folder.map { "cd \(shellQuote($0)) 2>/dev/null || cd" } ?? "cd" }
    switch action {
    case .attach(let session, _):
        return attachShellCommand(session)
    case .resume(let claude, _):
        return resumeCommand(id: claude.id, dir: claude.dir, model: claude.model, effort: claude.effort, mode: claude.mode)
    case .shell(let folder, let notes, _):
        var command = enter(folder)
        if let notes = notes { command += "; cat \(shellQuote(notes)) 2>/dev/null" }
        return command
    case .placeholder(let session, let folder, let why, _):
        return enter(folder) + "; echo \(shellQuote("# tmux session \(session): \(why)"))"
    }
}

/// The command iTerm is given for a new tab or window: a login shell runs it, then replaces
/// itself with a plain login shell so the tab outlives it (as `runInNewTab` does).
///
/// Not interactive (`-lc`) except for a resume: an interactive first shell loads `.zshrc`, and
/// with it powerlevel10k's gitstatus daemon. A short command (`cd; cat notes`) then `exec`s within
/// the same second, under the same pid, so the next shell's gitstatus files get the same name
/// (`<pid>.<EPOCHSECONDS>.1`); the first daemon, exiting, deletes the new shell's lock and the
/// tab prints "gitstatus failed to initialize". `.zprofile` alone puts tmux on PATH. A resume
/// needs `.zshrc` (claude's PATH, aliases), so it is interactive and waits a second before the
/// `exec`, in case it fails at once.
func tabStartCommand(_ action: RestoreAction) -> String {
    let shell = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_shell) } ?? "/bin/zsh"
    if case .resume = action { return "\(shell) -lic \(shellQuote("\(restoreCommand(action)); sleep 1; exec \(shell) -l"))" }
    return "\(shell) -lc \(shellQuote("\(restoreCommand(action)); exec \(shell) -l"))"
}

/// What a restore does to iTerm, so its order can be checked without one. Window ids are iTerm's.
struct TabRestoreSteps {
    /// The hotkey window's id, made with this profile when there is none.
    var hotkeyWindow: (_ profile: String) -> String?
    /// A new window with this profile, its first tab starting this command; its id.
    var newWindow: (_ profile: String, _ command: String) -> String?
    /// `command` is the whole start command, shell included (`tabStartCommand`).
    var selectLastTab: (_ window: String) -> Void
    var newTab: (_ window: String, _ profile: String, _ command: String) -> Bool
    var shownSessions: () -> Set<String>
    /// Gives a reattached tmux session's tab its title again (see `restoreTitle`).
    var retitle: (_ session: String) -> Void = { _ in }
    var pause: (Double) -> Void
    var log: (String) -> Void
    var report: (String, Double) -> Void
    var waitSeconds = 20
    var resumeWaitSeconds = 45
}

/// What a restore did: a summary line, a line per tab, and whether every tab came back.
struct RestoreResult {
    var summary: String
    var lines: [String]
    var complete: Bool
}

/// The title a reattached tab gets back. iTerm titles a `tmux -CC` tab from the title escape a
/// program wrote into the pane, and a reattach does not replay it, so the tab shows only its job
/// ("claude"). The pane's title as tmux keeps it (Claude Code's own, such as "✳ Topic") comes first;
/// tmux's default, the host name, is no title. Otherwise the session's name in CC Sessions.
func restoreTitle(paneTitle: String, host: String, fallback: String?) -> String? {
    let title = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != host, !host.hasPrefix(title + "."), title != host.components(separatedBy: ".").first {
        return title
    }
    let name = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
    return name?.isEmpty == false ? name : nil
}

/// The escape that sets a terminal's window and tab title (OSC 0), with control characters removed.
func titleEscape(_ title: String) -> String {
    "\u{1B}]0;" + String(title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }) + "\u{07}"
}

/// Opens every planned tab in order. Before each new tab the window's last tab is selected, since
/// iTerm puts a new tab after the current one; an attach waits until iTerm shows its session, and a
/// resume until iTerm shows a new one, before the next tab, so tmux tabs, which iTerm appends at the
/// end (clo moves a resumed one into its launching tab's place), keep their saved order.
@discardableResult
func runTabRestore(_ plan: RestorePlan, _ steps: TabRestoreSteps) -> RestoreResult {
    var opened = 0
    var complete = true
    var lines: [String] = []
    func said(_ line: String) { lines.append(line); steps.log("restore: \(line)") }
    func waitShown(_ action: RestoreAction, before: Set<String>) {
        switch action {
        case .attach(let session, _):
            for _ in 0..<max(1, steps.waitSeconds * 2) {
                if steps.shownSessions().contains(session) { steps.retitle(session); said("reattached: \(action.label)"); return }
                steps.pause(0.5)
            }
            complete = false
            said("no tab appeared after \(steps.waitSeconds) s: \(action.label)")
        case .resume:
            for _ in 0..<max(1, steps.resumeWaitSeconds * 2) {
                if let new = steps.shownSessions().subtracting(before).sorted().first { said("resumed as \(new): \(action.label)"); return }
                steps.pause(0.5)
            }
            complete = false
            said("opened, but no tmux tab appeared after \(steps.resumeWaitSeconds) s, check its tab: \(action.label)")
        case .shell:
            steps.pause(0.5); said("new shell: \(action.label)")
        case .placeholder:
            steps.pause(0.5); said("cannot return, shell opened: \(action.label)")
        }
    }
    func shownBefore(_ action: RestoreAction) -> Set<String> {
        if case .resume = action { return steps.shownSessions() }
        return []
    }
    let total = plan.actions.count
    steps.report("Restoring \(total) iTerm tab\(total == 1 ? "" : "s")", 60)
    for window in plan.windows {
        var id: String?
        var rest = window.actions[...]
        if window.hotkey {
            id = steps.hotkeyWindow(window.profile)
        } else if let first = rest.first {
            let before = shownBefore(first)
            id = steps.newWindow(first.profile, tabStartCommand(first))
            if id != nil { rest = rest.dropFirst(); opened += 1; waitShown(first, before: before) }
        }
        guard let windowId = id else {
            complete = false
            let kind = window.hotkey ? "hotkey" : "normal"
            for action in window.actions { said("not opened, the \(kind) window could not be made: \(action.label)") }
            continue
        }
        for action in rest {
            steps.selectLastTab(windowId)
            let before = shownBefore(action)
            if steps.newTab(windowId, action.profile, tabStartCommand(action)) {
                opened += 1
                waitShown(action, before: before)
            } else {
                complete = false
                said("not opened: \(action.label)")
            }
        }
    }
    for skip in plan.skipped { said("skipped: \(skip)") }
    var summary = total == 0 ? "Nothing to restore" : "Opened \(opened) of \(total) iTerm tab\(total == 1 ? "" : "s")"
    if !complete { summary += "; some did not come back" }
    steps.log("restore: \(summary)")
    steps.report(summary, 30)
    return RestoreResult(summary: summary, lines: lines, complete: complete)
}

// MARK: Which record is saved over, and which is restored

/// Where an automatic save goes. A record from before a reboot, a lost tmux server or an iTerm
/// restart is held until it is restored or saved over by hand: meanwhile the current tabs go to a
/// second file. When the run that second file describes has ended too, and it held a Claude
/// session, it replaces the held one.
enum AutosaveTarget: Equatable { case main, second(promote: Bool) }

func autosaveTarget(main: SavedTabs?, second: SavedTabs?, now: TabGeneration) -> AutosaveTarget {
    guard let main = main, main.released != true, main.generation != now else { return .main }
    let promote = second.map { $0.generation != now && $0.hasClaudeTab } ?? false
    return .second(promote: promote)
}

/// The record Restore reads: the second file once the run it describes has ended with a Claude
/// session in it, else the main one.
func recordToRestore(main: SavedTabs?, second: SavedTabs?, now: TabGeneration) -> SavedTabs? {
    if let second = second, second.generation != now, second.hasClaudeTab { return second }
    return main ?? second
}

/// What a record says that is worth writing again: not the time, the titles or the notes' paths.
func recordContent(_ record: SavedTabs) -> SavedTabs {
    var content = record
    content.savedAt = ""
    content.released = nil
    for w in content.windows.indices {
        for t in content.windows[w].tabs.indices {
            content.windows[w].tabs[t].name = ""
            content.windows[w].tabs[t].notes = nil
            content.windows[w].tabs[t].claude?.name = nil
            content.windows[w].tabs[t].claude?.cwd = nil
        }
    }
    return content
}

/// Whether `new` has lost a tmux session or a plain tab that `old` had.
func recordShrank(from old: SavedTabs, to new: SavedTabs) -> Bool {
    let sessions = { (r: SavedTabs) in Set(r.tabs.compactMap(\.session)) }
    let plain = { (r: SavedTabs) in r.tabs.filter { $0.kind == "plain" }.count }
    return !sessions(old).isSubset(of: sessions(new)) || plain(new) < plain(old)
}

/// A smaller set of tabs must last this long before it replaces a larger one: at a shutdown the
/// tabs go one by one.
let autosaveShrinkSeconds = 60.0

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
        return stop("None of the saved tmux sessions is running: the tmux server is gone, so nothing was restored. Open iTerm2 and choose Restore iTerm Tabs to resume them")
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
/// The current run's automatic saves while the main record is held (`autosaveTarget`).
let secondSavedTabsPath = (savedTabsFolder as NSString).appendingPathComponent("iterm-tabs-current.json")
/// Every save, restore and restart runs here, one at a time.
let itermTabsQueue = DispatchQueue(label: "cc-sessions.iterm-tabs", qos: .userInitiated)

/// clo's records for these tmux sessions.
func cloRecords(_ sessions: Set<String>) -> [String: CloRecord] {
    let env = ProcessInfo.processInfo.environment
    let folder = env["CLO_SESSION_RECORDS"]
        ?? ((env["XDG_STATE_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")) as NSString).appendingPathComponent("agents-shared/clo-sessions")
    var records: [String: CloRecord] = [:]
    for session in sessions {
        let path = (folder as NSString).appendingPathComponent(session.replacingOccurrences(of: "/", with: "_"))
        if let data = fm.contents(atPath: path), let record = parseCloRecord(String(decoding: data, as: UTF8.self)) { records[session] = record }
    }
    return records
}

/// What tmux's panes say: each pane's session by pane number and by tty, and each session's folder.
func currentTmuxPanes() -> (byPane: [String: String], byTty: [String: String], folders: [String: String]) {
    let text = tmuxOutput(["list-panes", "-a", "-F", "#{pane_id}\t#{session_name}\t#{pane_tty}\t#{pane_current_path}"]) ?? ""
    var byTty: [String: String] = [:], folders: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { continue }
        byTty[parts[2]] = parts[1]
        if folders[parts[1]] == nil, !parts[3].isEmpty { folders[parts[1]] = parts[3] }
    }
    let two = text.split(separator: "\n").map { $0.split(separator: "\t").prefix(2).joined(separator: "\t") }.joined(separator: "\n")
    return (tmuxSessionsByPane(in: two), byTty, folders)
}

/// This run of the machine.
func currentGeneration() -> TabGeneration {
    let server = tmuxOutput(["display-message", "-p", "#{pid}"]).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return TabGeneration(boot: bootSessionId(), server: server, iterm: runningITermPid().map(Int.init))
}

/// This boot's id, nil when the kernel does not say.
func bootSessionId() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var text = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &text, &size, nil, 0) == 0 else { return nil }
    return String(cString: text)
}

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
/// `quiet` is the automatic save's: success is not logged, and a refusal resets no grant.
func currentITermListing(quiet: Bool = false) -> [ListedWindow]? {
    guard runningITermPid() != nil else { return nil }
    let text = runScript(itermListingScript, label: "iterm tabs: list", retrying: quiet, logSuccess: !quiet)
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

/// The record of the tabs `windows` lists, without the plain tabs' notes, and each plain tab's
/// listing and command, by its index, for writing them.
func currentRecord(_ windows: [ListedWindow], seen: [SeenSession]) -> (record: SavedTabs, plain: [Int: (tab: ListedTab, command: String?)]) {
    let panes = currentTmuxPanes()
    let sessions = Set(panes.byPane.values)
    let claude = claudeByTmuxSession(panes.byTty, seen: seen, clo: cloRecords(sessions))
    var plain: [Int: (tab: ListedTab, command: String?)] = [:]
    var record = savedTabs(windows, panes: panes.byPane, savedAt: ISO8601DateFormatter().string(from: Date()),
                           claude: claude, folders: panes.folders) { tab, index in
        let tty = (tab.tty as NSString).lastPathComponent
        let process = foregroundProcess(in: commandOutput("/bin/ps", ["-t", tty, "-o", "pid=,stat=,command="]))
        let folder = process.flatMap { lsofDirectory(in: commandOutput("/usr/sbin/lsof", ["-a", "-p", String($0.pid), "-d", "cwd", "-Fn"])) }
        let command = process.flatMap { $0.shell ? nil : $0.command }
        plain[index] = (tab, command)
        return (folder, command, nil)
    }
    record.generation = currentGeneration()
    return (record, plain)
}

/// Writes each plain tab's notes (what ran, its last screen lines) and puts their paths in the record.
func writeNotes(_ record: inout SavedTabs, plain: [Int: (tab: ListedTab, command: String?)]) {
    try? fm.createDirectory(atPath: savedTabNotesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    var index = 0
    for w in record.windows.indices {
        for t in record.windows[w].tabs.indices where record.windows[w].tabs[t].kind == "plain" {
            index += 1
            guard let found = plain[index] else { continue }
            let path = (savedTabNotesFolder as NSString).appendingPathComponent("tab-\(stamp)-\(index).txt")
            let text = plainTabNotes(name: found.tab.name, command: found.command, screen: itermSessionContents(found.tab.sessionId), savedAt: record.savedAt)
            if fm.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) { record.windows[w].tabs[t].notes = path }
        }
    }
}

@discardableResult
func writeRecord(_ record: SavedTabs, to path: String) -> Bool {
    try? fm.createDirectory(atPath: savedTabsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(record) else { return false }
    do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { return false }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return true
}

/// Removes the notes files neither record names.
func removeUnusedNotes() {
    let used = Set([savedTabsPath, secondSavedTabsPath].compactMap(loadSavedITermTabs).flatMap(\.tabs).compactMap(\.notes))
    for old in (try? fm.contentsOfDirectory(atPath: savedTabNotesFolder)) ?? [] where old.hasSuffix(".txt") {
        let path = (savedTabNotesFolder as NSString).appendingPathComponent(old)
        if !used.contains(path) { try? fm.removeItem(atPath: path) }
    }
}

/// Saves every iTerm window and tab in order, over any held record; returns the report line, or the
/// reason it could not.
func saveITermTabs(seen: [SeenSession]) -> (record: SavedTabs?, message: String) {
    guard runningITermPid() != nil else { return (nil, "iTerm2 is not running: nothing saved") }
    guard let windows = currentITermListing(), !windows.isEmpty, windows.contains(where: { !$0.tabs.isEmpty }) else {
        if replacedBundle(at: Bundle.main.bundlePath) {
            return (nil, "CC Sessions was reinstalled while open, and macOS refuses this old copy's requests to iTerm2. Quit and reopen CC Sessions, then save again. Nothing was saved and iTerm2 was left running")
        }
        return (nil, "Could not read iTerm2's tabs: its AppleScript failed or listed none (cc-sessions.log has what it returned). Nothing was saved and iTerm2 was left running")
    }
    var (record, plain) = currentRecord(windows, seen: seen)
    writeNotes(&record, plain: plain)
    guard writeRecord(record, to: savedTabsPath) else { return (nil, "Could not write \(savedTabsPath)") }
    try? fm.removeItem(atPath: secondSavedTabsPath)
    removeUnusedNotes()
    let tabs = record.tabs
    let tmux = tabs.filter { $0.kind == "tmux" }.count, plainCount = tabs.filter { $0.kind == "plain" }.count, other = tabs.count - tmux - plainCount
    let resumable = tabs.filter { $0.claude?.prompted == true }.count
    var message = "Saved \(tmux) tmux tab\(tmux == 1 ? "" : "s") (\(resumable) resumable after a reboot) and \(plainCount) plain tab\(plainCount == 1 ? "" : "s") in \(record.windows.count) window\(record.windows.count == 1 ? "" : "s")"
    if other > 0 { message += "; \(other) tmux tab\(other == 1 ? "" : "s") of another server cannot be restored" }
    let profiles = itermProfileNames()
    for name in Set(tabs.map(\.profile)).sorted() where name != profiles.defaultName && profiles.counts[name, default: 0] > 1 {
        message += "; iTerm2 has \(profiles.counts[name]!) profiles named \"\(name)\", so its tabs may come back with the other one's font: rename or delete the extra in iTerm2 > Settings > Profiles"
    }
    log("iterm tabs: \(message)")
    return (record, message)
}

/// The automatic save's memory between ticks; touched only on `itermTabsQueue`.
struct AutosaveState {
    var shrinkingSince: Date?
    var failedAt: Date?
}

/// Saves the tabs when they changed since the last save (`autosaveTarget` says where). Nothing is
/// saved without iTerm and a tmux server, and a smaller set waits `autosaveShrinkSeconds`.
func autosaveITermTabs(seen: [SeenSession], state: inout AutosaveState, now: Date = Date()) {
    if let failed = state.failedAt, now.timeIntervalSince(failed) < 600 { return }
    guard runningITermPid() != nil, !replacedBundle(at: Bundle.main.bundlePath) else { return }
    let generation = currentGeneration()
    guard generation.server != nil else { return }
    guard let windows = currentITermListing(quiet: true) else { state.failedAt = now; return }
    state.failedAt = nil
    guard windows.contains(where: { !$0.tabs.isEmpty }) else { return }
    var (record, plain) = currentRecord(windows, seen: seen)
    let main = loadSavedITermTabs(savedTabsPath), second = loadSavedITermTabs(secondSavedTabsPath)
    let target = autosaveTarget(main: main, second: second, now: record.generation)
    let path = target == .main ? savedTabsPath : secondSavedTabsPath
    let old = target == .main ? main : second
    if let old = old, old.generation == record.generation {
        if recordContent(old) == recordContent(record) { state.shrinkingSince = nil; return }
        if recordShrank(from: old, to: record) {
            let since = state.shrinkingSince ?? now
            state.shrinkingSince = since
            if now.timeIntervalSince(since) < autosaveShrinkSeconds { return }
        }
    }
    state.shrinkingSince = nil
    if target == .second(promote: true), let second = second {
        guard writeRecord(second, to: savedTabsPath) else { return }
        log("iterm tabs: autosave: the last run's tabs (saved \(second.savedAt)) replace the older record")
    }
    writeNotes(&record, plain: plain)
    guard writeRecord(record, to: path) else { log("iterm tabs: autosave: could not write \(path)"); return }
    if target == .main { try? fm.removeItem(atPath: secondSavedTabsPath) }
    removeUnusedNotes()
    log("iterm tabs: autosave: \(record.tabs.count) tabs in \((path as NSString).lastPathComponent)")
}

/// A saved record, nil when there is none or it does not read.
func loadSavedITermTabs(_ path: String) -> SavedTabs? {
    fm.contents(atPath: path).flatMap { try? JSONDecoder().decode(SavedTabs.self, from: $0) }
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

/// Writes each pane's title escape (see `restoreTitle`) to the pane's tty, its output side: tmux
/// passes it to iTerm as pane output, and the program in the pane can retitle it later as usual.
func retitleTmuxSession(_ session: String, names: [String: String]) {
    let host = ProcessInfo.processInfo.hostName
    for line in (tmuxOutput(["list-panes", "-t", "=" + session, "-F", "#{pane_tty}\t#{pane_title}"]) ?? "").split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("/dev/"),
              let title = restoreTitle(paneTitle: parts[1], host: host, fallback: names[session]),
              let handle = FileHandle(forWritingAtPath: parts[0]) else { continue }
        handle.write(Data(titleEscape(title).utf8))
        try? handle.close()
        log("iterm tabs: \(session): title set again")
    }
}

/// The restore steps that drive the real iTerm. `names` is each tmux session's name in CC Sessions,
/// the title of last resort.
func liveTabRestoreSteps(report: @escaping (String, Double) -> Void, names: [String: String] = [:]) -> TabRestoreSteps {
    let profiles = itermProfileNames()
    return TabRestoreSteps(
        hotkeyWindow: { profile in
            // Right after iTerm starts there is no hotkey window until its key is first pressed, and
            // making one can fail for a few seconds while iTerm loads its profiles: keep trying, and
            // log why each try failed, for up to 30 s.
            let script = """
                tell application id "\(itermBundleId)"
                  repeat with w in windows
                    if is hotkey window of w then return (id of w) as text
                  end repeat
                  try
                    set w to (create hotkey window with profile \(appleScriptString(profile)))
                  on error e
                    return "error: " & e
                  end try
                  repeat with w in windows
                    if is hotkey window of w then return (id of w) as text
                  end repeat
                  return "error: made a hotkey window, but none is listed"
                end tell
                """
            for attempt in 1...30 {
                let answer = runScript(script, label: "iterm tabs: hotkey window (try \(attempt))")
                if !answer.isEmpty, !answer.hasPrefix("error"), answer.allSatisfy(\.isNumber) { return answer }
                usleep(1_000_000)
            }
            return nil
        },
        newWindow: { profile, command in
            let script = """
                tell application id "\(itermBundleId)"
                  set w to (create window with \(itermProfileClause(profile, profiles)) command \(appleScriptString(command)))
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
                  tell window id \(window) to create tab with \(itermProfileClause(profile, profiles)) command \(appleScriptString(command))
                  return "ok"
                end tell
                """
            return runScript(script, label: "iterm tabs: new tab") == "ok"
        },
        shownSessions: { liveShownTmuxSessions() },
        retitle: { retitleTmuxSession($0, names: names) },
        pause: { usleep(UInt32($0 * 1_000_000)) },
        log: { log("iterm tabs: \($0)") },
        report: report)
}

/// iTerm's profiles as its preferences list them: how many share each name, and the default's name.
struct ITermProfileNames {
    var counts: [String: Int]
    var defaultName: String?
}

func itermProfileNames(plist: String = home.appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist").path) -> ITermProfileNames {
    guard let data = fm.contents(atPath: plist),
          let prefs = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
        return ITermProfileNames(counts: [:], defaultName: nil)
    }
    let bookmarks = prefs["New Bookmarks"] as? [[String: Any]] ?? []
    var counts: [String: Int] = [:]
    for bookmark in bookmarks { if let name = bookmark["Name"] as? String { counts[name, default: 0] += 1 } }
    let guid = prefs["Default Bookmark Guid"] as? String
    return ITermProfileNames(counts: counts, defaultName: bookmarks.first { ($0["Guid"] as? String) == guid }?["Name"] as? String)
}

/// How a new tab or window names its profile in AppleScript. iTerm picks a profile by name, and where two
/// share one (iTerm's stock Monaco "Default" beside a synced "Default") it took the stock one, so a tab saved
/// under the default profile's name is made with `default profile`, which iTerm resolves by its Guid.
func itermProfileClause(_ name: String, _ profiles: ITermProfileNames) -> String {
    name == profiles.defaultName ? "default profile" : "profile \(appleScriptString(name))"
}

/// A restore worked out but not run: the record it reads and what it will do.
struct PreparedRestore {
    var record: SavedTabs
    var plan: RestorePlan
    /// The Mac started again since the record was saved.
    var rebooted: Bool
}

/// What Restore would do now, or why it cannot.
func prepareITermRestore(seen: [SeenSession]) -> (restore: PreparedRestore?, why: String) {
    let generation = currentGeneration()
    guard let record = recordToRestore(main: loadSavedITermTabs(savedTabsPath), second: loadSavedITermTabs(secondSavedTabsPath), now: generation) else {
        return (nil, "No saved iTerm tabs: choose Save iTerm Tabs first")
    }
    guard runningITermPid() != nil else { return (nil, "iTerm2 is not running: open it, then Restore iTerm Tabs") }
    let panes = currentTmuxPanes()
    let live = liveTmuxSessions()
    let clo = cloRecords(live.union(record.tabs.compactMap(\.session)))
    let world = restoreWorld(record, now: generation, live: live, shown: liveShownTmuxSessions(),
                             sessionsByTty: panes.byTty, seen: seen, clo: clo)
    let saved = ISO8601DateFormatter().date(from: record.savedAt)
    let rebooted = saved.flatMap { saved in bootTimeMs().map { saved.timeIntervalSince1970 * 1000 < $0 } } ?? false
    return (PreparedRestore(record: record, plan: restorePlan(record, world), rebooted: rebooted), "")
}

/// Runs a prepared restore. Once every tab is back, the record is released to the automatic save.
func performITermRestore(_ prepared: PreparedRestore, report: @escaping (String, Double) -> Void, names: [String: String] = [:]) -> RestoreResult {
    let result = runTabRestore(prepared.plan, liveTabRestoreSteps(report: report, names: names))
    var record = prepared.record
    record.released = result.complete
    // The record just restored is the one held from now on, whichever file it came from.
    if writeRecord(record, to: savedTabsPath), loadSavedITermTabs(secondSavedTabsPath).map({ $0.generation != currentGeneration() || result.complete }) ?? false {
        try? fm.removeItem(atPath: secondSavedTabsPath)
    }
    if prepared.plan.windows.contains(where: \.hotkey) {
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
    return result
}

/// The restart steps that drive the real iTerm and tmux.
func liveITermRestartSteps(seen: [SeenSession], report: @escaping (String, Double) -> Void, names: [String: String] = [:]) -> ITermRestartSteps {
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
        restore: {
            let (prepared, why) = prepareITermRestore(seen: seen)
            guard let prepared = prepared else { return why }
            let result = performITermRestore(prepared, report: report, names: names)
            return ([result.summary] + result.lines).joined(separator: "\n")
        },
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

    // An old record is used whatever its age; a running session is attached, a shown one skipped,
    // an ended one with no Claude session gets a shell, foreign tabs are reported.
    let old = SavedTabs(savedAt: "2001-01-01T00:00:00Z", windows: record.windows)
    let plan = restorePlan(old, RestoreWorld(live: ["proj-a", "proj-c"], shown: ["proj-c"]))
    let wantFirst: [RestoreAction] = [.attach(session: "proj-a", profile: "Hotkey Window"),
                                      .shell(folder: "/dir1", notes: "/notes/tab-1.txt", profile: "Hotkey Window"),
                                      .shell(folder: "/dir2", notes: "/notes/tab-2.txt", profile: "Hotkey Window"),
                                      .placeholder(session: "proj-b", folder: nil, why: "ended; it held no Claude session", profile: "Hotkey Window")]
    if plan.windows.count != 1 || plan.windows[0].actions != wantFirst || !plan.windows[0].hotkey {
        problems.append("restore plan was \(plan.windows)")
    }
    if plan.skipped != ["foreign: a tmux tab of another server", "proj-c: already shown"] { problems.append("restore skipped \(plan.skipped)") }
    problems += savedClaudeProblems()
    problems += autosaveProblems()
    if restoreCommand(.attach(session: "a'b", profile: "")) != "if command -v clo >/dev/null; then command clo --attach 'a'\\''b'; else tmux -CC attach-session -t '=a'\\''b'; fi" {
        problems.append("attach command was \(restoreCommand(.attach(session: "a'b", profile: "")))")
    }
    if restoreCommand(.shell(folder: "/x y", notes: "/n.txt", profile: "")) != "cd '/x y' 2>/dev/null || cd; cat '/n.txt' 2>/dev/null" {
        problems.append("plain tab command was \(restoreCommand(.shell(folder: "/x y", notes: "/n.txt", profile: "")))")
    }
    let resumed = RestoreAction.resume(SavedClaude(id: "i1", dir: "/d", model: "m", effort: "high", mode: "plan"), profile: "")
    if !restoreCommand(resumed).contains("--resume i1 --model 'm' --effort high --permission-mode plan") || !tabStartCommand(resumed).contains(" -lic ") {
        problems.append("resume tab command was \(tabStartCommand(resumed))")
    }
    if appleScriptString("a\"b\\c") != "\"a\\\"b\\\\c\"" { problems.append("AppleScript string was \(appleScriptString("a\"b\\c"))") }

    // Restore order: the last tab is selected before every new tab, an attach waits for its tab,
    // a resume for a new one, and a normal window starts with its first tab's command.
    // The session an attach command names, "new-<id>" for a resume (test names carry no quote).
    func attached(_ command: String) -> String? {
        if let start = command.range(of: "--resume ") { return "new-" + command[start.upperBound...].prefix { $0 != " " && $0 != ";" && $0 != "'" } }
        // The start command quotes the attach command again, so the name sits between escaped quotes.
        guard let start = command.range(of: "--attach ") else { return nil }
        return String(command[start.upperBound...].drop { "'\\".contains($0) }.prefix { !"'\\;".contains($0) })
    }
    func tab(_ action: RestoreAction) -> String { tabStartCommand(action) }
    func restore(_ plan: RestorePlan, showAfter: Int?) -> (calls: [String], result: RestoreResult) {
        var calls: [String] = [], polls = 0, opened: Set<String> = []
        let steps = TabRestoreSteps(
            hotkeyWindow: { calls.append("hotkey \($0)"); return "1" },
            newWindow: { profile, command in calls.append("window \(profile): \(command)"); if let s = attached(command) { opened.insert(s) }; return "2" },
            selectLastTab: { calls.append("select \($0)") },
            newTab: { window, _, command in calls.append("tab \(window): \(command)"); if let s = attached(command) { opened.insert(s) }; return true },
            shownSessions: {
                polls += 1
                guard let after = showAfter, polls >= after else { return [] }
                return opened
            },
            pause: { _ in }, log: { _ in }, report: { _, _ in }, waitSeconds: 2, resumeWaitSeconds: 2)
        let result = runTabRestore(plan, steps)
        return (calls, result)
    }
    let a = RestoreAction.attach(session: "a", profile: "H"), shell = RestoreAction.shell(folder: "/d", notes: nil, profile: "H")
    let c = RestoreAction.attach(session: "c", profile: "D"), r = RestoreAction.resume(SavedClaude(id: "r1", dir: "/d"), profile: "D")
    let two = RestorePlan(windows: [(true, "H", [a, shell]), (false, "D", [c, r])], skipped: [])
    let ordered = restore(two, showAfter: 1)
    let want = ["hotkey H", "select 1", "tab 1: \(tab(a))", "select 1", "tab 1: \(tab(shell))",
                "window D: \(tab(c))", "select 2", "tab 2: \(tab(r))"]
    if ordered.calls != want { problems.append("restore order was \(ordered.calls)") }
    if !ordered.result.complete || !ordered.result.summary.hasPrefix("Opened 4 of 4") || !ordered.result.lines.contains("resumed as new-r1: r1") {
        problems.append("a full restore reported \(ordered.result)")
    }
    var retitled: [String] = []
    let titled = TabRestoreSteps(
        hotkeyWindow: { _ in "1" }, newWindow: { _, _ in "2" }, selectLastTab: { _ in }, newTab: { _, _, _ in true },
        shownSessions: { ["a", "c"] }, retitle: { retitled.append($0) }, pause: { _ in }, log: { _ in }, report: { _, _ in }, waitSeconds: 1, resumeWaitSeconds: 1)
    let stale = runTabRestore(two, titled)
    if retitled != ["a", "c"] { problems.append("reattached tabs that appeared were retitled as \(retitled), not a and c") }
    if stale.complete { problems.append("a resume with no new tab counted as complete") }
    if restoreTitle(paneTitle: "✳ Topic", host: "box.local", fallback: "Name") != "✳ Topic" { problems.append("a pane's own title did not come first") }
    for host in ["box.local", "box"] where restoreTitle(paneTitle: "box", host: host, fallback: "Name") != "Name" {
        problems.append("tmux's host-name title was kept over the CC Sessions name (host \(host))")
    }
    if restoreTitle(paneTitle: " ", host: "box", fallback: nil) != nil { problems.append("an empty title with no fallback still gave a title") }
    if titleEscape("a\u{07}b\u{1B}c") != "\u{1B}]0;abc\u{07}" { problems.append("the title escape kept control characters") }
    let never = restore(RestorePlan(windows: [(true, "H", [a])], skipped: ["b: already shown"]), showAfter: nil)
    if never.result.complete || never.result.lines != ["no tab appeared after 2 s: a", "skipped: b: already shown"] { problems.append("a tab that never appeared was reported as \(never.result)") }

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

/// The checks of what is saved for a tmux tab's Claude session and what a restore does with it.
func savedClaudeProblems() -> [String] {
    var problems: [String] = []
    func claude(_ id: String, dir: String = "/p", prompted: Bool = true) -> SavedClaude { SavedClaude(id: id, dir: dir, name: id, prompted: prompted) }
    if parseCloRecord("abc\t/some dir\n") != CloRecord(id: "abc", folder: "/some dir") || parseCloRecord("\n") != nil { problems.append("a clo record was misread") }
    let seen = [SeenSession(claude: claude("live1"), tty: "/dev/t1", live: true), SeenSession(claude: claude("past2"), tty: "/dev/t2", live: false)]
    let held = claudeByTmuxSession(["/dev/t1": "one", "/dev/t2": "two", "/dev/t3": "three"], seen: seen,
                                   clo: ["one": CloRecord(id: "other", folder: "/p"), "two": CloRecord(id: "past2", folder: "/p")])
    if held != ["one": claude("live1"), "two": claude("past2")] { problems.append("the Claude session of each tmux session was \(held)") }
    func tab(_ session: String, _ c: SavedClaude?) -> SavedTab { SavedTab(kind: "tmux", name: session, profile: "P", session: session, folder: "/f", claude: c) }
    let tabs = [tab("gone", claude("g")), tab("cleared", claude("before")), tab("reused", claude("mine")), tab("moved", claude("m")),
                tab("outside", claude("o")), tab("empty", claude("e", prompted: false)), tab("legacy", nil), tab("kept", claude("k"))]
    let record = SavedTabs(savedAt: "T", windows: [SavedWindow(hotkey: true, profile: "P", tabs: tabs)], server: 1)
    let clo = ["cleared": CloRecord(id: "after", folder: "/p"), "reused": CloRecord(id: "stranger", folder: "/elsewhere"),
               "legacy": CloRecord(id: "l", folder: "/l")]
    let world = restoreWorld(record, now: TabGeneration(server: 2), live: ["kept", "newname", "reused"], shown: [],
                             sessionsByTty: ["/dev/k": "kept", "/dev/n": "newname", "/dev/r": "reused"],
                             seen: [SeenSession(claude: claude("k"), tty: "/dev/k", live: true), SeenSession(claude: claude("m"), tty: "/dev/n", live: true),
                                    SeenSession(claude: claude("o"), tty: "/dev/o", live: true), SeenSession(claude: claude("x"), tty: "/dev/r", live: true)], clo: clo)
    let actions = restorePlan(record, world).actions
    let want: [RestoreAction] = [.resume(claude("g"), profile: "P"),
                                 .resume(SavedClaude(id: "after", dir: "/p", name: "before"), profile: "P"),
                                 // The name now belongs to another conversation on a new server: the saved one is resumed.
                                 .resume(claude("mine"), profile: "P"),
                                 .attach(session: "newname", profile: "P"),
                                 .placeholder(session: "empty", folder: "/p", why: "never had a prompt, so there is nothing to resume", profile: "P"),
                                 .resume(SavedClaude(id: "l", dir: "/l"), profile: "P"),
                                 .attach(session: "kept", profile: "P")]
    if actions != want { problems.append("restoring Claude tabs planned \(actions)") }
    if restorePlan(record, world).skipped != ["o: already running outside tmux"] { problems.append("restoring Claude tabs skipped \(restorePlan(record, world).skipped)") }
    let preview = restorePreview(restorePlan(record, world))
    if preview.counts != "4 sessions will be resumed, 2 reattached, 1 cannot return." { problems.append("the restore preview read \(preview.counts)") }
    return problems
}

/// The checks of where an automatic save goes and what a restore reads.
func autosaveProblems() -> [String] {
    var problems: [String] = []
    func record(boot: String, sessions: [String], released: Bool? = nil, claude: Bool = true) -> SavedTabs {
        let tabs = sessions.map { SavedTab(kind: "tmux", name: $0, profile: "P", session: $0, claude: claude ? SavedClaude(id: $0, dir: "/p") : nil) }
        return SavedTabs(savedAt: "T", windows: [SavedWindow(hotkey: true, profile: "P", tabs: tabs)], boot: boot, server: 1, iterm: 1, released: released)
    }
    let a = record(boot: "1", sessions: ["x", "y"]), b = record(boot: "2", sessions: ["z"])
    let now2 = b.generation, now3 = TabGeneration(boot: "3", server: 1, iterm: 1)
    if autosaveTarget(main: nil, second: nil, now: now2) != .main || autosaveTarget(main: b, second: nil, now: now2) != .main { problems.append("an autosave did not replace its own run's record") }
    if autosaveTarget(main: a, second: nil, now: now2) != .second(promote: false) || autosaveTarget(main: a, second: b, now: now2) != .second(promote: false) {
        problems.append("an autosave replaced the record from before a reboot")
    }
    if autosaveTarget(main: record(boot: "1", sessions: ["x"], released: true), second: nil, now: now2) != .main { problems.append("a restored record was still held") }
    if autosaveTarget(main: a, second: b, now: now3) != .second(promote: true) { problems.append("the last run's record did not replace an older held one") }
    if autosaveTarget(main: a, second: record(boot: "2", sessions: ["s"], claude: false), now: now3) != .second(promote: false) { problems.append("a run with no Claude session replaced a held record") }
    if recordToRestore(main: a, second: b, now: now2) != a || recordToRestore(main: a, second: b, now: now3) != b || recordToRestore(main: nil, second: b, now: now2) != b {
        problems.append("restore read the wrong record")
    }
    if !recordShrank(from: a, to: record(boot: "1", sessions: ["x"])) || recordShrank(from: a, to: record(boot: "1", sessions: ["x", "y", "w"])) { problems.append("a shrinking set of tabs was misjudged") }
    var renamed = a
    renamed.windows[0].tabs[0].name = "spinner"
    renamed.savedAt = "later"
    if recordContent(renamed) != recordContent(a) { problems.append("a new title counted as a change of tabs") }
    return problems
}
