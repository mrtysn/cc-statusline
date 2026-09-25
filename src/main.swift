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
import AudioToolbox
import AVFoundation
import CryptoKit
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

/// system-one's per-session shadow log (agents-shared/notebook/2026-09-24-system-one-
/// decision-model-integration.md, section 9): one JSONL file per session, read for
/// the Verdicts view. Resolved the same way cc-statusline.js resolves it.
let systemOneShadowDir: URL = {
    if let v = ProcessInfo.processInfo.environment["SYSTEM_ONE_STATE_DIR"], !v.isEmpty {
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath).appendingPathComponent("shadow")
    }
    return xdgDir("XDG_STATE_HOME", fallback: ".local/state").appendingPathComponent("system-one").appendingPathComponent("shadow")
}()

/// The three hooks with a shadow log, in the order the Verdicts window's hook
/// selector lists them.
let systemOneHooks = ["bash", "prompt", "stop"]

/// Short labels for the questions each hook asks, in display order, mirroring
/// cc-statusline.js's HOOK_LABELS so the status line row and this window agree
/// (bash keeps the irr/for/net/ins order section 9 of the design doc fixed).
/// A question outside the map still renders, at its position (q1, q2, ...).
let systemOneHookLabels: [String: [(key: String, label: String)]] = [
    "bash": [("irreversible", "Irr"), ("foreign_process", "For"), ("leaves_machine", "Net"), ("network_install", "Ins")],
    "prompt": [("kind", "Knd"), ("wants_action", "Act")],
    "stop": [("overlong", "Lng"), ("needless_table", "Tbl")],
]

func systemOneShadowFile(for sessionId: String, hook: String) -> URL? {
    let safeSession = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    let safeHook = hook.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    guard !safeSession.isEmpty, !safeHook.isEmpty else { return nil }
    return systemOneShadowDir.appendingPathComponent(safeHook).appendingPathComponent("\(safeSession).jsonl")
}

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
    // The throwing calls, not seekToEndOfFile() and write(_:): those raise an
    // Objective-C exception on a full disk, which Swift cannot catch.
    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
    let hit_ratio: Double?
    let requests: Double?
    let misses: Double?
    let last_miss_at: Double?
    let last_miss_causes: [String]?
}

struct LineCount: Decodable {
    let added: Double
    let removed: Double
}

struct Tokens: Decodable {
    let input: Double
    let cache_write: Double
    let cache_read: Double
    let output: Double
    let total: Double
}

struct Agents: Decodable {
    let total: Int
    let running: Int
}

/// What the transcript says the session is doing; see transcriptScan in the script.
struct TranscriptState: Decodable {
    let state: String?
    let state_at: Double?
    let tool: String?
    let mode: String?
    let tokens: Tokens?
    let agents: Agents?
}

struct RedrawCost: Decodable {
    let cpu_ms: Double?
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
    /// The name with its version, e.g. `Opus 5.5`; the strip shows only the tier.
    let model_full: String?
    /// The id Claude Code runs, e.g. `claude-opus-5-5`, for resuming with it.
    let model_id: String?
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
    /// Where the session was launched, which is where it resumes.
    let project_dir: String?
    let git: GitState?
    let lines: LineCount?
    let session_name: String?
    let version: String?
    let fast_mode: Bool?
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

struct Ended: Decodable {
    let reason: String?
    let at: Double?
}

struct Session: Decodable {
    let updated_at: Double
    /// The later of the last redraw and the last transcript write: a busy
    /// session can go minutes without redrawing.
    let active_at: Double?
    let tty: String?
    /// The Claude Code process that owns the terminal.
    let pid: Int32?
    /// What the latest status line redraw cost.
    let redraw: RedrawCost?
    let transcript: TranscriptState?
    /// The name other sessions message this one by, e.g. `finance-be`.
    let peer_name: String?
    /// Claude Code's own word for the session: busy, idle or waiting.
    let peer_status: String?
    /// While waiting, what for: `input needed`, `dialog open`, …
    let peer_waiting_for: String?
    /// How a finished session ended: Claude Code's SessionEnd reason, or
    /// `crashed` when its process went without one.
    let ended: Ended?
    let rows: [String]
    let summary: Summary
    let segments: Segments
}

/// The account's Fable quota, read from the shared usage cache.
struct FableQuota: Decodable {
    let percent: Double?
    let resets_at: Double?
    let read_at: Double?
}

/// An outside format that stopped matching what the tool reads; see health.json.
struct HealthIssue: Decodable {
    let key: String
    let problem: String
    let version: String?
    let first_seen: Double
    let count: Int
}

struct Snapshot: Decodable {
    let live: [Session]
    let history: [Session]
    let fable: FableQuota?
    let health: [HealthIssue]?
}

/// The app's half of the format checks, for what only it reads: hook events and
/// the npm registry. Same file and rules as the script's checkFormat: a failure
/// is written when it appears and at most once a minute after, a pass clears it.
func checkFormat(_ key: String, _ ok: Bool, _ problem: String, example: String? = nil) {
    let file = cacheDir.appendingPathComponent("health.json")
    var health = (try? Data(contentsOf: file)).flatMap {
        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
    } ?? [:]
    let known = health[key] as? [String: Any]
    let now = Date().timeIntervalSince1970 * 1000
    if ok {
        guard known != nil else { return }
        health.removeValue(forKey: key)
        log("format ok again: \(key)")
    } else {
        if let last = known?["last_seen"] as? Double, now - last < 60000 { return }
        health[key] = [
            "problem": problem,
            "version": known?["version"] ?? NSNull(),
            "first_seen": known?["first_seen"] ?? now,
            "last_seen": now,
            "count": ((known?["count"] as? Int) ?? 0) + 1,
            "example": example.map { String($0.prefix(300)) } ?? known?["example"] ?? NSNull(),
        ]
        if known == nil { log("format: \(key): \(problem)") }
    }
    if let data = try? JSONSerialization.data(withJSONObject: health) { try? data.write(to: file, options: .atomic) }
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

    let task = scriptProcess(script, ["live", "--columns", String(columns)])
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
    } catch {
        log("spawn failed: \(error.localizedDescription)")
        return nil
    }
    return finishSnapshot(task, pipe)
}

/// The script as a process, with a PATH that can find node.
func scriptProcess(_ script: URL, _ arguments: [String]) -> Process {
    let task = Process()
    task.executableURL = script
    task.arguments = arguments
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
    return task
}

/// Fetches the account's usage once, for the Fable quota: it only moves while
/// Fable runs, and a Fable session keeps the shared cache fresh by itself, so
/// one reading at launch covers the rest. Blocks; call it off the main thread.
func refreshUsageOnce() {
    let script = repoDir.appendingPathComponent("cc-statusline.js")
    guard fm.isExecutableFile(atPath: script.path) else { return }
    let task = scriptProcess(script, ["refresh-usage"])
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log("usage refresh failed: \(error.localizedDescription)")
    }
}

private func finishSnapshot(_ task: Process, _ pipe: Pipe) -> Snapshot? {
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
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

// MARK: - Reading processes

/// Memory and CPU of each session's Claude Code process and everything under it,
/// read from the kernel: no ps, no subprocess. Listing processes with ps costs
/// ~0.4 s of system time here, far more than everything else the app does.
final class ProcessSampler {
    struct Reading {
        /// What Activity Monitor calls Memory: resident plus compressed.
        let footprint: UInt64
        /// Share of one core since the last reading; nil on the first.
        let cpuPercent: Double?
        /// CPU the session's own process has used since it started.
        let cpuSeconds: Double
        let processes: Int
        /// When the youngest process under the session started, epoch seconds:
        /// an approved shell command starts one, a pending prompt does not.
        let newestChild: Double?
    }

    /// rusage times are in mach ticks, which are not nanoseconds on Apple silicon.
    private let tick: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom)
    }()
    private var previous: [pid_t: UInt64] = [:]
    private var previousAt: UInt64 = 0

    /// The pid still runs and still owns the session's terminal. A pid is reused
    /// once its process exits; the terminal is what ties it to the session.
    func owns(pid: pid_t, tty: String?) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        guard let tty = tty else { return true }
        var st = stat()
        guard stat(tty, &st) == 0 else { return false }
        return info.e_tdev == UInt32(bitPattern: st.st_rdev)
    }

    private func usage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
            }
        }
        return ok ? info : nil
    }

    private func tree(_ root: pid_t) -> [pid_t] {
        var out = [root]
        var i = 0
        while i < out.count && out.count < 512 {
            var buffer = [pid_t](repeating: 0, count: 256)
            let n = proc_listchildpids(out[i], &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            if n > 0 { out += buffer.prefix(Int(n)).filter { $0 > 0 && !out.contains($0) } }
            i += 1
        }
        return out
    }

    /// One reading per root pid. CPU is the change since the previous call, per
    /// process, so a child that exits between readings is simply not counted.
    func sample(_ roots: [pid_t]) -> [pid_t: Reading] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousAt == 0 ? 0 : Double(now - previousAt)
        var seen: [pid_t: UInt64] = [:]
        var out: [pid_t: Reading] = [:]
        for root in roots {
            var footprint: UInt64 = 0
            var spent: Double = 0
            var own: Double = 0
            var count = 0
            var newest: Double? = nil
            for pid in tree(root) {
                guard let u = usage(pid) else { continue }
                if pid != root {
                    var info = proc_bsdinfo()
                    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
                        newest = max(newest ?? 0, started)
                    }
                }
                let cpu = UInt64(Double(u.ri_user_time + u.ri_system_time) * tick)
                footprint += u.ri_phys_footprint
                if let before = previous[pid], cpu >= before { spent += Double(cpu - before) }
                if pid == root { own = Double(cpu) / 1e9 }
                seen[pid] = cpu
                count += 1
            }
            guard count > 0 else { continue }
            out[root] = Reading(
                footprint: footprint, cpuPercent: elapsed > 0 ? 100 * spent / elapsed : nil,
                cpuSeconds: own, processes: count, newestChild: newest)
        }
        previous = seen
        previousAt = now
        return out
    }
}

/// What this tool costs the machine: the app, the `live` snapshots it runs, and
/// the status line redraws in every session, as a share of one core over the
/// last few minutes.
final class SelfCost {
    private static let window: Double = 300
    private var appSamples: [(at: Double, cpu: Double)] = []
    private var redraws: [(at: Double, cpu: Double)] = []
    private var lastRedraw: [String: Double] = [:]
    private let started = Date().timeIntervalSince1970

    /// CPU of the app and of the children it has waited for: the snapshots.
    private func appCpu() -> Double {
        func seconds(_ who: Int32) -> Double {
            var r = rusage()
            getrusage(who, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec)
                + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        return seconds(RUSAGE_SELF) + seconds(RUSAGE_CHILDREN)
    }

    func footprint() -> UInt64 {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) == 0
            }
        }
        return ok ? info.ri_phys_footprint : 0
    }

    /// Each spool keeps only its latest redraw, so a redraw is counted when its
    /// timestamp moves. The first snapshot only sets the baseline.
    func record(_ sessions: [Session]) {
        let now = Date().timeIntervalSince1970
        let first = lastRedraw.isEmpty
        for session in sessions {
            guard let id = session.summary.session_id else { continue }
            if !first, let seen = lastRedraw[id], session.updated_at > seen, let cpu = session.redraw?.cpu_ms {
                redraws.append((now, cpu / 1000))
            }
            lastRedraw[id] = session.updated_at
        }
        appSamples.append((now, appCpu()))
        appSamples.removeAll { now - $0.at > Self.window }
        redraws.removeAll { now - $0.at > Self.window }
    }

    /// Shares of one core: (status line redraws, the app and its snapshots).
    func load() -> (redraws: Double, app: Double)? {
        let now = Date().timeIntervalSince1970
        let span = min(Self.window, now - started)
        guard span >= 30, let oldest = appSamples.first, let newest = appSamples.last, newest.at > oldest.at
        else { return nil }
        let app = 100 * (newest.cpu - oldest.cpu) / (newest.at - oldest.at)
        let drawn = 100 * redraws.reduce(0) { $0 + $1.cpu } / span
        return (drawn, app)
    }
}

// MARK: - Session events and sounds

/// The app's own files: the sound packs and their settings.
let supportDir: URL =
    (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library"))
    .appendingPathComponent("Agent Bar Hopping")
/// Where hooks/event.zsh leaves one file per Claude Code event.
let eventsDir = cacheDir.appendingPathComponent("events")

/// sounds.json in the support directory; written with these defaults when absent.
struct SoundSettings: Codable {
    var enabled = true
    /// A directory under packs/ holding an openpeon.json manifest and its sounds.
    var pack = "rick"
    var volume: Float = 0.35
    var categories: [String: Bool] = [
        "task.complete": true, "task.error": true, "input.required": true,
        "resource.limit": true, "user.spam": true,
    ]
    /// A reply that took less than this is not announced: you were watching.
    var silent_window_seconds: Double = 7
    /// This many prompts to one session inside the window is spam.
    var annoyed_threshold = 3
    var annoyed_window_seconds: Double = 10
    /// Per-session overrides of `enabled`, by session id: true plays for that
    /// session whatever the switch says, false mutes it. Dropped when the
    /// session ends.
    var sessions: [String: Bool] = [:]

    init() {}

    /// Every field optional, so a file written before a field existed still
    /// loads, with the default for what it lacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoundSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        pack = try c.decodeIfPresent(String.self, forKey: .pack) ?? d.pack
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? d.volume
        categories = try c.decodeIfPresent([String: Bool].self, forKey: .categories) ?? d.categories
        silent_window_seconds = try c.decodeIfPresent(Double.self, forKey: .silent_window_seconds) ?? d.silent_window_seconds
        annoyed_threshold = try c.decodeIfPresent(Int.self, forKey: .annoyed_threshold) ?? d.annoyed_threshold
        annoyed_window_seconds = try c.decodeIfPresent(Double.self, forKey: .annoyed_window_seconds) ?? d.annoyed_window_seconds
        sessions = try c.decodeIfPresent([String: Bool].self, forKey: .sessions) ?? d.sessions
    }
}

/// Whether this Mac can decode a sound file. Ogg Vorbis is the one format
/// packs use that depends on the system: Core Audio decodes it on macOS 15 and
/// not on older releases, so ask for its decoder rather than a version.
func playable(_ file: String) -> Bool {
    file.lowercased().hasSuffix(".ogg") ? vorbisDecodes : true
}

let vorbisDecodes: Bool = {
    var size: UInt32 = 0
    guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr else { return false }
    var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
    guard AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, &ids) == noErr else { return false }
    return ids.contains(0x766F_7262)  // 'vorb'
}()

// MARK: - Display settings (system-one verdict row)

/// display.json in the support directory, beside sounds.json: what the status
/// line draws beyond the segments Claude Code's own input carries. Written
/// with the default (off) when absent; the status line script reads it on
/// every redraw the same way it reads sounds.json and the usage cache.
struct DisplaySettings: Codable {
    var verdictRow = false
    /// Which hook's shadow log the status line row draws ('bash' | 'prompt' |
    /// 'stop'); empty is off, even when verdictRow is on. Default empty: a
    /// session that never picked a hook draws nothing.
    var verdictHook = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdictRow = try c.decodeIfPresent(Bool.self, forKey: .verdictRow) ?? false
        verdictHook = try c.decodeIfPresent(String.self, forKey: .verdictHook) ?? ""
    }
}

/// Owns display.json: the app's single writer, same pattern as sounds.json.
final class DisplayStore {
    private(set) var settings = DisplaySettings()
    private let file = supportDir.appendingPathComponent("display.json")

    init() {
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: file),
            let s = try? JSONDecoder().decode(DisplaySettings.self, from: data)
        {
            settings = s
        }
        save()
    }

    func update(_ change: (inout DisplaySettings) -> Void) {
        change(&settings)
        save()
    }

    private func save() {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic: the status line script reads this file on every redraw and
        // must never see half of it.
        try? encoder.encode(settings).write(to: file, options: .atomic)
    }
}

/// The colours a tag can take: few enough to tell apart at a glance down a
/// column, each light enough to read on the dark background.
struct TagColour {
    let name: String
    let hex: String

    var color: NSColor {
        let v = UInt32(hex, radix: 16) ?? 0x7D828F
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let all = [
        TagColour(name: "Red", hex: "E06C75"), TagColour(name: "Orange", hex: "D19A66"),
        TagColour(name: "Yellow", hex: "E5C07B"), TagColour(name: "Green", hex: "98C379"),
        TagColour(name: "Blue", hex: "61AFEF"), TagColour(name: "Purple", hex: "C678DD"),
        TagColour(name: "Grey", hex: "7D828F"),
    ]
}

/// A label with a colour, made once and put on any number of sessions.
struct Tag: Codable, Equatable {
    var name: String
    /// Written out so the status line script draws the same colour without a
    /// table of its own.
    var hex: String

    var color: NSColor { TagColour(name: "", hex: hex).color }
}

/// Everything under one directory gets these marks: the directory a session
/// was launched in, or any folder below it. The most specific rule applies.
struct TagRule: Codable, Equatable {
    /// Absolute, without a trailing slash.
    var dir: String
    var dots: [String] = []
    var tags: [String] = []

    init(dir: String) { self.dir = dir }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dir = try c.decode(String.self, forKey: .dir)
        dots = try c.decodeIfPresent([String].self, forKey: .dots) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    func covers(_ path: String) -> Bool { path == dir || path.hasPrefix(dir == "/" ? "/" : dir + "/") }
}

struct TagFile: Codable {
    var tags: [Tag] = []
    /// Session id to the named tags set on it by hand. Keyed by id because
    /// `claude --resume` keeps it: a session restarted after an update is
    /// still tagged.
    var sessions: [String: [String]] = [:]
    /// Session id to the preset colour dots set on it by hand, by hex.
    var dots: [String: [String]] = [:]
    var rules: [TagRule] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        sessions = Self.lists(c, CodingKeys.sessions)
        dots = Self.lists(c, CodingKeys.dots)
        rules = try c.decodeIfPresent([TagRule].self, forKey: .rules) ?? []
    }

    /// A list per session, or a single value from before a session could
    /// have several.
    private static func lists<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String: [String]] {
        if let many = try? c.decodeIfPresent([String: [String]].self, forKey: key) { return many }
        if let one = try? c.decodeIfPresent([String: String].self, forKey: key) { return one.mapValues { [$0] } }
        return [:]
    }
}

/// What the list is narrowed to: one preset dot, or one named tag.
enum TagFilter: Equatable {
    case dot(String)
    case tag(String)
}

/// Owns tags.json beside display.json: the app is its single writer, and the
/// status line script reads it on every redraw.
final class TagStore {
    private(set) var file = TagFile()
    private let url = supportDir.appendingPathComponent("tags.json")

    init() {
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(TagFile.self, from: data) {
            file = f
        }
    }

    var tags: [Tag] { file.tags }
    var rules: [TagRule] { file.rules }

    // MARK: By hand

    func manualDots(_ sessionId: String) -> [String] { file.dots[sessionId] ?? [] }
    func manualTags(_ sessionId: String) -> [String] { file.sessions[sessionId] ?? [] }

    func toggleDot(_ hex: String, for sessionId: String) {
        var dots = manualDots(sessionId)
        if let i = dots.firstIndex(of: hex) { dots.remove(at: i) } else { dots.append(hex) }
        file.dots[sessionId] = dots.isEmpty ? nil : dots
        save()
    }

    func toggleTag(_ name: String, for sessionId: String) {
        var names = manualTags(sessionId)
        if let i = names.firstIndex(of: name) { names.remove(at: i) } else { names.append(name) }
        file.sessions[sessionId] = names.isEmpty ? nil : names
        save()
    }

    /// Every dot and tag set by hand; a rule's marks stay.
    func clear(_ sessionId: String) {
        file.dots[sessionId] = nil
        file.sessions[sessionId] = nil
        save()
    }

    // MARK: Named tags

    /// A new tag, or the existing one of that name recoloured.
    func create(_ name: String, hex: String) {
        if let i = file.tags.firstIndex(where: { $0.name == name }) {
            file.tags[i].hex = hex
        } else {
            file.tags.append(Tag(name: name, hex: hex))
        }
        save()
    }

    /// Gone from every session and rule that had it.
    func delete(_ name: String) {
        file.tags.removeAll { $0.name == name }
        file.sessions = file.sessions.compactMapValues { names in
            let kept = names.filter { $0 != name }
            return kept.isEmpty ? nil : kept
        }
        for i in file.rules.indices { file.rules[i].tags.removeAll { $0 == name } }
        save()
    }

    // MARK: Rules

    /// The most specific rule over a launch directory, `~` or absolute.
    func rule(for projectDir: String?) -> TagRule? {
        guard let dir = projectDir.map({ ($0 as NSString).expandingTildeInPath }) else { return nil }
        return file.rules.filter { $0.covers(dir) }.max { $0.dir.count < $1.dir.count }
    }

    /// A rule for this directory, or the one it already has.
    func addRule(_ dir: String) -> Int {
        let clean = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        if let i = file.rules.firstIndex(where: { $0.dir == clean }) { return i }
        file.rules.append(TagRule(dir: clean))
        save()
        return file.rules.count - 1
    }

    func updateRule(_ index: Int, _ change: (inout TagRule) -> Void) {
        guard file.rules.indices.contains(index) else { return }
        change(&file.rules[index])
        save()
    }

    func removeRule(_ index: Int) {
        guard file.rules.indices.contains(index) else { return }
        file.rules.remove(at: index)
        save()
    }

    // MARK: What a session shows

    /// Its dots and tags, by hand and from its directory's rule together, in
    /// the preset order and the order the tags were made.
    func marks(_ sessionId: String?, _ projectDir: String?) -> (dots: [TagColour], tags: [Tag]) {
        let rule = rule(for: projectDir)
        let hexes = Set((sessionId.map(manualDots) ?? []) + (rule?.dots ?? []))
        let names = Set((sessionId.map(manualTags) ?? []) + (rule?.tags ?? []))
        return (TagColour.all.filter { hexes.contains($0.hex) }, file.tags.filter { names.contains($0.name) })
    }

    /// Whether a session passes the list's filter: any of its marks will do.
    func matches(_ filter: TagFilter?, _ sessionId: String?, _ projectDir: String?) -> Bool {
        guard let filter = filter else { return true }
        let m = marks(sessionId, projectDir)
        switch filter {
        case .dot(let hex): return m.dots.contains { $0.hex == hex }
        case .tag(let name): return m.tags.contains { $0.name == name }
        }
    }

    private func save() {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic: the status line script must never read half of it.
        try? encoder.encode(file).write(to: url, options: .atomic)
    }
}

/// A filled circle in a tag's colour, for menus.
func tagDot(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
}

/// Turns Claude Code's hook events into sounds, and remembers the one thing the
/// transcript cannot show: a permission prompt waiting on the user.
final class EventCenter {
    private var settings = SoundSettings()
    /// Sound files per category, from the pack's manifest.
    private var sounds: [String: [URL]] = [:]
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Which play is the latest, so only its end stops the engine.
    private var playCount = 0
    /// The last file per category, so a category never repeats itself.
    private var lastPlayed: [String: URL] = [:]
    /// The last completion in any session: several finishing together chime once.
    private var lastComplete: Double = 0
    private static let completeDebounceSeconds: Double = 5
    private var watcher: DispatchSourceFileSystemObject?
    private var promptStarted: [String: Double] = [:]
    private var prompts: [String: [Double]] = [:]
    /// When each session last asked for a permission, in epoch seconds.
    private(set) var permissionAt: [String: Double] = [:]
    /// Called on the main queue after events change what a row should show.
    var onChange: (() -> Void)?

    /// Events older than this when read were missed while the app was closed:
    /// too late to announce, and a stale permission would mislead.
    private static let freshSeconds: Double = 60

    init() {
        loadSettings()
        loadPack()
        try? fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let fd = open(eventsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            log("cannot watch \(eventsDir.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
        // A device change (wake, a display's audio coming and going) stops the
        // engine behind our back; drop the sound in flight rather than play into it.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.playCount += 1
            self.player.stop()
            self.engine.stop()
        }
        drain()
    }

    private let settingsFile = supportDir.appendingPathComponent("sounds.json")

    private func loadSettings() {
        if let data = try? Data(contentsOf: settingsFile),
            let s = try? JSONDecoder().decode(SoundSettings.self, from: data)
        {
            settings = s
        }
        save()
    }

    private func save() {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: settingsFile)
    }

    // MARK: Settings, for the controls

    var current: SoundSettings { settings }

    /// Applies a change and writes it straight away: there is no save button.
    func update(_ change: (inout SoundSettings) -> Void) {
        let pack = settings.pack
        change(&settings)
        if settings.pack != pack {
            sounds = [:]
            loadPack()
        }
        save()
    }

    /// Reads the pack again, for when its files changed under the same name.
    func reloadPack() {
        sounds = [:]
        loadPack()
    }

    /// Drops what was read of a pack, after it was installed again or removed.
    func forget(_ pack: String) {
        otherPacks[pack] = nil
        previewed = previewed.filter { !$0.key.hasPrefix(pack + "/") }
        if pack == settings.pack { reloadPack() }
    }

    /// The installed packs, by directory name.
    var packs: [String] {
        let dir = supportDir.appendingPathComponent("packs")
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// A sample of the pack, whatever the switches say: picking a pack should
    /// let you hear it.
    func preview() {
        play("task.complete", session: nil, force: true)
    }

    /// Where each pack's category preview is in its list, by "pack/category":
    /// previews play a pack's sounds in order, so each can be heard, where
    /// events pick at random.
    private var previewed: [String: Int] = [:]
    /// Installed packs other than the one in use, read when first previewed.
    private var otherPacks: [String: [String: [URL]]] = [:]

    private func sounds(of pack: String) -> [String: [URL]] {
        if pack == settings.pack { return sounds }
        if let read = otherPacks[pack] { return read }
        let read = Self.readPack(pack)
        otherPacks[pack] = read
        return read
    }

    func soundCount(_ category: String, pack: String? = nil) -> Int {
        sounds(of: pack ?? settings.pack)[category]?.count ?? 0
    }

    /// Plays the category's next sound in the pack's order, whatever the
    /// switches say. Returns its place, 1-based, and how many there are.
    func previewNext(_ category: String, pack: String? = nil) -> (index: Int, count: Int)? {
        let pack = pack ?? settings.pack
        guard let list = sounds(of: pack)[category], !list.isEmpty else { return nil }
        let key = pack + "/" + category
        let i = (previewed[key] ?? 0) % list.count
        previewed[key] = i + 1
        playFile(list[i])
        return (i + 1, list.count)
    }

    func override(for session: String) -> Bool? { settings.sessions[session] }

    func setOverride(_ value: Bool?, for session: String) {
        update { $0.sessions[session] = value }
    }

    /// Overrides of sessions no longer open go.
    func prune(keeping live: Set<String>) {
        guard settings.sessions.keys.contains(where: { !live.contains($0) }) else { return }
        update { $0.sessions = $0.sessions.filter { live.contains($0.key) } }
    }

    private func loadPack() {
        sounds = Self.readPack(settings.pack)
        if sounds.isEmpty { log("no playable sound pack at packs/\(settings.pack)") }
    }

    /// Reads an openpeon (CESP 1.0) manifest the way peon-ping does: a path with
    /// a slash is relative to the pack, a bare name lives in sounds/, and nothing
    /// may resolve outside the pack. A malformed entry is skipped, not the whole
    /// pack, and so is a file this Mac cannot decode.
    static func readPack(_ name: String) -> [String: [URL]] {
        let dir = supportDir.appendingPathComponent("packs").appendingPathComponent(name)
        let manifest = ["openpeon.json", "manifest.json"].lazy
            .compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .first
        guard let categories = manifest?["categories"] as? [String: Any] else { return [:] }
        let root = dir.standardizedFileURL.path + "/"
        var found: [String: [URL]] = [:]
        for (category, value) in categories {
            let entries = ((value as? [String: Any])?["sounds"] as? [Any]) ?? []
            let files: [URL] = entries.compactMap { entry in
                guard let file = (entry as? [String: Any])?["file"] as? String, !file.isEmpty else { return nil }
                let url = (file.contains("/") ? dir.appendingPathComponent(file)
                    : dir.appendingPathComponent("sounds").appendingPathComponent(file)).standardizedFileURL
                guard url.path.hasPrefix(root), playable(url.path), fm.fileExists(atPath: url.path) else { return nil }
                return url
            }
            if !files.isEmpty { found[category] = files }
        }
        return found
    }

    /// Reads every waiting event in arrival order, then deletes it.
    private func drain() {
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir.path) else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let file = eventsDir.appendingPathComponent(name)
            defer { try? fm.removeItem(at: file) }
            let at = (Double(name.prefix { $0.isNumber }) ?? 0) / 1e6
            guard now - at < Self.freshSeconds,
                let data = try? Data(contentsOf: file),
                let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            changed = handle(event, at: at) || changed
        }
        if changed { onChange?() }
    }

    /// Returns whether the event changed what a row shows.
    /// The events hooks/event.zsh is registered for; anything else means a name
    /// changed under us.
    private static let registered: Set<String> = [
        "UserPromptSubmit", "Stop", "StopFailure", "PostToolUseFailure", "PermissionRequest", "PreToolUse",
        "Notification", "PreCompact", "SessionEnd",
    ]

    private func handle(_ event: [String: Any], at: Double) -> Bool {
        let name = event["hook_event_name"] as? String ?? ""
        let session = event["session_id"] as? String ?? ""
        checkFormat(
            "hooks/event", Self.registered.contains(name) && !session.isEmpty,
            name.isEmpty || session.isEmpty
                ? "hook events have no hook_event_name or session_id" : "unknown hook event \(name)",
            example: event.keys.sorted().joined(separator: ","))
        switch name {
        case "UserPromptSubmit":
            promptStarted[session] = at
            let recent = (prompts[session] ?? []).filter { at - $0 < settings.annoyed_window_seconds } + [at]
            prompts[session] = recent
            // Every prompt past the threshold inside the window is spam again.
            if recent.count >= settings.annoyed_threshold { play("user.spam", session: session) }
            return permissionAt.removeValue(forKey: session) != nil
        case "Stop":
            let started = promptStarted.removeValue(forKey: session)
            let quick = started.map { at - $0 < settings.silent_window_seconds } ?? false
            if !quick && at - lastComplete >= Self.completeDebounceSeconds {
                play("task.complete", session: session)
                lastComplete = at
            }
            return permissionAt.removeValue(forKey: session) != nil
        case "StopFailure":
            play("task.error", session: session)
        case "PostToolUseFailure":
            // Every tool reports failures here, and a shell command with an error
            // is the one worth hearing about.
            if event["tool_name"] as? String == "Bash", let error = event["error"] as? String, !error.isEmpty {
                play("task.error", session: session)
            }
        case "PermissionRequest":
            play("input.required", session: session)
            permissionAt[session] = at
            return true
        case "PreToolUse":
            // Registered only for AskUserQuestion and ExitPlanMode: a question
            // or a plan now waits on the user.
            play("input.required", session: session)
        case "Notification":
            if event["notification_type"] as? String == "elicitation_dialog" { play("input.required", session: session) }
        case "PreCompact":
            play("resource.limit", session: session)
        default: break
        }
        return false
    }

    /// One sound at a time: a new one cuts the last short, as the events it
    /// announces are newer. Never the same file twice running when a category
    /// has more than one.
    private func play(_ category: String, session: String?, force: Bool = false) {
        // A session's own override beats the switch, both ways.
        let on = session.flatMap { settings.sessions[$0] } ?? settings.enabled
        guard force || (on && settings.categories[category] == true),
            var choices = sounds[category], !choices.isEmpty
        else { return }
        if choices.count > 1, let last = lastPlayed[category] { choices.removeAll { $0 == last } }
        guard let url = choices.randomElement() else { return }
        playFile(url)
        lastPlayed[category] = url
    }

    /// Through an engine rather than NSSound: NSSound and AVAudioPlayer open an
    /// Ogg Vorbis file and then refuse to play it, where decoding it into a
    /// buffer works. The engine runs only while a sound does, so the audio
    /// device is not held open between them.
    func playFile(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
            let frames = AVAudioFrameCount(exactly: file.length),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
            (try? file.read(into: buffer)) != nil
        else { return log("cannot decode \(url.lastPathComponent)") }
        player.stop()
        if player.engine == nil { engine.attach(player) }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        do { if !engine.isRunning { try engine.start() } } catch { return log("audio engine: \(error.localizedDescription)") }
        playCount += 1
        let count = playCount
        player.volume = settings.volume
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.playCount == count else { return }
                self.player.stop()
                self.engine.stop()
            }
        }
        // play() on a stopped engine raises an Objective-C exception Swift cannot
        // catch, and a device change can stop it between start() and here.
        guard engine.isRunning else { return log("audio engine stopped before play") }
        player.play()
    }
}

/// The newest Claude Code release, from npm's public registry: one small request
/// every six hours at most, cached in the cache dir so a relaunch does not ask
/// again, and an hour's pause after a failure rather than a retry per refresh.
final class LatestVersion {
    private let file = cacheDir.appendingPathComponent("claude-latest.json")
    private static let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")!
    private static let freshFor: Double = 6 * 3600
    private static let pauseAfterFailure: Double = 3600
    private struct Cache: Codable {
        var version: String?
        var fetched_at: Double
        var failed_at: Double?
    }
    private var cache: Cache
    private var inFlight = false
    var version: String? { cache.version }
    /// Called on the main queue when a fetch brought a new version.
    var onChange: (() -> Void)?

    init() {
        cache =
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            ?? Cache(version: nil, fetched_at: 0, failed_at: nil)
    }

    func refreshIfDue() {
        let now = Date().timeIntervalSince1970
        guard !inFlight, now - cache.fetched_at > Self.freshFor,
            now - (cache.failed_at ?? 0) > Self.pauseAfterFailure
        else { return }
        inFlight = true
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let version = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["version"] as? String
            let status = (response as? HTTPURLResponse)?.statusCode
            let ok = status == 200 && version != nil
            // An answer without a version is a changed format; no answer is an outage.
            if let status = status {
                checkFormat(
                    "npm/latest", ok, "npm registry: HTTP \(status)\(version == nil ? ", no version field" : "")")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                let now = Date().timeIntervalSince1970
                if ok {
                    let changed = self.cache.version != version
                    self.cache = Cache(version: version, fetched_at: now, failed_at: nil)
                    if changed { self.onChange?() }
                } else {
                    self.cache.failed_at = now
                    log("latest version: fetch failed")
                }
                if let data = try? JSONEncoder().encode(self.cache) { try? data.write(to: self.file) }
            }
        }.resume()
    }
}

// MARK: - Sound pack registry

/// One pack in the openpeon registry, as far as browsing and installing needs.
struct RegistryPack: Decodable {
    let name: String
    let display_name: String?
    let description: String?
    let language: String?
    let sound_count: Int?
    let total_size_bytes: Int?
    let source_repo: String
    let source_ref: String
    let source_path: String?
    let manifest_sha256: String?
    /// The events the pack has sounds for.
    let categories: [String]?

    /// An installed pack the registry does not list.
    init(local name: String) {
        self.name = name
        display_name = nil
        description = "installed here, not in the registry"
        language = nil
        sound_count = nil
        total_size_bytes = nil
        source_repo = ""
        source_ref = ""
        source_path = nil
        manifest_sha256 = nil
        categories = nil
    }
}

/// Browses and installs packs from the openpeon registry, the one peon-ping's
/// `peon packs install` uses. The index is fetched when the browser opens, at
/// most daily, and an hour's pause follows a failure. An install fetches the
/// manifest and each sound from the pack's GitHub repo — what peon-ping does —
/// but also checks the sha256 the registry and the manifest publish, which
/// peon-ping does not. It stops at the first refusal, skips ogg (macOS cannot
/// play it), and builds the pack in a hidden directory, so a failed install
/// leaves nothing half-made in packs/.
final class PackStore {
    private static let indexURL = URL(string: "https://peonping.github.io/registry/index.json")!
    private let cache = supportDir.appendingPathComponent("registry.json")
    private let packsDir = supportDir.appendingPathComponent("packs")
    private var failedAt: Double = 0

    /// The cached index, whatever its age.
    var packs: [RegistryPack] {
        struct Index: Decodable { let packs: [RegistryPack] }
        guard let data = try? Data(contentsOf: cache) else { return [] }
        return (try? JSONDecoder().decode(Index.self, from: data))?.packs ?? []
    }

    var installed: Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: packsDir.path)) ?? []).filter { !$0.hasPrefix(".") })
    }

    /// Fetches the index if the cached one is a day old; calls back on the main
    /// queue either way, with an error when there was one.
    func refreshIndex(_ done: @escaping (String?) -> Void) {
        let age = Date().timeIntervalSince(
            ((try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date) ?? .distantPast)
        let now = Date().timeIntervalSince1970
        guard age > 86400, now - failedAt > 3600 else { return done(nil) }
        fetch(Self.indexURL) { [weak self] data, error in
            guard let self = self else { return }
            let decoded = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = (decoded?["packs"] as? [Any])?.isEmpty == false
            if data != nil { checkFormat("registry/index", ok, "sound pack registry: no packs[] in its index") }
            if let data = data, ok {
                try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
                try? data.write(to: self.cache, options: .atomic)
                done(nil)
            } else {
                self.failedAt = now
                done(error ?? "the registry answered in an unexpected shape")
            }
        }
    }

    /// Where the pack's files are on GitHub, or nil for a path that could escape.
    private static func base(_ pack: RegistryPack) -> String? {
        guard !pack.source_repo.isEmpty else { return nil }
        var base = "https://raw.githubusercontent.com/\(pack.source_repo)/\(pack.source_ref)"
        if let path = pack.source_path, !path.isEmpty, path != "." {
            guard safe(path) else { return nil }
            base += "/" + path
        }
        return base
    }

    /// The manifest's sounds per category, as peon-ping names them under
    /// sounds/: a path there keeps its folders, anything else is its base name.
    /// Unsafe names and files this Mac cannot decode are left out.
    private static func sounds(_ manifest: Data) -> [String: [(rel: String, sha: String?)]]? {
        guard let root = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
            let categories = root["categories"] as? [String: Any]
        else { return nil }
        var found: [String: [(rel: String, sha: String?)]] = [:]
        for (name, value) in categories {
            guard let category = value as? [String: Any] else { continue }
            for case let sound as [String: Any] in (category["sounds"] as? [Any]) ?? [] {
                guard let file = sound["file"] as? String else { continue }
                let rel = file.hasPrefix("sounds/") ? String(file.dropFirst(7)) : (file as NSString).lastPathComponent
                guard safe(rel), playable(rel) else { continue }
                found[name, default: []].append((rel, sound["sha256"] as? String))
            }
        }
        return found
    }

    /// The pack's manifest, checked against the registry's checksum.
    private func manifest(_ pack: RegistryPack, base: String, _ done: @escaping (Data?, String?) -> Void) {
        fetch(URL(string: base + "/openpeon.json")!) { data, error in
            guard let manifest = data else { return done(nil, error ?? "no manifest") }
            if let expected = pack.manifest_sha256, Self.sha256(manifest) != expected.lowercased() {
                return done(nil, "the manifest does not match the registry's checksum")
            }
            done(manifest, nil)
        }
    }

    private static func url(base: String, _ rel: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?!()"))
        return rel.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: base + "/sounds/" + $0) }
    }

    /// Previews of packs not installed: each manifest's sounds once read, and
    /// each sound fetched only the first time it is played.
    private var previewManifests: [String: [String: [(rel: String, sha: String?)]]] = [:]
    private let previewDir = cacheDir.appendingPathComponent("pack-previews")

    /// Fetches the category's sound at `index` (wrapping) of a pack that is not
    /// installed: one request for the manifest the first time, then one for
    /// the sound unless it was fetched before. Calls back with the file and
    /// its place, 1-based, of how many, or an error.
    func previewSound(
        _ pack: RegistryPack, _ category: String, index: Int,
        _ done: @escaping (_ file: URL?, _ place: Int, _ count: Int, _ error: String?) -> Void
    ) {
        guard let base = Self.base(pack), Self.safe(pack.name), !pack.name.contains("/") else {
            return done(nil, 0, 0, "unsafe source path")
        }
        guard let listed = previewManifests[pack.name] else {
            return manifest(pack, base: base) { [weak self] data, error in
                guard let self = self else { return }
                guard let data = data else { return done(nil, 0, 0, error) }
                guard let sounds = Self.sounds(data) else { return done(nil, 0, 0, "the manifest has no categories") }
                self.previewManifests[pack.name] = sounds
                self.previewSound(pack, category, index: index, done)
            }
        }
        guard let list = listed[category], !list.isEmpty else { return done(nil, 0, 0, "no sounds for this") }
        let i = index % list.count
        let (rel, sha) = list[i]
        let dest = previewDir.appendingPathComponent(pack.name).appendingPathComponent(rel)
        if fm.fileExists(atPath: dest.path) { return done(dest, i + 1, list.count, nil) }
        guard let url = Self.url(base: base, rel) else { return done(nil, 0, 0, "bad file name \(rel)") }
        fetch(url) { data, error in
            guard let data = data else { return done(nil, 0, 0, "\(rel): \(error ?? "no data")") }
            if let sha = sha, Self.sha256(data) != sha.lowercased() {
                return done(nil, 0, 0, "\(rel) does not match its checksum")
            }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: dest) } catch { return done(nil, 0, 0, error.localizedDescription) }
            done(dest, i + 1, list.count, nil)
        }
    }

    /// Installs a pack; `progress` gets (done, total) sounds, `done` an error or nil.
    func install(
        _ pack: RegistryPack, progress: @escaping (Int, Int) -> Void, done: @escaping (String?) -> Void
    ) {
        guard let base = Self.base(pack) else { return done("unsafe source path") }
        let staging = packsDir.appendingPathComponent(".\(pack.name).partial")
        try? fm.removeItem(at: staging)
        manifest(pack, base: base) { [weak self] data, error in
            guard let self = self else { return }
            guard let manifest = data else { return done(error) }
            guard let categories = Self.sounds(manifest) else { return done("the manifest has no categories") }
            // Each sound once, though several events may share it.
            var files: [(rel: String, sha: String?)] = []
            var seen = Set<String>()
            for sound in categories.values.joined() where seen.insert(sound.rel).inserted { files.append(sound) }
            guard !files.isEmpty else { return done("no sounds macOS can play") }
            do {
                try fm.createDirectory(at: staging.appendingPathComponent("sounds"), withIntermediateDirectories: true)
                try manifest.write(to: staging.appendingPathComponent("openpeon.json"))
            } catch { return done(error.localizedDescription) }
            // One at a time: a pack is a few dozen small files, and a refusal
            // should end it before the next request goes out.
            func next(_ i: Int) {
                progress(i, files.count)
                guard i < files.count else {
                    let target = self.packsDir.appendingPathComponent(pack.name)
                    try? fm.removeItem(at: target)
                    do { try fm.moveItem(at: staging, to: target) } catch { return done(error.localizedDescription) }
                    return done(nil)
                }
                let (rel, sha) = files[i]
                guard let url = Self.url(base: base, rel) else {
                    try? fm.removeItem(at: staging)
                    return done("bad file name \(rel)")
                }
                self.fetch(url) { data, error in
                    guard let data = data else {
                        try? fm.removeItem(at: staging)
                        return done("\(rel): \(error ?? "no data")")
                    }
                    if let sha = sha, Self.sha256(data) != sha.lowercased() {
                        try? fm.removeItem(at: staging)
                        return done("\(rel) does not match its checksum")
                    }
                    let dest = staging.appendingPathComponent("sounds").appendingPathComponent(rel)
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: dest)
                    next(i + 1)
                }
            }
            next(0)
        }
    }

    /// Deletes an installed pack's directory.
    func remove(_ name: String) -> String? {
        guard Self.safe(name), !name.contains("/") else { return "unsafe pack name" }
        do {
            try fm.removeItem(at: packsDir.appendingPathComponent(name))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func safe(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9._?!() /-]+$", options: .regularExpression) != nil
            && !name.contains("..") && !name.hasPrefix("/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A GET whose answer arrives on the main queue: the body on a 200, else why not.
    private func fetch(_ url: URL, _ done: @escaping (Data?, String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                if status == 200, let data = data { return done(data, nil) }
                done(nil, status.map { "HTTP \($0)" } ?? error?.localizedDescription ?? "no answer")
            }
        }.resume()
    }
}

/// The global sound settings as controls: the switch and the volume on one
/// row, which events sound on another, each with a ▶ to hear it. The sessions
/// window and the pack browser each hold a copy; a change in either redraws
/// both. The app's own colours throughout, not the system accent: a blue
/// switch and blue boxes would be the only colour that means nothing.
final class SoundControls: NSObject {
    /// The events that can sound, in the order the toggles show them.
    static let events: [(key: String, title: String)] = [
        ("task.complete", "done"), ("task.error", "error"), ("input.required", "needs you"),
        ("resource.limit", "limit"), ("user.spam", "spam"),
    ]
    static func title(_ key: String) -> String { events.first { $0.key == key }?.title ?? key }
    /// Posted after a control changes a setting or the pack in use changes.
    static let changed = Notification.Name("SoundControlsChanged")

    let volumeRow = NSStackView()
    let eventRow = NSStackView()
    private let center: EventCenter
    /// The speaker glyph the Sound column uses, as the switch for every session.
    private let soundSwitch = NSButton(title: "", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0.35, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "")
    private var eventBoxes: [NSButton] = []
    private var previewButtons: [NSButton] = []

    /// What ▶ plays and whether it has anything to; the pack in use when unset.
    var previewer: ((String) -> Void)?
    var previewable: ((String) -> Bool)?
    /// What a volume change plays; the pack in use when unset.
    var sampler: (() -> Void)?
    /// Where a line of feedback goes.
    var report: (String) -> Void = { _ in }

    /// `roomy` for the pack browser, where ▶ is the point of the window: the
    /// largest glyph, on a target the size of a small button. The header's has
    /// to fit beside the quotas, so it is smaller, on a smaller target.
    init(center: EventCenter, roomy: Bool = false) {
        self.center = center
        super.init()
        soundSwitch.isBordered = false
        soundSwitch.target = self
        soundSwitch.action = #selector(soundSwitched)
        volumeSlider.controlSize = .mini
        volumeSlider.trackFillColor = Palette.dim
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        volumeSlider.setAccessibilityLabel("Volume")
        // The share, as the quota bars carry theirs; muted reads 0%, because
        // that is what comes out.
        volumeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeLabel.alignment = .right
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true
        for view in [soundSwitch, volumeSlider, volumeLabel] { volumeRow.addArrangedSubview(view) }
        volumeRow.spacing = 8

        // Text toggles rather than checkboxes: ● on, ○ off, in the palette.
        eventBoxes = Self.events.map { event in
            let box = NSButton(title: "", target: self, action: #selector(eventToggled))
            box.isBordered = false
            box.identifier = NSUserInterfaceItemIdentifier(event.key)
            return box
        }
        // A ▶ beside each: its sounds one by one, in the pack's order.
        previewButtons = Self.events.map { event in
            let play = NSButton(title: "", target: self, action: #selector(previewEvent))
            play.isBordered = false
            play.attributedTitle = NSAttributedString(
                string: "▶",
                attributes: [.font: NSFont.systemFont(ofSize: roomy ? 13 : 9), .foregroundColor: roomy ? Palette.text : Palette.dim])
            play.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                play.widthAnchor.constraint(equalToConstant: roomy ? 26 : 18),
                play.heightAnchor.constraint(equalToConstant: roomy ? 22 : 18),
            ])
            play.identifier = NSUserInterfaceItemIdentifier(event.key)
            play.toolTip = "Play the next \(event.title) sound"
            play.setAccessibilityLabel("Preview \(event.title) sounds")
            return play
        }
        for (box, play) in zip(eventBoxes, previewButtons) {
            let pair = NSStackView(views: [box, play])
            pair.spacing = 2
            // ▶ centres on the label: on a shared baseline it rides low.
            pair.alignment = .centerY
            eventRow.addArrangedSubview(pair)
        }
        eventRow.spacing = roomy ? 6 : 8
        redraw()
        NotificationCenter.default.addObserver(
            forName: Self.changed, object: nil, queue: .main) { [weak self] _ in self?.redraw() }
    }

    /// Everything from the settings, and ▶ only where there is a sound to play.
    func redraw() {
        let settings = center.current
        let on = settings.enabled
        soundSwitch.attributedTitle = NSAttributedString(
            string: on ? "\u{F057E}" : "\u{F0581}",
            attributes: [.font: barFont, .foregroundColor: on ? Palette.text : Palette.dim])
        soundSwitch.toolTip = on ? "Sounds on — click to turn them off" : "Sounds off — click to turn them on"
        soundSwitch.setAccessibilityLabel("Sounds for every session, \(on ? "on" : "off")")
        volumeSlider.floatValue = settings.volume
        let percent = on ? Int((settings.volume * 100).rounded()) : 0
        volumeLabel.stringValue = "\(percent)%"
        volumeLabel.textColor = percent == 0 ? Palette.dim : Palette.text
        volumeLabel.setAccessibilityLabel("Volume \(percent) percent")
        for box in eventBoxes {
            let key = box.identifier?.rawValue ?? ""
            let on = settings.categories[key] == true
            box.attributedTitle = NSAttributedString(
                string: (on ? "● " : "○ ") + Self.title(key),
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: on ? Palette.text : Palette.dim])
            box.setAccessibilityLabel("\(Self.title(key)) sounds, \(on ? "on" : "off")")
        }
        for play in previewButtons {
            let key = play.identifier?.rawValue ?? ""
            play.isEnabled = previewable?(key) ?? (center.soundCount(key) > 0)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    @objc private func soundSwitched() {
        center.update { $0.enabled.toggle() }
        changed()
    }

    @objc private func volumeChanged() {
        let volume = volumeSlider.floatValue
        // Dragged to nothing is muted, and up from nothing is on: the switch
        // says so too.
        center.update {
            $0.volume = volume
            if volume == 0 { $0.enabled = false } else if !$0.enabled { $0.enabled = true }
        }
        changed()
        if let sampler = sampler { sampler() } else { center.preview() }
    }

    @objc private func eventToggled(_ box: NSButton) {
        guard let key = box.identifier?.rawValue else { return }
        center.update { $0.categories[key] = $0.categories[key] != true }
        changed()
    }

    @objc private func previewEvent(_ play: NSButton) {
        guard let key = play.identifier?.rawValue else { return }
        if let previewer = previewer { return previewer(key) }
        guard let place = center.previewNext(key) else { return }
        report("\(center.current.pack) · \(Self.title(key)) \(place.index) of \(place.count)")
    }
}

/// The registry, searchable, in a window of its own, with the installed packs
/// first: pick one to hear it with the same controls the sessions window has,
/// then Use it, or Install it first.
final class PackBrowser: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: PackStore
    private let events: EventCenter
    private let controls: SoundControls
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Install", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var shown: [RegistryPack] = []
    private var installed: Set<String> = []
    private var busy = false
    /// Where each not-installed pack's category preview is, by "pack/category".
    private var previewPlace: [String: Int] = [:]

    init(store: PackStore, events: EventCenter) {
        self.store = store
        self.events = events
        controls = SoundControls(center: events, roomy: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sound packs"
        // The controls draw in the sessions window's palette, which is dark.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 560, height: 300)
        super.init(window: window)
        build()
        status.stringValue = "Loading the registry…"
        filter(selecting: events.current.pack)
        store.refreshIndex { [weak self] error in
            guard let self = self else { return }
            self.filter(selecting: self.selected?.name ?? events.current.pack)
            if let error = error { self.status.stringValue = "Registry not refreshed: \(error)" }
        }
        NotificationCenter.default.addObserver(
            forName: SoundControls.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var selected: RegistryPack? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search name, language or description"
        search.delegate = self
        let columns: [(String, String, CGFloat)] = [
            ("name", "Pack", 220), ("language", "Lang", 50), ("sounds", "Sounds", 60), ("size", "Size", 70),
            ("installed", "", 60),
        ]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(act)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        actionButton.target = self
        actionButton.action = #selector(act)
        actionButton.keyEquivalent = "\r"
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        controls.previewer = { [weak self] key in self?.preview(key) }
        controls.previewable = { [weak self] key in self?.canPreview(key) ?? false }
        controls.sampler = { [weak self] in self?.sample() }
        controls.report = { [weak self] line in self?.status.stringValue = line }
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let soundRow = NSStackView(views: [controls.volumeRow, gap, controls.eventRow])
        soundRow.distribution = .fill
        for view in [search, scroll, soundRow, status, actionButton, removeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: soundRow.topAnchor, constant: -10),
            soundRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            soundRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            soundRow.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -10),
            actionButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            actionButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            removeButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -12),
        ])
    }

    /// Opens on the pack in use, whatever was searched last time.
    func present() {
        search.stringValue = ""
        filter(selecting: events.current.pack)
        showWindow(nil)
        window?.makeFirstResponder(table)
    }

    func controlTextDidChange(_ obj: Notification) { filter(selecting: selected?.name) }

    /// The installed packs first, those the registry does not list among them,
    /// then the rest in the registry's order.
    private func filter(selecting name: String?) {
        installed = store.installed
        let registry = store.packs
        let listed = Set(registry.map(\.name))
        let local = installed.subtracting(listed).sorted().map { RegistryPack(local: $0) }
        let all = local + registry
        let term = search.stringValue.lowercased()
        let matching = all.filter { pack in
            term.isEmpty
                || [pack.name, pack.display_name, pack.language, pack.description].compactMap { $0 }
                    .contains { $0.lowercased().contains(term) }
        }
        shown = matching.filter { installed.contains($0.name) } + matching.filter { !installed.contains($0.name) }
        table.reloadData()
        if let name = name, let row = shown.firstIndex(where: { $0.name == name }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        refresh()
        guard !busy else { return }
        if selected != nil { describeSelected() } else {
            status.stringValue = "\(shown.count) of \(all.count) packs · \(installed.count) installed"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refresh()
        if !busy { describeSelected() }
    }

    /// The status line names the selected pack, and whether it is here: the
    /// ▶s play whichever pack this says.
    private func describeSelected() {
        guard let pack = selected else { return }
        let name = pack.display_name ?? pack.name
        let where_ = pack.name == events.current.pack ? "in use"
            : installed.contains(pack.name) ? "installed"
            : "not installed" + (pack.sound_count.map { " · \($0) sounds" } ?? "")
                + (pack.total_size_bytes.map { ", \(bytes(UInt64($0)))" } ?? "")
        status.stringValue = "\(name) — \(where_)"
    }

    /// The buttons and the ▶s for the selected pack, and the in-use mark.
    private func refresh() {
        let pack = selected
        let current = events.current.pack
        let isInstalled = pack.map { installed.contains($0.name) } == true
        if pack?.name == current {
            actionButton.title = "In use"
            actionButton.isEnabled = false
        } else {
            actionButton.title = isInstalled ? "Use" : "Install"
            actionButton.isEnabled = !busy && pack != nil
        }
        removeButton.isEnabled = !busy && isInstalled && pack?.name != current
        controls.redraw()
        if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "installed" }),
            !shown.isEmpty
        {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shown.count), columnIndexes: [column])
        }
    }

    private func canPreview(_ key: String) -> Bool {
        guard let pack = selected else { return false }
        if installed.contains(pack.name) { return events.soundCount(key, pack: pack.name) > 0 }
        return pack.categories?.contains(key) ?? true
    }

    /// The selected pack's next sound for the event: from disk when installed,
    /// else fetched from the pack's repo the first time it is played.
    private func preview(_ key: String) {
        guard let pack = selected else { return }
        let title = SoundControls.title(key)
        let name = pack.display_name ?? pack.name
        if installed.contains(pack.name) {
            guard let place = events.previewNext(key, pack: pack.name) else { return }
            status.stringValue = "\(name) · \(title) \(place.index) of \(place.count)"
            return
        }
        let slot = pack.name + "/" + key
        let index = previewPlace[slot] ?? 0
        status.stringValue = "\(name) · \(title): fetching from GitHub…"
        store.previewSound(pack, key, index: index) { [weak self] file, place, count, error in
            guard let self = self else { return }
            guard let file = file else {
                self.status.stringValue = "\(name) · \(title): \(error ?? "no sound")"
                return
            }
            self.previewPlace[slot] = place
            self.events.playFile(file)
            self.status.stringValue = "\(name) · \(title) \(place) of \(count), not installed"
        }
    }

    /// A volume change plays the selected pack when its sounds are here, and
    /// the pack in use otherwise: a slider is no reason to fetch anything.
    private func sample() {
        if let pack = selected, installed.contains(pack.name), events.previewNext("task.complete", pack: pack.name) != nil {
            return
        }
        events.preview()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue, row < shown.count else { return nil }
        let pack = shown[row]
        let text: String
        switch key {
        case "name": text = pack.display_name ?? pack.name
        case "language": text = pack.language ?? ""
        case "sounds": text = pack.sound_count.map(String.init) ?? ""
        case "size": text = pack.total_size_bytes.map { bytes(UInt64($0)) } ?? ""
        case "installed":
            text = pack.name == events.current.pack ? "in use" : installed.contains(pack.name) ? "✓" : ""
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = key == "name" ? [pack.name, pack.description].compactMap { $0 }.joined(separator: "\n") : nil
        field.translatesAutoresizingMaskIntoConstraints = false
        // In a cell of its own the text sits at the top of a taller row; centred
        // in a holder it sits on the row's middle line.
        let cell = NSView()
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Return, a double-click and the button: use an installed pack, install
    /// one that is not and use it.
    @objc private func act() {
        guard !busy, let pack = selected, pack.name != events.current.pack else { return }
        if installed.contains(pack.name) { return use(pack.name) }
        busy = true
        refresh()
        // Says what it is about to fetch before it does.
        status.stringValue = "\(pack.name): \(pack.sound_count.map { "\($0) sounds" } ?? "sounds")"
            + (pack.total_size_bytes.map { ", \(bytes(UInt64($0)))" } ?? "") + " from GitHub…"
        store.install(pack, progress: { [weak self] done, total in
            self?.status.stringValue = "\(pack.name): \(done) of \(total)"
        }, done: { [weak self] error in
            guard let self = self else { return }
            self.busy = false
            if let error = error {
                self.status.stringValue = "\(pack.name) not installed: \(error)"
                self.refresh()
            } else {
                self.events.forget(pack.name)
                self.use(pack.name)
                self.filter(selecting: pack.name)
            }
        })
    }

    private func use(_ name: String) {
        events.update { $0.pack = name }
        NotificationCenter.default.post(name: SoundControls.changed, object: nil)
        events.preview()
        describeSelected()
    }

    @objc private func removeSelected() {
        guard !busy, let pack = selected, installed.contains(pack.name) else { return }
        // Deleting files: asked first, and never the pack now in use.
        guard pack.name != events.current.pack else { return }
        let ask = NSAlert()
        ask.messageText = "Remove the \(pack.display_name ?? pack.name) pack?"
        ask.informativeText = "Its sounds are deleted from disk. You can install it again from here."
        ask.addButton(withTitle: "Remove")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        if let error = store.remove(pack.name) {
            status.stringValue = "\(pack.name) not removed: \(error)"
        } else {
            events.forget(pack.name)
            filter(selecting: pack.name)
        }
    }
}

func bytes(_ n: UInt64) -> String {
    let mb = Double(n) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    // Under a megabyte, "0 MB" says nothing; a pack of 440 KB is not nothing.
    if mb < 1 { return "\(Int((Double(n) / 1024).rounded())) KB" }
    return "\(Int(mb.rounded())) MB"
}

/// CPU time as the grid spells durations: 45s, 12m, 2.5h.
func cpuTime(_ seconds: Double) -> String {
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return trimmed(seconds / 3600, "h")
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
    static let blue = NSColor(srgbRed: 0.494, green: 0.690, blue: 0.918, alpha: 1)
    /// Claude Code's own orange, for the ✻ it draws beside a pending agent.
    static let orange = NSColor(srgbRed: 215 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)

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

/// A whole number keeps no decimal: "2.0d" claims a precision that one decimal
/// place in days — a 2.4 hour step — does not have.
func trimmed(_ value: Double, _ unit: String) -> String {
    let shown = String(format: "%.1f", value)
    return (shown.hasSuffix(".0") ? String(shown.dropLast(2)) : shown) + unit
}

func until(_ epochMs: Double?) -> String {
    guard let ms = epochMs else { return "" }
    let s = Int(ms / 1000 - Date().timeIntervalSince1970)
    if s <= 0 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return trimmed(Double(s) / 3600, "h") }
    return trimmed(Double(s) / 86400, "d")
}

/// The moment itself, in the Launched-at column's form: "09/22 14:30".
func clock(_ epochMs: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MM/dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: epochMs / 1000))
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
    runScript(script, label: "focus \(tty)")
    // The script selects the tab, but a hotkey window hides again unless iTerm is
    // the active app — and AppleScript's own `activate` makes iTerm open a fresh
    // tab when that window is hidden.
    bringITermForward(label: "focus \(tty)")
}

/// The shell command that opens a finished session again: from the directory it
/// was launched in, since Claude Code files a transcript under that directory,
/// and with the model, effort and permission mode it last ran.
func resumeCommand(_ s: Summary, mode: String?) -> String? {
    guard let id = s.session_id, let dir = s.project_dir else { return nil }
    let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var parts = ["cd", quote((dir as NSString).expandingTildeInPath), "&&", "claude", "--resume", id]
    if let model = s.model_id { parts += ["--model", quote(model)] }
    if let effort = s.effort { parts += ["--effort", effort] }
    // The transcript still says `default` for what the command line calls `manual`.
    if let mode = mode { parts += ["--permission-mode", mode == "default" ? "manual" : mode] }
    return parts.joined(separator: " ")
}

/// Runs a command in a new tab of iTerm's hotkey window, and shows that window;
/// with no hotkey window, in a new window. The tab starts with the command rather
/// than having it typed: text written into a fresh tab races the shell's startup,
/// and a terminal reply landing in front of it garbled the first word. The shell
/// is interactive so aliases and functions load, and replaces itself with a
/// plain login shell afterwards so the tab outlives the command.
func runInNewTab(_ command: String) {
    let shell = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_shell) } ?? "/bin/zsh"
    let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let launch = "\(shell) -lic \(quote("\(command); exec \(shell) -l"))"
    let text = launch.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
        tell application "iTerm2"
          set target to missing value
          repeat with w in windows
            if is hotkey window of w then set target to w
          end repeat
          if target is missing value then
            set target to (create window with default profile command "\(text)")
            select target
            activate
            return "window"
          end if
          tell target to create tab with default profile command "\(text)"
          reveal hotkey window
          return "ok"
        end tell
        """
    let result = runScript(script, label: "resume")
    if result == "ok" { bringITermForward(label: "resume") }
}

/// Types a command into the iTerm session on this tty, as if at its prompt.
/// "ok", or "not found" when no session has the tty any more.
func typeInTerminal(tty: String, _ command: String) -> String {
    let text = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  tell s to write text "\(text)"
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "not found"
        """
    return runScript(script, label: "restart \(tty)")
}

/// True once the process is gone, false if it outlasts the wait.
func waitForExit(_ pid: pid_t, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        usleep(100_000)
    }
    return false
}

/// Waits until the processes on a terminal have stopped changing and stopped
/// using CPU for a second: the shell is back at its prompt. Text typed while it
/// still starts up races its queries to the terminal, whose replies can land in
/// front of the command and garble it.
func waitForQuietTerminal(_ tty: String, seconds: Double) {
    var st = stat()
    guard stat(tty, &st) == 0 else { return }
    let device = UInt32(bitPattern: st.st_rdev)
    func snapshot() -> (pids: [pid_t], cpu: UInt64) {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var mine: [pid_t] = []
        var cpu: UInt64 = 0
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev == device else { continue }
            mine.append(pid)
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            if ok { cpu += usage.ri_user_time + usage.ri_system_time }
        }
        return (mine.sorted(), cpu)
    }
    let deadline = Date().addingTimeInterval(seconds)
    var last = snapshot()
    var quietSince = Date()
    while Date() < deadline {
        usleep(250_000)
        let now = snapshot()
        if now.pids != last.pids || now.cpu != last.cpu { quietSince = Date() }
        last = now
        if Date().timeIntervalSince(quietSince) >= 1 { return }
    }
}

/// Runs an AppleScript and returns what it printed. Apple Events can be refused
/// silently, so whatever osascript says is logged.
@discardableResult
func runScript(_ script: String, label: String) -> String {
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
        log("\(label): \(error.localizedDescription)")
        return ""
    }
    let stdout = String(data: (try? out.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
    let stderr = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    let result = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    log("\(label): exit \(task.terminationStatus) out=\(result) err=\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    return result
}

/// Brings iTerm to the front, so a hotkey window it just revealed stays up.
/// `open -a` on an app that is already running just brings it forward, and does
/// so from inside a bundle where NSRunningApplication's lookup came back empty.
func bringITermForward(label: String) {
    let bring = Process()
    bring.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    bring.arguments = ["-a", "iTerm"]
    do {
        try bring.run()
        bring.waitUntilExit()
        if bring.terminationStatus != 0 { log("\(label): open -a iTerm exited \(bring.terminationStatus)") }
    } catch {
        log("\(label): open -a iTerm failed: \(error.localizedDescription)")
    }
}

/// A drawn progress bar. The terminal's ASCII bar earns its place in a row of
/// text; in a window a real bar reads faster and takes less room.
final class BarView: NSView {
    var fraction: Double = 0 { didSet { shown = CGFloat(fraction) } }
    /// What is drawn: `fraction`, or a value on its way there.
    @objc dynamic var shown: CGFloat = 0 { didSet { needsDisplay = true } }
    /// What this bar's predecessor showed before a refresh rebuilt it. Once on
    /// screen the bar eases from there, so a new reading moves rather than jumps.
    var glideFrom: Double?

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "shown" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let from = glideFrom else { return }
        glideFrom = nil
        guard abs(from - fraction) > 0.001 else { return }
        shown = CGFloat(from)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().shown = CGFloat(fraction)
        }
    }
    var colour: NSColor = .white { didSet { needsDisplay = true } }
    /// Equal parts marked on the bar: 5 for a 5-hour window, 7 for a week, so
    /// each tick is an hour or a day. 0 draws none.
    var divisions = 0 { didSet { needsDisplay = true } }
    /// The tick drawn in white instead of cut out: the end of the current hour
    /// or day, the share a steady pace would have used by then.
    var markedTick: Int? { didSet { needsDisplay = true } }
    /// A blue tick at this share of the bar: where the pace row's projection
    /// lands by the reset. Nil, or past the end, draws none.
    var projection: Double? { didSet { needsDisplay = true } }

    static let thickness: CGFloat = 4

    private func drawBar() {
        let height = Self.thickness
        let track = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        let radius = height / 2
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let filled = max(0, min(1, Double(shown)))
        guard filled > 0 else { return }
        let width = max(height, track.width * CGFloat(filled))
        colour.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: height),
            xRadius: radius, yRadius: radius
        ).fill()
    }

    /// Ticks are gaps cut in the background colour, so they read on the filled
    /// part and the empty track alike.
    override func draw(_ dirtyRect: NSRect) {
        drawBar()
        // Only as tall as the bar itself, not the frame around it.
        func tick(_ x: CGFloat) {
            NSRect(x: x, y: (bounds.height - Self.thickness) / 2, width: 1, height: Self.thickness).fill()
        }
        if divisions > 1 {
            for i in 1..<divisions {
                (i == markedTick ? Palette.text : Palette.background).setFill()
                tick((bounds.width * CGFloat(i) / CGFloat(divisions)).rounded())
            }
        }
        // Drawn last, so it wins where it falls on an hour or day.
        if let projection = projection, projection > 0, projection < 1 {
            Palette.blue.setFill()
            tick((bounds.width * CGFloat(projection)).rounded())
        }
    }
}

/// A menu item that runs a closure, for menus built per cell.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// A cell that acts on a click and says so with the cursor.
final class ClickableCell: NSView {
    var onClick: (() -> Void)? {
        didSet { setAccessibilityRole(onClick == nil ? .group : .button) }
    }

    /// A cell with its own click action keeps the event, so the table never
    /// sees the double-click; the cell passes that on itself.
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, onClick != nil, let onDoubleClick = onDoubleClick {
            onDoubleClick()
        } else if event.clickCount == 1, let onClick = onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// A short highlight, so a copy that changes nothing on screen is still felt.
    /// The written confirmation in the header is the static cue, so skipping the
    /// flash under reduced motion loses nothing.
    func flash() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.898, green: 0.753, blue: 0.482, alpha: 0.22).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Draws its own selection band. AppKit's emphasised highlight rewrites the
/// attributes of every label in the row, which undoes the fonts and colours the
/// cells set for themselves.
final class SessionRowView: NSTableRowView {
    /// Set on the first finished row, to mark where the live sessions end.
    var drawsBoundary = false
    /// Extra height on that row, so the line sits in clear space.
    static let boundaryPadding: CGFloat = 26
    /// Set on a finished row from a different day than the one above it.
    var startsDay = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if startsDay {
            // Faint and dashed, so it reads as a date and never as the boundary.
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 12, y: 0.5))
            line.line(to: NSPoint(x: bounds.width - 12, y: 0.5))
            line.lineWidth = 1
            line.setLineDash([3, 4], count: 2, phase: 0)
            NSColor(srgbRed: 0.42, green: 0.44, blue: 0.51, alpha: 0.35).setStroke()
            line.stroke()
        }
        guard drawsBoundary else { return }
        NSColor(srgbRed: 0.42, green: 0.44, blue: 0.51, alpha: 0.9).setFill()
        // Centred in the padding: half the gap above the line, half below it,
        // before this row's own text.
        NSRect(x: 0, y: (Self.boundaryPadding / 2).rounded(), width: bounds.width, height: 1).fill()
    }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    /// Under the mouse, 0 to 1; animated in and out.
    @objc dynamic var hover: CGFloat = 0 { didSet { needsDisplay = true } }
    /// A state change, 1 when it lands and fading to 0.
    @objc dynamic var pulse: CGFloat = 0 { didSet { needsDisplay = true } }
    var pulseColour = Palette.text

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "hover" || key == "pulse" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    /// Where hover, pulse and selection draw: inset from the table's edges and
    /// rounded, and on the boundary row only the part below the line.
    private var band: NSBezierPath {
        let top = drawsBoundary ? Self.boundaryPadding : 0
        let rect = NSRect(x: 4, y: top + 1, width: bounds.width - 8, height: bounds.height - top - 2)
        return NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    }

    /// The keyboard's place in the table. A 6% wash measured 1.17:1 against the
    /// background, which is no indicator at all; the bar on the leading edge
    /// carries the contrast and the wash carries the row. Hover is a lighter
    /// wash with no bar, so the two never read as the same thing.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let band = self.band
        if pulse > 0 {
            pulseColour.withAlphaComponent(0.16 * pulse).setFill()
            band.fill()
        }
        let wash = (isSelected ? 0.10 : 0) + 0.04 * hover
        if wash > 0 {
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: wash).setFill()
            band.fill()
        }
        guard isSelected else { return }
        // The bar follows the band's rounded corners rather than poking out.
        NSGraphicsContext.saveGraphicsState()
        band.addClip()
        Palette.text.withAlphaComponent(0.8).setFill()
        NSRect(x: band.bounds.minX, y: band.bounds.minY, width: 3, height: band.bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Verdicts (per-session system-one log)

/// One line of a session's shadow log, parsed for the Verdicts view.
private struct VerdictRow {
    let time: String
    let excerpt: String
    /// Keyed by question name: the cell text (a two-decimal probability for
    /// noul and score answers, the chosen option's first three letters for a
    /// choice answer); absent when the log line lacks the question.
    let cells: [String: String]
    let fired: Set<String>
}

/// The on-demand view of one session's system-one shadow log, opened from its
/// Directory cell's right-click menu: no permanent column, just a read of the
/// file on open and again on a 2-second timer while the window stays up.
final class VerdictsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let sessionId: String
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let hookSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rows: [VerdictRow] = []
    private var timer: Timer?
    /// Size and mtime of the log at the last parse: a tick that finds them
    /// unchanged does nothing. Reset on a hook switch, so the next reload
    /// always re-parses the newly chosen log.
    private var seen: (size: UInt64, modified: Date)?
    /// How much of the log's tail is read: a shadow log grows without bound
    /// over a long session, and the view shows its recent calls, not all of it.
    private static let tailBytes: UInt64 = 512 * 1024
    private static let maxRows = 500
    /// Told to the opener so it can drop its reference once the window closes.
    var onClose: (() -> Void)?

    /// The hook currently shown; drives both the file read and the column
    /// set. Columns are the chosen hook's known questions (systemOneHookLabels),
    /// in that fixed order, so headers do not reshuffle row to row.
    private var hook: String
    private var order: [(key: String, label: String)] { systemOneHookLabels[hook] ?? [] }

    init(sessionId: String, hook: String = "bash") {
        self.sessionId = sessionId
        self.hook = systemOneHooks.contains(hook) ? hook : "bash"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Verdicts \u{2014} \(sessionId.prefix(8))"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        window.delegate = self
        build()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor

        status.textColor = Palette.dim
        status.font = NSFont.systemFont(ofSize: 11)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.lineBreakMode = .byTruncatingMiddle

        hookSelector.addItems(withTitles: systemOneHooks)
        hookSelector.selectItem(withTitle: hook)
        hookSelector.target = self
        hookSelector.action = #selector(hookChanged)
        hookSelector.translatesAutoresizingMaskIntoConstraints = false

        rebuildColumns()
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Palette.background
        table.gridColor = Palette.frame
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(status)
        content.addSubview(hookSelector)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: hookSelector.leadingAnchor, constant: -12),
            hookSelector.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            hookSelector.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Rebuilds the table's columns for the current hook: Time, Command, one
    /// column per known question (from `order`), then Fired.
    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        var columns: [(String, String, CGFloat)] = [("time", "Time", 150), ("cmd", "Command", 300)]
        for (key, label) in order { columns.append((key, label, 50)) }
        columns.append(("fired", "Fired", 110))
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
    }

    @objc private func hookChanged() {
        guard let title = hookSelector.titleOfSelectedItem, title != hook else { return }
        hook = title
        seen = nil
        rebuildColumns()
        reload()
    }

    /// The command excerpt, first 80 characters: the Bash hook's own `state`
    /// field ("cwd: ...\ncommand:\n<cmd>") with the cwd line dropped, or
    /// another caller's already-80-character `state_excerpt`.
    private static func excerpt(of entry: [String: Any]) -> String {
        if let state = entry["state"] as? String {
            let body = state.range(of: "command:\n").map { String(state[$0.upperBound...]) } ?? state
            return String(body.prefix(80)).replacingOccurrences(of: "\n", with: "\u{23CE}")
        }
        if let e = entry["state_excerpt"] as? String { return String(e.prefix(80)) }
        return ""
    }

    private func reload() {
        guard let file = systemOneShadowFile(for: sessionId, hook: hook) else {
            status.stringValue = "No session id"
            rows = []
            table.reloadData()
            return
        }
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
            let size = attrs[.size] as? UInt64, let modified = attrs[.modificationDate] as? Date
        else {
            status.stringValue = "No log yet \u{2014} \(file.path)"
            rows = []
            seen = nil
            table.reloadData()
            return
        }
        if let seen, seen.size == size, seen.modified == modified { return }
        // The last tailBytes only, seeking past the rest; the first line of a
        // cut tail is partial and dropped, and a last line still being
        // appended fails to parse and is skipped the same way.
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let cut = size > Self.tailBytes
        if cut { try? handle.seek(toOffset: size - Self.tailBytes) }
        guard let data = try? handle.readToEnd() else { return }
        seen = (size, modified)
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if cut, !lines.isEmpty { lines.removeFirst() }
        var parsed: [VerdictRow] = []
        for line in lines.suffix(Self.maxRows) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let answers = obj["answers"] as? [String: Any] ?? [:]
            var cells: [String: String] = [:]
            for (key, _) in order {
                guard let a = answers[key] as? [String: Any] else { continue }
                if let v = a["noul"] as? Double {
                    cells[key] = String(format: "%.2f", v)
                } else if let v = a["score"] as? Double {
                    let levels = (a["probabilities"] as? [String: Any])?.count ?? 0
                    cells[key] = String(format: "%.2f", v / Double(max(levels - 1, 1)))
                } else if let c = a["choice"] as? String {
                    cells[key] = String(c.prefix(3))
                }
            }
            let fired = Set((obj["fired"] as? [[String: Any]])?.compactMap { $0["q"] as? String } ?? [])
            parsed.append(VerdictRow(time: (obj["ts"] as? String) ?? "", excerpt: Self.excerpt(of: obj), cells: cells, fired: fired))
        }
        rows = parsed.reversed()
        status.stringValue = "\(sessionId)  \u{00B7}  \(rows.count) call(s)\(cut ? ", most recent" : "")  \u{00B7}  \(file.path)"
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let r = rows[row]
        var colour = Palette.text
        let text: String
        switch key {
        case "time": text = r.time
        case "cmd": text = r.excerpt
        case "fired":
            text = r.fired.isEmpty ? "" : r.fired.joined(separator: ",")
            colour = r.fired.isEmpty ? Palette.dim : Palette.yellow
        default:
            if let v = r.cells[key] {
                text = v
                colour = r.fired.contains(key) ? Palette.yellow : Palette.dim
            } else if order.contains(where: { $0.key == key }) {
                text = "--"
                colour = Palette.dim
            } else {
                text = ""
            }
        }
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        let cell = NSView()
        cell.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }
}

// MARK: - Window

/// A path with the home directory as `~`, for showing.
func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Asks for a name and a colour and makes the tag; a name that already exists
/// takes the new colour. Hands the name on once it is made.
func promptNewTag(store: TagStore, on window: NSWindow, note: String, then: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = "New Tag"
    alert.informativeText = note
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 220, height: 24))
    field.placeholderString = "Name"
    let colours = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
    let used = Set(store.tags.map(\.hex))
    for colour in TagColour.all {
        colours.addItem(withTitle: colour.name)
        colours.lastItem?.image = tagDot(colour.color)
    }
    // The first colour no tag has yet, so a new tag stands out by default.
    colours.selectItem(at: TagColour.all.firstIndex { !used.contains($0.hex) } ?? 0)
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 56))
    box.addSubview(field)
    box.addSubview(colours)
    alert.accessoryView = box
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.create(name, hex: TagColour.all[max(0, colours.indexOfSelectedItem)].hex)
        then(name)
    }
}

/// Tag Rules: each rule gives every session launched in a directory, or below
/// it, a set of dots and tags on top of any set by hand. A list of rules, and
/// under it the selected rule's directory, dots and tags; every change is saved
/// as it is made.
final class TagRulesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: TagStore
    var onChange: (() -> Void)?
    private let table = NSTableView()
    private let addRemove = NSSegmentedControl(
        labels: ["+", "−"], trackingMode: .momentary, target: nil, action: nil)
    private let dirLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Change…", target: nil, action: nil)
    private let dotRow = NSStackView()
    private let tagList = NSStackView()
    private let detail = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString: "")

    init(store: TagStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Tag Rules"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 480, height: 380)
        super.init(window: window)
        build()
        table.reloadData()
        if !store.rules.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        drawDetail()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var selectedIndex: Int? {
        let row = table.selectedRow
        return row >= 0 && row < store.rules.count ? row : nil
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString:
            "Every session launched in a directory, or anywhere under it, gets that rule's dots and tags, "
            + "beside any set by hand. Where rules nest, the most specific one applies.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        for (key, title, width) in [("dir", "Directory", 300.0), ("marks", "Marks", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        addRemove.target = self
        addRemove.action = #selector(addOrRemove)
        addRemove.setToolTip("Add a rule for a directory", forSegment: 0)
        addRemove.setToolTip("Remove the selected rule", forSegment: 1)

        chooseButton.target = self
        chooseButton.action = #selector(changeDirectory)
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dirRow = NSStackView(views: [dirLabel, chooseButton])
        dirRow.spacing = 8

        dotRow.spacing = 6
        tagList.orientation = .vertical
        tagList.alignment = .leading
        tagList.spacing = 4
        let newTag = NSButton(title: "New Tag…", target: self, action: #selector(makeTag))
        newTag.controlSize = .small

        let dotsTitle = NSTextField(labelWithString: "Dots")
        let tagsTitle = NSTextField(labelWithString: "Tags")
        for label in [dotsTitle, tagsTitle] { label.font = NSFont.systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        for view in [dirRow, dotsTitle, dotRow, tagsTitle, tagList, newTag] { detail.addArrangedSubview(view) }
        detail.setCustomSpacing(14, after: dirRow)
        detail.setCustomSpacing(14, after: dotRow)

        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "Add a rule with +, then pick its dots and tags."

        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"

        for view in [intro, scroll, addRemove, detail, hint, done] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            addRemove.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            addRemove.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detail.topAnchor.constraint(equalTo: addRemove.bottomAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: intro.trailingAnchor),
            hint.topAnchor.constraint(equalTo: addRemove.bottomAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            done.topAnchor.constraint(greaterThanOrEqualTo: detail.bottomAnchor, constant: 16),
            done.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            dirLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    /// The selected rule's directory, dots and tags; nothing selected, a hint.
    private func drawDetail() {
        guard let index = selectedIndex else {
            detail.isHidden = true
            hint.isHidden = false
            hint.stringValue = store.rules.isEmpty
                ? "Add a rule with +, then pick its dots and tags." : "Select a rule to edit it."
            addRemove.setEnabled(false, forSegment: 1)
            return
        }
        let rule = store.rules[index]
        detail.isHidden = false
        hint.isHidden = true
        addRemove.setEnabled(true, forSegment: 1)
        dirLabel.stringValue = tildePath(rule.dir)
        dirLabel.toolTip = rule.dir
        dotRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, colour) in TagColour.all.enumerated() {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(dotToggled(_:)))
            button.image = tagDot(colour.color)
            button.imagePosition = .imageTrailing
            button.tag = i
            button.state = rule.dots.contains(colour.hex) ? .on : .off
            button.toolTip = colour.name
            button.setAccessibilityLabel("\(colour.name) dot")
            dotRow.addArrangedSubview(button)
        }
        tagList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if store.tags.isEmpty {
            let none = NSTextField(labelWithString: "No named tags yet.")
            none.textColor = .secondaryLabelColor
            tagList.addArrangedSubview(none)
        }
        for (i, tag) in store.tags.enumerated() {
            let button = NSButton(checkboxWithTitle: tag.name, target: self, action: #selector(tagToggled(_:)))
            button.image = tagDot(tag.color)
            button.imagePosition = .imageLeading
            button.tag = i
            button.state = rule.tags.contains(tag.name) ? .on : .off
            tagList.addArrangedSubview(button)
        }
    }

    private func changed(reselect index: Int?) {
        table.reloadData()
        if let index = index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        drawDetail()
        onChange?()
    }

    /// A folder picker as a sheet over this one; the folder comes back.
    private func pickDirectory(_ done: @escaping (String) -> Void) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Sessions launched in this directory, or under it, get the rule's marks."
        if let index = selectedIndex { panel.directoryURL = URL(fileURLWithPath: store.rules[index].dir) }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            done(url.path)
        }
    }

    @objc private func addOrRemove() {
        if addRemove.selectedSegment == 0 {
            pickDirectory { [weak self] dir in
                guard let self = self else { return }
                self.changed(reselect: self.store.addRule(dir))
            }
        } else if let index = selectedIndex {
            store.removeRule(index)
            changed(reselect: store.rules.isEmpty ? nil : min(index, store.rules.count - 1))
        }
    }

    @objc private func changeDirectory() {
        guard let index = selectedIndex else { return }
        pickDirectory { [weak self] dir in
            guard let self = self else { return }
            let clean = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            // Another rule already has that directory: go to it rather than make two.
            if let other = self.store.rules.firstIndex(where: { $0.dir == clean }), other != index {
                self.changed(reselect: other)
                return
            }
            self.store.updateRule(index) { $0.dir = clean }
            self.changed(reselect: index)
        }
    }

    @objc private func dotToggled(_ sender: NSButton) {
        guard let index = selectedIndex, TagColour.all.indices.contains(sender.tag) else { return }
        let hex = TagColour.all[sender.tag].hex
        store.updateRule(index) { rule in
            if sender.state == .on { if !rule.dots.contains(hex) { rule.dots.append(hex) } } else { rule.dots.removeAll { $0 == hex } }
        }
        changed(reselect: index)
    }

    @objc private func tagToggled(_ sender: NSButton) {
        guard let index = selectedIndex, store.tags.indices.contains(sender.tag) else { return }
        let name = store.tags[sender.tag].name
        store.updateRule(index) { rule in
            if sender.state == .on { if !rule.tags.contains(name) { rule.tags.append(name) } } else { rule.tags.removeAll { $0 == name } }
        }
        changed(reselect: index)
    }

    /// A new tag, ticked on the selected rule.
    @objc private func makeTag() {
        guard let window = window else { return }
        let index = selectedIndex
        promptNewTag(store: store, on: window, note: "It goes on this rule, and can be put on sessions and other rules.") {
            [weak self] name in
            guard let self = self else { return }
            if let index = index { self.store.updateRule(index) { if !$0.tags.contains(name) { $0.tags.append(name) } } }
            self.changed(reselect: index)
        }
    }

    @objc private func finish() {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < store.rules.count else { return nil }
        let rule = store.rules[row]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "dir" {
            field.stringValue = tildePath(rule.dir)
            field.toolTip = rule.dir
        } else {
            let text = NSMutableAttributedString()
            let font = NSFont.systemFont(ofSize: 12)
            for colour in TagColour.all where rule.dots.contains(colour.hex) {
                text.append(NSAttributedString(string: "●", attributes: [.font: font, .foregroundColor: colour.color]))
            }
            for tag in store.tags where rule.tags.contains(tag.name) {
                text.append(NSAttributedString(
                    string: (text.length > 0 ? "  " : "") + tag.name, attributes: [.font: font, .foregroundColor: tag.color]))
            }
            if text.length == 0 {
                text.append(NSAttributedString(
                    string: "nothing yet", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            field.attributedStringValue = text
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { drawDetail() }
}

final class SessionsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation,
    NSMenuDelegate
{
    private let statusLabel = NSTextField(labelWithString: "")
    private let quotaBar = NSStackView()
    private let gridScroll = NSScrollView()
    private let table = NSTableView()

    private var rows: [(session: Session, past: Bool)] = []
    /// Memory and CPU per Claude Code pid, from the latest reading.
    private var loads: [pid_t: ProcessSampler.Reading] = [:]
    /// Snapshots run one at a time, so the sampler's CPU deltas stay in order.
    private let worker = DispatchQueue(label: "agent-bar-hopping.reload", qos: .userInitiated)
    private let sampler = ProcessSampler()
    private let selfCost = SelfCost()
    private let events = EventCenter()
    private let soundBar = NSStackView()
    private lazy var soundControls = SoundControls(center: events)
    /// The pack in use; a click opens the browser to hear and choose others.
    private let packButton = NSButton(title: "", target: nil, action: nil)
    private let packStore = PackStore()
    private var packBrowser: PackBrowser?
    private let latest = LatestVersion()
    /// display.json: the verdict row toggle beside the sound controls, and the
    /// on-demand Verdicts view opened from a session's Directory cell.
    private let displayStore = DisplayStore()
    private let verdictsToggle = NSButton(title: "", target: nil, action: nil)
    /// tags.json: the labels put on sessions from their right-click menu.
    private let tagStore = TagStore()
    /// Shows only the sessions with one dot or tag; nil shows every session.
    private var tagFilter: TagFilter?
    /// The filter behind each popup entry, in order; nil for "All sessions"
    /// and for separators.
    private var filterChoices: [TagFilter?] = []
    private var tagRules: TagRulesWindow?
    private let rulesButton = NSButton(title: "", target: nil, action: nil)
    /// The tag filter, Tag Rules and the verdicts toggle: what the list and the
    /// status line show, not how anything sounds.
    private let listControls = NSStackView()
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Every session in the last snapshot; `rows` is what the filter lets through.
    private var allRows: [(session: Session, past: Bool)] = []
    private var verdictsWindows: [String: VerdictsWindow] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var sessionsWatcher: DispatchSourceFileSystemObject?
    private var paintedOnce = false
    private var noteToken: UUID?
    private var counts = ""
    private let emptyLabel = NSTextField(labelWithString: "No session has drawn a status line yet.")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1560, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Agent Bar Hopping"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.background
        super.init(window: window)
        build()
        // The window is exactly as wide as its columns, the spacing between them
        // and the scroller beside them — miss any of those and the table
        // overflows by a hair and grows a horizontal scroll bar.
        let scroller = NSScroller.scrollerWidth(
            for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        let fitted =
            columns.reduce(0) { $0 + $1.width }
            + table.intercellSpacing.width * CGFloat(columns.count)
            + max(scroller, 16) + 2
        window.contentMinSize = NSSize(width: 720, height: 280)
        window.setContentSize(NSSize(width: fitted, height: 720))
        window.center()
        window.setFrameAutosaveName("AgentBarHopping")
        // A frame saved before a column was added would cut the new one off.
        if let restored = window.contentView?.frame.width, restored < fitted {
            window.setContentSize(NSSize(width: fitted, height: window.contentView?.frame.height ?? 720))
        }
        startWatching()
        events.onChange = { [weak self] in self?.refreshTable() }
        latest.onChange = { [weak self] in self?.refreshTable(full: true) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            refreshUsageOnce()
            DispatchQueue.main.async { self?.reload() }
        }
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
        quotaBar.orientation = .horizontal
        // Each quota is two rows, the reading and its pace; their tops line up.
        quotaBar.alignment = .top
        quotaBar.spacing = 32
        quotaBar.translatesAutoresizingMaskIntoConstraints = false

        buildColumns()
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Palette.background
        table.gridColor = Palette.frame
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        // Two lines in every cell: what the status line draws, and what it means.
        table.rowHeight = ceil(barFont.boundingRectForFont.height) + 16 + 12
        table.usesAlternatingRowBackgroundColors = false
        // AppKit's own highlight rewrites the fonts and colours of the labels
        // inside a row, so the band is drawn by SessionRowView instead. Selection
        // itself stays on: it is how the keyboard reaches a row.
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.allowsEmptySelection = true
        table.target = self
        // A double-click on the columns that name a session goes to its terminal.
        table.doubleAction = #selector(showClickedTerminal)
        // Right-click anywhere on a row: built when it opens, for the clicked row.
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        table.menu = rowMenu
        // The default spacing plus per-cell padding is most of the row's width.
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Sessions")
        // Hover follows the mouse, and the scroll under a still mouse.
        table.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        gridScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: gridScroll.contentView, queue: .main
        ) { [weak self] _ in self?.updateHover() }
        gridScroll.documentView = table
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = false
        gridScroll.drawsBackground = false
        gridScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = Palette.dim
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        buildSoundBar()
        content.addSubview(statusLabel)
        content.addSubview(listControls)
        content.addSubview(quotaBar)
        content.addSubview(soundBar)
        content.addSubview(gridScroll)
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            // The list's controls on the same line as its counts, at the right.
            listControls.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            listControls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: listControls.leadingAnchor, constant: -24),
            quotaBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            quotaBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            quotaBar.trailingAnchor.constraint(lessThanOrEqualTo: soundBar.leadingAnchor, constant: -24),
            // The sound settings take the space right of the quotas.
            soundBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            // Level with the bottom of the quotas, so it sits on the table.
            soundBar.bottomAnchor.constraint(equalTo: quotaBar.bottomAnchor),
            gridScroll.topAnchor.constraint(equalTo: quotaBar.bottomAnchor, constant: 12),
            gridScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: gridScroll.topAnchor, constant: 60),
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
        Column(key: "age", title: "Last Seen", width: 74),
        Column(key: "cwd", title: "Directory", width: 164),
        // Beside the directory, as the heat stripe sits beside the cache: the
        // session's dots, stacked, without a title.
        Column(key: "dots", title: "", width: 12),
        Column(key: "topic", title: "Doing", width: 300),
        Column(key: "state", title: "State", width: 112),
        // Beside the state: what a session is doing and how long its cache has
        // are read together.
        Column(key: "cache", title: "Cache", width: 140),
        Column(key: "heat", title: "", width: 10),
        Column(key: "model", title: "Model", width: 74),
        Column(key: "effort", title: "Effort", width: 60),
        Column(key: "context", title: "Context", width: 82),
        Column(key: "sound", title: "Sound", width: 46),
        Column(key: "tokens", title: "Tokens", width: 88),
        Column(key: "memory", title: "Memory", width: 72),
        Column(key: "cpu", title: "CPU", width: 60),
        Column(key: "started", title: "Launched at", width: 112),
        Column(key: "git", title: "Branch", width: 132),
    ]

    private func buildColumns() {
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 16
            // A header follows its cells, or the two disagree. Model and effort
            // face each other across the gap, so the pair reads as one unit.
            switch spec.key {
            case "context", "sound": column.headerCell.alignment = .center
            case "age": column.headerCell.alignment = .right
            case "model", "cache", "tokens", "memory", "cpu": column.headerCell.alignment = .right
            case "effort": column.headerCell.alignment = .left
            default: break
            }
            // Each column sorts by what it means, not by the text it shows:
            // model by capability, effort by level, cache by time left.
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key, ascending: true)
            table.addTableColumn(column)
        }
        // The caches about to go cold first, until a header is clicked; with
        // nothing warm that is the most recently active first.
        table.sortDescriptors = [NSSortDescriptor(key: "cache", ascending: true)]
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("cache"))?.title = "Cache · soonest"
    }

    // MARK: Sound settings

    /// The global sound settings, in the header's spare room: the switch, the
    /// volume and the pack on one line, which events sound on the next.
    /// Everything applies at once; a session can override the switch in the
    /// Sound column.
    private func buildSoundBar() {
        soundBar.orientation = .vertical
        soundBar.alignment = .trailing
        soundBar.spacing = 6
        soundBar.translatesAutoresizingMaskIntoConstraints = false
        soundControls.report = { [weak self] line in self?.note(line) }
        packButton.isBordered = false
        packButton.target = self
        packButton.action = #selector(openPacks)
        packButton.toolTip = "Hear, choose and install sound packs"
        drawPackButton()
        verdictsToggle.isBordered = false
        verdictsToggle.target = self
        verdictsToggle.action = #selector(verdictsToggled)
        drawVerdictsToggle()
        // The switch changes the Sound column; a new pack changes the button.
        NotificationCenter.default.addObserver(
            forName: SoundControls.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.drawPackButton()
            self?.refreshTable()
        }
        // The pack sits at the right edge, over the end of the event row; the
        // gap before it takes up the difference. The list's own controls are
        // not here: they sit in the top row, beside the counts they narrow.
        let gap = NSView()
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterPopup.controlSize = .small
        filterPopup.font = NSFont.systemFont(ofSize: 11)
        filterPopup.isBordered = false
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.toolTip = "Show only the sessions with one tag"
        drawFilterPopup()
        rulesButton.isBordered = false
        rulesButton.attributedTitle = NSAttributedString(
            string: "rules", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dim])
        rulesButton.target = self
        rulesButton.action = #selector(openTagRules)
        rulesButton.toolTip = "Tag Rules: dots and tags for every session launched under a directory"
        let top = NSStackView(views: [soundControls.volumeRow, gap, packButton])
        listControls.setViews([filterPopup, rulesButton, verdictsToggle], in: .leading)
        listControls.spacing = 12
        listControls.translatesAutoresizingMaskIntoConstraints = false
        top.spacing = 8
        top.distribution = .fill
        soundBar.addArrangedSubview(top)
        soundBar.addArrangedSubview(soundControls.eventRow)
        top.widthAnchor.constraint(equalTo: soundControls.eventRow.widthAnchor).isActive = true
    }

    /// system-one's verdict row on the status line: a text toggle in the
    /// ● on / ○ off style the event boxes use, bound to display.json so the
    /// status line script picks the change up on its next redraw. A click
    /// cycles off -> bash -> prompt -> stop -> off, since the row draws at
    /// most one hook's scores at a time.
    private func drawVerdictsToggle() {
        let hook = displayStore.settings.verdictHook
        let on = displayStore.settings.verdictRow && !hook.isEmpty
        verdictsToggle.attributedTitle = NSAttributedString(
            string: (on ? "\u{25CF} " : "\u{25CB} ") + "verdicts" + (on ? " (\(hook))" : ""),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: on ? Palette.text : Palette.dim])
        verdictsToggle.toolTip =
            "system-one's gate scores as a fourth status line row, for the shown hook's questions. "
            + (on ? "Showing \(hook). Click to cycle or turn off." : "Off. Click to choose a hook.")
        verdictsToggle.setAccessibilityLabel("Verdict row on the status line, \(on ? "on, \(hook)" : "off")")
    }

    @objc private func verdictsToggled() {
        displayStore.update {
            let next: [String] = ["", "bash", "prompt", "stop"]
            let current = $0.verdictRow ? $0.verdictHook : ""
            let idx = next.firstIndex(of: current) ?? 0
            let hook = next[(idx + 1) % next.count]
            $0.verdictHook = hook
            $0.verdictRow = !hook.isEmpty
        }
        drawVerdictsToggle()
    }

    /// "All sessions", then one entry per tag with its dot. A filter on a tag
    /// that has since been deleted falls back to all.
    private func drawFilterPopup() {
        if case .tag(let name)? = tagFilter, !tagStore.tags.contains(where: { $0.name == name }) { tagFilter = nil }
        filterPopup.removeAllItems()
        filterChoices = []
        let menu = filterPopup.menu ?? NSMenu()
        func add(_ title: String, _ image: NSImage?, _ choice: TagFilter?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = image
            menu.addItem(item)
            filterChoices.append(choice)
        }
        add("All sessions", nil, nil)
        menu.addItem(.separator())
        filterChoices.append(nil)
        for colour in TagColour.all { add(colour.name, tagDot(colour.color), .dot(colour.hex)) }
        if !tagStore.tags.isEmpty {
            menu.addItem(.separator())
            filterChoices.append(nil)
            for tag in tagStore.tags { add(tag.name, tagDot(tag.color), .tag(tag.name)) }
        }
        filterPopup.selectItem(at: filterChoices.firstIndex { $0 == tagFilter && $0 != nil } ?? 0)
    }

    @objc private func filterChanged() {
        let index = filterPopup.indexOfSelectedItem
        tagFilter = index >= 0 && index < filterChoices.count ? filterChoices[index] : nil
        applyFilter()
    }

    /// The filter in words, for the empty list.
    private var filterWords: String {
        switch tagFilter {
        case .dot(let hex)?: return "the \(TagColour.all.first { $0.hex == hex }?.name.lowercased() ?? "") dot"
        case .tag(let name)?: return "the tag \(name)"
        case nil: return "that tag"
        }
    }

    /// Rows from the last snapshot through the tag filter, sorted and drawn.
    private func applyFilter() {
        let keep = selected?.session.summary.session_id
        rows = allRows.filter { tagStore.matches(tagFilter, $0.session.summary.session_id, $0.session.summary.project_dir) }
        emptyLabel.stringValue = allRows.isEmpty
            ? "No session has drawn a status line yet." : "No session has \(filterWords)."
        emptyLabel.isHidden = !rows.isEmpty
        sortRows()
        refreshTable(full: true)
        select(keep)
    }

    /// After a tag changes: the popup lists it, and the rows show it.
    private func tagsChanged() {
        drawFilterPopup()
        applyFilter()
    }

    private func drawPackButton() {
        let title = NSMutableAttributedString(
            string: events.current.pack, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.text])
        title.append(NSAttributedString(
            string: " ›", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dim]))
        packButton.attributedTitle = title
        packButton.setAccessibilityLabel("Sound pack \(events.current.pack), choose another")
    }

    /// The per-session Verdicts view, from a session's Directory cell menu: an
    /// on-demand read of its shadow log, newest first, no permanent column.
    /// One window per session id; asking again just brings it forward.
    private func openVerdicts(sessionId: String) {
        if let existing = verdictsWindows[sessionId] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let defaultHook = displayStore.settings.verdictHook
        let window = VerdictsWindow(sessionId: sessionId, hook: defaultHook.isEmpty ? "bash" : defaultHook)
        verdictsWindows[sessionId] = window
        window.onClose = { [weak self] in self?.verdictsWindows[sessionId] = nil }
        window.window?.center()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPacks() {
        if packBrowser == nil {
            packBrowser = PackBrowser(store: packStore, events: events)
            packBrowser?.window?.center()
        }
        packBrowser?.present()
    }

    // MARK: Loading

    /// The width the whole row would be drawn at. The grid shows segments rather
    /// than rows, so this only decides how the unused `rows` come back.
    private func rowColumns() -> Int { 120 }

    /// The table takes focus on launch: arrow keys should work without a click.
    func focusTable() {
        window?.makeFirstResponder(table)
    }

    func reload() {
        let cols = rowColumns()
        worker.async { [weak self] in
            guard let self = self else { return }
            let snapshot = readSnapshot(columns: cols)
            var loads: [pid_t: ProcessSampler.Reading] = [:]
            var reused = Set<String>()
            if let snapshot = snapshot {
                // The script knows the pid is alive; only the kernel can say it
                // is still the same process, on the same terminal.
                for s in snapshot.live {
                    if let pid = s.pid, !self.sampler.owns(pid: pid, tty: s.tty), let id = s.summary.session_id {
                        reused.insert(id)
                    }
                }
                let pids = snapshot.live.compactMap { s -> pid_t? in
                    guard let pid = s.pid, !reused.contains(s.summary.session_id ?? "") else { return nil }
                    return pid
                }
                loads = self.sampler.sample(pids)
                self.selfCost.record(snapshot.live + snapshot.history)
            }
            let cost = self.selfCost.load()
            let footprint = self.selfCost.footprint()
            DispatchQueue.main.async { self.apply(snapshot, loads: loads, reused: reused, cost: cost, footprint: footprint) }
        }
    }

    private func apply(
        _ snapshot: Snapshot?, loads: [pid_t: ProcessSampler.Reading], reused: Set<String>,
        cost: (redraws: Double, app: Double)?, footprint: UInt64
    ) {
        guard let snapshot = snapshot else {
            statusLabel.stringValue = "cc-statusline not reachable — see \(logURL.path)"
            return
        }
        if !paintedOnce {
            paintedOnce = true
            log("first paint: \(snapshot.live.count) live, \(snapshot.history.count) finished")
        }
        self.loads = loads
        events.prune(keeping: Set(snapshot.live.compactMap { $0.summary.session_id }))
        let keep = selected?.session.summary.session_id
        let ended = { (s: Session) in reused.contains(s.summary.session_id ?? "") }
        let live = snapshot.live.filter { !ended($0) }
        let past = snapshot.live.filter(ended) + snapshot.history
        allRows = live.map { ($0, false) } + past.map { ($0, true) }
        rows = allRows.filter { tagStore.matches(tagFilter, $0.session.summary.session_id, $0.session.summary.project_dir) }
        counts = "\(live.count) live · \(past.count) finished"
        toolCost = (cost, footprint)
        healthIssues = snapshot.health ?? []
        latest.refreshIfDue()
        if noteToken == nil { statusLabel.stringValue = counts }
        emptyLabel.stringValue = allRows.isEmpty
            ? "No session has drawn a status line yet." : "No session has \(filterWords)."
        emptyLabel.isHidden = !rows.isEmpty
        drawQuotaBar(snapshot)
        sortRows()
        refreshTable()
        table.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(table.tableColumns.indices))
        select(keep)
    }

    /// What watching all this costs, shown as the table's first row: the status
    /// line redraws in every session and the app with its snapshots.
    private var toolCost: (cpu: (redraws: Double, app: Double)?, footprint: UInt64) = (nil, 0)
    /// Outside formats that stopped matching; the row turns red and says which.
    private var healthIssues: [HealthIssue] = []

    private func toolCell(_ key: String) -> NSView? {
        let text: String
        var colour = Palette.dim
        switch key {
        case "cwd":
            text = "this tool"
        case "topic":
            if let first = healthIssues.first {
                // Loud on purpose: a format changed and something reads wrong.
                text = "cc-statusline · ⚠ " + first.problem
                    + (healthIssues.count > 1 ? " (+\(healthIssues.count - 1) more)" : "")
                colour = Palette.red
            } else {
                text = "cc-statusline"
            }
        case "started":
            // Every session's version is held against this one.
            text = "v" + (latest.version ?? "—") + " latest"
        case "memory":
            text = bytes(toolCost.footprint)
            colour = Palette.text.withAlphaComponent(0.8)
        case "cpu":
            text = toolCost.cpu.map { String(format: "%.1f%%", $0.redraws + $0.app) } ?? "—"
            colour = Palette.text.withAlphaComponent(0.8)
        default:
            return nil
        }
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = colour
        field.alignment = key == "memory" || key == "cpu" ? .right : .left
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if key == "topic", !healthIssues.isEmpty {
            cell.toolTip = healthIssues.map { issue in
                let since = clock(issue.first_seen)
                return "\(issue.problem) — since \(since)"
                    + (issue.version.map { ", Claude Code \($0)" } ?? "") + ", seen \(issue.count)×"
            }.joined(separator: "\n") + "\nDetails in error.log; cleared once parsing works again."
        } else if key == "cpu", let cpu = toolCost.cpu {
            // The split, for when the total is worth looking into.
            cell.toolTip = String(format: "Status line redraws %.1f%%, app and its snapshots %.1f%%", cpu.redraws, cpu.app)
        } else if key == "cpu" {
            cell.toolTip = "Shown after the app has run for 30 seconds"
        }
        cell.setAccessibilityLabel(key == "cwd" ? "This tool's own cost" : text + (cell.toolTip.map { ", \($0)" } ?? ""))
        return cell
    }

    /// A selection belongs to a session, not to a row number: new data or a new
    /// sort moves rows, and the selected session keeps its highlight wherever it
    /// lands. Gone from the list, nothing stays selected.
    private func select(_ id: String?) {
        guard let id = id, let row = rows.firstIndex(where: { $0.session.summary.session_id == id }) else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRow != row + 1 {
            table.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
        }
    }

    /// The contents each cell was last drawn with, and the rows they belong to.
    private var drawnIds: [String] = []
    /// The table row under the mouse, or -1.
    private var hoveredRow = -1
    /// Each live session's state as last drawn, to pulse a row when it changes.
    private var lastState: [String: String] = [:]
    /// What each bar last showed, so its replacement glides on from there.
    private var barMemory: [String: Double] = [:]
    private var drawn: [[String: CellContent]] = []

    private func shownContent(_ key: String, row: Int) -> CellContent {
        if row < drawn.count, let c = drawn[row][key] { return c }
        return content(key, row: row)
    }

    /// Rebuilds only the cells whose contents changed while the rows stay the
    /// same sessions in the same order; anything else redraws the table. Most
    /// refreshes are one session's redraw, and every cell is a stack of views.
    private func refreshTable(full: Bool = false) {
        let keys = table.tableColumns.map { $0.identifier.rawValue }
        let ids = rows.map { "\($0.session.summary.session_id ?? "")\($0.past ? "~" : "")" }
        let next = rows.indices.map { row in
            Dictionary(uniqueKeysWithValues: keys.map { ($0, content($0, row: row)) })
        }
        let same = !full && ids == drawnIds
        let previous = drawn
        drawn = next
        drawnIds = ids
        defer { pulseChangedStates() }
        guard same else {
            table.reloadData()
            return
        }
        for row in rows.indices {
            let changed = IndexSet(keys.indices.filter { next[row][keys[$0]] != previous[row][keys[$0]] })
            if !changed.isEmpty { table.reloadData(forRowIndexes: IndexSet(integer: row + 1), columnIndexes: changed) }
        }
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

        // Claude Code rewrites a session's file when it starts waiting on you,
        // which need not come with a redraw; the table follows it at once.
        let sessionsDir = xdgDir("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("sessions")
        let sfd = open(sessionsDir.path, O_EVTONLY)
        if sfd >= 0 {
            let sessions = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: sfd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            sessions.setEventHandler { [weak self] in self?.scheduleReload() }
            sessions.setCancelHandler { Darwin.close(sfd) }
            sessions.resume()
            sessionsWatcher = sessions
        }

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

    // Row 0 is the tool's own row; session i is table row i + 1.
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 }

    /// One line, not two: it is a footnote to the sessions, not one of them.
    private static let toolRowHeight: CGFloat = 22

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row == 0 { return Self.toolRowHeight }
        return tableView.rowHeight + (isBoundary(row - 1) ? SessionRowView.boundaryPadding : 0)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row > 0 }

    /// The first finished row: the live sessions end above it.
    private func isBoundary(_ row: Int) -> Bool {
        row < rows.count && rows[row].past && (row == 0 || !rows[row - 1].past)
    }

    /// Finished rows on a different calendar day from the row above: by launch
    /// under the Started sort, last activity otherwise. Worked out once per sort,
    /// not once per row view.
    private var daySplits: Set<Int> = []

    private func findDaySplits() -> Set<Int> {
        let started = table.sortDescriptors.first?.key == "started"
        let past = rows.indices.filter { rows[$0].past }
        let times = past.map { i -> Double in
            let s = rows[i].session
            return started ? s.summary.started_at ?? 0 : s.active_at ?? s.updated_at
        }
        let days = times.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0 / 1000)) }
        return Set(past.indices.dropFirst().filter { days[$0] != days[$0 - 1] }.map { past[$0] })
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SessionRowView()
        // Live sessions always sort above finished ones; the line says where
        // that boundary is without spending a row on a heading.
        view.drawsBoundary = row > 0 && isBoundary(row - 1)
        view.startsDay = row > 0 && daySplits.contains(row - 1)
        // A rebuilt row under a still mouse is already hovered: no fade in.
        view.hover = row == hoveredRow ? 1 : 0
        return view
    }

    // MARK: Motion

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func updateHover() {
        guard let window = table.window else { return }
        let point = table.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let row = table.visibleRect.contains(point) ? table.row(at: point) : -1
        // Row 0 is the tool's own row, which is not a session.
        setHover(row > 0 ? row : -1)
    }

    private func setHover(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        for (index, level) in [(previous, CGFloat(0)), (row, CGFloat(1))] where index > 0 {
            guard let view = table.rowView(atRow: index, makeIfNecessary: false) as? SessionRowView else { continue }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                view.animator().hover = level
            }
        }
    }

    /// A live row whose state just changed tints once and fades, so the eye
    /// finds what moved among many sessions: yellow when it now waits on you.
    /// A running tool's timer is not a change; `Bash 3m` to `Bash 4m` is still Bash.
    private func pulseChangedStates() {
        var seen: [String: String] = [:]
        var changed: [(row: Int, needsYou: Bool)] = []
        for (index, entry) in rows.enumerated() where !entry.past {
            guard let id = entry.session.summary.session_id else { continue }
            let (word, colour) = stateWords(entry.session, past: false)
            let state = word.replacingOccurrences(of: #" \d+(\.\d+)?[smhd]$"#, with: "", options: .regularExpression)
            seen[id] = state
            if let before = lastState[id], before != state {
                changed.append((index + 1, colour == Palette.yellow || word == "your turn"))
            }
        }
        lastState = seen
        guard !changed.isEmpty else { return }
        // After this pass's reload has made its row views.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let visible = self.table.rows(in: self.table.visibleRect)
            for (row, needsYou) in changed where NSLocationInRange(row, visible) {
                guard let view = self.table.rowView(atRow: row, makeIfNecessary: true) as? SessionRowView else { continue }
                view.pulseColour = needsYou ? Palette.yellow : Palette.text
                view.pulse = 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 1.0
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().pulse = 0
                }
            }
        }
    }

    /// The cache cell's two lines, 12 and 11 point, as the eye measures them:
    /// cap height of the first to baseline of the second. `offset` is how far
    /// that span's centre sits below the centre of the whole text block.
    static let cacheTextSpan: (height: CGFloat, offset: CGFloat) = {
        let first = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let second = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let lineOne = first.ascender - first.descender + first.leading
        let lineTwo = second.ascender - second.descender + second.leading
        let capTop = first.ascender - first.capHeight
        let baseline = lineOne + second.ascender
        // A pixel past each end: measured on screen, the figures' antialiasing
        // reaches one row beyond the metrics.
        return ((baseline - capTop).rounded() + 2, ((capTop + baseline) / 2 - (lineOne + lineTwo) / 2).rounded())
    }()

    /// Hands a rebuilt bar the value its predecessor showed, so it glides on.
    private func remember(_ bar: BarView, _ key: String) {
        bar.glideFrom = barMemory[key]
        barMemory[key] = bar.fraction
    }

    /// Working or running a tool, and not waiting on anyone.
    private func isWorking(_ session: Session) -> Bool {
        guard let state = session.transcript?.state, state == "thinking" || state == "tool",
            session.peer_status != "waiting"
        else { return false }
        return stateWords(session, past: false).1 != Palette.yellow
    }

    /// The dot of a working session, breathing between full and 60% on a
    /// 2-second cycle. Every such dot shares one clock, so they breathe
    /// together and a rebuilt cell picks up mid-breath rather than restarting.
    private func breathingDot(_ colour: NSColor) -> NSTextField {
        let dot = NSTextField(labelWithString: "●")
        dot.font = barFont
        dot.textColor = colour
        dot.wantsLayer = true
        dot.setAccessibilityElement(false)
        dot.translatesAutoresizingMaskIntoConstraints = false
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.6
        breath.duration = 1
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = CACurrentMediaTime() - fmod(CACurrentMediaTime(), 2)
        dot.layer?.add(breath, forKey: "breath")
        return dot
    }

    /// What ⌘C and ⌘↩ act on, and what a click selects.
    private var selected: (session: Session, past: Bool)? {
        let row = table.selectedRow - 1
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(showSelectedTerminal) else { return true }
        item.title = selected?.past == true ? "Resume Session" : "Show Terminal"
        return selected != nil
    }

    @objc func copySelectedSessionId() {
        guard let id = selected?.session.summary.session_id else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        note("Copied \(id)")
    }

    /// The columns that say which session a row is: a double-click on them goes
    /// to its terminal. The figures to the right stay inert.
    private static let terminalColumns: Set<String> = ["age", "cwd", "topic", "state", "cache", "heat"]

    @objc func showClickedTerminal() {
        let column = table.clickedColumn
        guard column >= 0, Self.terminalColumns.contains(table.tableColumns[column].identifier.rawValue) else { return }
        let row = table.clickedRow - 1
        guard row >= 0, row < rows.count else { return }
        go(to: rows[row])
    }

    @objc func showSelectedTerminal() {
        guard let entry = selected else { return }
        go(to: entry)
    }

    /// A live session's terminal, or a finished one opened again in a new tab.
    private func go(to entry: (session: Session, past: Bool)) {
        if !entry.past {
            if let tty = entry.session.tty { focusTerminal(tty: tty) }
            return
        }
        resume(entry.session)
    }

    /// Opens a finished session again, unless it is already open elsewhere, in
    /// which case its terminal comes forward instead.
    private func resume(_ session: Session) {
        let id = session.summary.session_id
        if let live = rows.first(where: { !$0.past && $0.session.summary.session_id == id }), let tty = live.session.tty {
            focusTerminal(tty: tty)
            return
        }
        // No transcript means no prompt was ever sent: nothing to resume.
        guard session.transcript != nil else {
            note("Nothing to resume: the session never had a prompt")
            return
        }
        guard let command = resumeCommand(session.summary, mode: session.transcript?.mode) else {
            note("Cannot resume: the session's launch directory was never recorded")
            return
        }
        runInNewTab(command)
        note("Resuming \(id ?? "session")")
    }

    // MARK: Session menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow - 1
        guard row >= 0, row < rows.count else { return }
        fillSessionMenu(menu, rows[row], flash: nil)
    }

    /// What a right-click on a session offers: copies of what names it, its
    /// tag, its verdicts, and opening it again.
    private func fillSessionMenu(_ menu: NSMenu, _ entry: (session: Session, past: Bool), flash: (() -> Void)?) {
        let (session, past) = entry
        let s = session.summary
        menu.autoenablesItems = false
        // The path in full rather than with its ~.
        let path = s.cwd.map { ($0 as NSString).expandingTildeInPath }
        let name = session.peer_name
        let copy = { [weak self] (text: String) in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash?()
            self?.note("Copied \(text)")
        }
        menu.addItem(ActionItem("Copy Path", enabled: path != nil) { path.map(copy) })
        menu.addItem(ActionItem("Copy Session Name", enabled: name != nil) { name.map(copy) })
        menu.addItem(.separator())
        if let sid = s.session_id {
            let tagItem = NSMenuItem(title: "Tag", action: nil, keyEquivalent: "")
            tagItem.submenu = tagMenu(for: sid, projectDir: s.project_dir)
            menu.addItem(tagItem)
        }
        let sid = s.session_id
        menu.addItem(ActionItem("Verdicts", enabled: sid != nil) { [weak self] in
            sid.map { self?.openVerdicts(sessionId: $0) }
        })
        menu.addItem(.separator())
        if past {
            menu.addItem(ActionItem("Resume Session", enabled: session.transcript != nil) { [weak self] in self?.resume(session) })
        } else {
            let item = ActionItem("Restart Session", enabled: restartBlocker(session) == nil) { [weak self] in
                self?.restartInPlace(session)
            }
            item.toolTip = restartBlocker(session) ?? "Exits Claude Code here and resumes it in the same iTerm tab"
            menu.addItem(item)
        }
    }

    /// The preset dots, then the named tags, each an on/off toggle for this
    /// session. One that comes from the directory's rule shows as mixed: it
    /// stays while the rule does, whatever is set here.
    private func tagMenu(for sessionId: String, projectDir: String?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rule = tagStore.rule(for: projectDir)
        let dots = tagStore.manualDots(sessionId)
        let names = tagStore.manualTags(sessionId)
        func state(_ manual: Bool, _ ruled: Bool) -> NSControl.StateValue { manual ? .on : ruled ? .mixed : .off }
        for colour in TagColour.all {
            let hex = colour.hex
            let item = ActionItem(colour.name) { [weak self] in
                self?.tagStore.toggleDot(hex, for: sessionId)
                self?.tagsChanged()
            }
            item.image = tagDot(colour.color)
            item.state = state(dots.contains(hex), rule?.dots.contains(hex) == true)
            if rule?.dots.contains(hex) == true { item.toolTip = "From the rule for \(tildePath(rule!.dir))" }
            menu.addItem(item)
        }
        if !tagStore.tags.isEmpty { menu.addItem(.separator()) }
        for tag in tagStore.tags {
            let name = tag.name
            let item = ActionItem(name) { [weak self] in
                self?.tagStore.toggleTag(name, for: sessionId)
                self?.tagsChanged()
            }
            item.image = tagDot(tag.color)
            item.state = state(names.contains(name), rule?.tags.contains(name) == true)
            if rule?.tags.contains(name) == true { item.toolTip = "From the rule for \(tildePath(rule!.dir))" }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("New Tag…") { [weak self] in self?.newTag(for: sessionId) })
        if !dots.isEmpty || !names.isEmpty {
            menu.addItem(ActionItem("Clear") { [weak self] in
                self?.tagStore.clear(sessionId)
                self?.tagsChanged()
            })
        }
        if !tagStore.tags.isEmpty {
            let delete = NSMenuItem(title: "Delete Tag", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for tag in tagStore.tags {
                let name = tag.name
                let item = ActionItem(name) { [weak self] in
                    self?.tagStore.delete(name)
                    self?.tagsChanged()
                    self?.note("Deleted the tag \(name)")
                }
                item.image = tagDot(tag.color)
                sub.addItem(item)
            }
            delete.submenu = sub
            menu.addItem(delete)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Tag Rules…") { [weak self] in self?.openTagRules() })
        return menu
    }

    /// A new tag, put straight on the session it was asked from.
    private func newTag(for sessionId: String) {
        guard let window = window else { return }
        promptNewTag(store: tagStore, on: window, note: "It goes on this session, and can then be put on any other.") {
            [weak self] name in
            guard let self = self else { return }
            if !self.tagStore.manualTags(sessionId).contains(name) { self.tagStore.toggleTag(name, for: sessionId) }
            self.tagsChanged()
        }
    }

    /// Rules that tag sessions by their launch directory, as a sheet over the list.
    @objc func openTagRules() {
        guard let window = window, window.attachedSheet == nil else { return }
        let rules = TagRulesWindow(store: tagStore)
        rules.onChange = { [weak self] in self?.tagsChanged() }
        tagRules = rules
        window.beginSheet(rules.window!) { [weak self] _ in self?.tagRules = nil }
    }

    // MARK: Restarting in place

    /// Why a live session cannot be restarted now, or nil when it can. Only an
    /// idle one: a restart mid-turn would cut the turn off.
    private func restartBlocker(_ session: Session) -> String? {
        let s = session.summary
        guard s.session_id != nil, session.pid != nil, session.tty != nil else { return "Its process or terminal is unknown" }
        guard session.transcript != nil else { return "Nothing to resume: the session never had a prompt" }
        guard s.project_dir != nil else { return "Its launch directory was never recorded" }
        guard stateWords(session, past: false).0 == "your turn", (session.transcript?.agents?.running ?? 0) == 0 else {
            return "Busy: restart it once it is your turn"
        }
        return nil
    }

    /// Running an older Claude Code than the newest release, or than the newest
    /// any live session runs when the release is unknown.
    private func isOutdated(_ session: Session) -> Bool {
        guard let v = session.summary.version, let reference = latest.version ?? newestVersion else { return false }
        return versionOrder(v, reference)
    }

    /// Every idle live session on an older Claude Code, restarted where it is.
    @objc func restartOutdatedSessions() {
        let outdated = allRows.filter { !$0.past && isOutdated($0.session) }.map(\.session)
        let ready = outdated.filter { restartBlocker($0) == nil }
        let busy = outdated.count - ready.count
        guard !ready.isEmpty else {
            note(outdated.isEmpty
                ? "Every live session runs the newest Claude Code"
                : "\(busy) outdated session\(busy == 1 ? " is" : "s are") busy; none restarted")
            return
        }
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Restart \(ready.count) session\(ready.count == 1 ? "" : "s") on an older Claude Code?"
        alert.informativeText = "Each one exits and resumes in its own iTerm tab, with its model, effort and permission mode."
            + (busy > 0 ? " \(busy) busy session\(busy == 1 ? " is" : "s are") left alone." : "")
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            ready.forEach { self?.restartInPlace($0) }
        }
    }

    /// Ends Claude Code in its own tab and types the resume command there, so
    /// the tab keeps its place. SIGTERM is a clean exit: Claude Code runs its
    /// SessionEnd hooks, and the session is idle, so no turn is cut off. A tab
    /// that closed with it gets the command in a new tab instead.
    private func restartInPlace(_ session: Session) {
        guard restartBlocker(session) == nil, let pid = session.pid, let tty = session.tty,
            let id = session.summary.session_id,
            let command = resumeCommand(session.summary, mode: session.transcript?.mode)
        else { return }
        let sampler = self.sampler
        note("Restarting \(id)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = { (message: String) in DispatchQueue.main.async { self?.note(message) } }
            // The pid is only ours to signal while it is still that process on that terminal.
            guard sampler.owns(pid: pid, tty: tty) else { return report("Not restarted: \(id) already ended") }
            kill(pid, SIGTERM)
            guard waitForExit(pid, seconds: 15) else { return report("Not restarted: \(id) did not exit") }
            waitForQuietTerminal(tty, seconds: 10)
            if typeInTerminal(tty: tty, command) != "ok" {
                DispatchQueue.main.async { runInNewTab(command) }
            }
            report("Restarted \(id)")
        }
    }

    /// A line of feedback for an action that changes nothing on screen.
    func note(_ message: String) {
        statusLabel.stringValue = message
        let token = UUID()
        noteToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.noteToken == token else { return }
            self.statusLabel.stringValue = self.counts
        }
    }

    /// Everything one cell shows. Two cells with equal contents draw the same,
    /// so a refresh rebuilds only the cells whose contents changed.
    struct CellContent: Equatable {
        var text: NSAttributedString
        var heat: NSColor?
        var percent: Double?
        var past: Bool
        var drop: CGFloat
        var alignment: NSTextAlignment
    }

    private func content(_ key: String, row: Int) -> CellContent {
        let (session, past) = rows[row]
        // The boundary row is taller; its content sits below the line, not
        // centred across it.
        let drop = isBoundary(row) ? SessionRowView.boundaryPadding / 2 : 0
        let s = session.summary
        let seg = session.segments

        // Every cell is a stack: the status line's own drawing on top, the value
        // spelled out underneath.
        let top: NSAttributedString
        var bottom: String
        // A background tint for the columns where the number is a temperature.
        var heat: NSColor? = nil
        var captionColour = Palette.dim
        // Stretches of the caption drawn in their own colour: yellow for the
        // part that needs attention, each tag's colour for its name.
        var highlights: [(range: NSRange, colour: NSColor)] = []
        var captionIndent: CGFloat = 0
        switch key {
        case "topic":
            // The dot leads the topic: the two together say what the session is
            // doing and how alive it is.
            // A working session's dot is drawn by an overlay that breathes;
            // the glyph stays, clear, to hold its place in the line.
            let breathes = !past && isWorking(session)
            let dot = mono(past ? "○  " : "●  ", breathes ? .clear : dotColour(session, past: past))
            // The caption lines up with the topic, not with the dot before it.
            captionIndent = ceil(dot.size().width)
            let title = NSMutableAttributedString(attributedString: dot)
            // New for a minute after it changes, as of the last redraw: a session
            // that ended inside that minute never redraws to say it is not.
            let fresh = !past && (s.topic_is_new ?? false)
            title.append(prose(s.topic ?? "—", fresh ? Palette.yellow : Palette.text))
            top = title
            // Claude Code's own name for the session, under the topic ours derives.
            bottom = s.session_name ?? ""
        case "dots":
            let line = NSMutableAttributedString()
            for dot in tagStore.marks(s.session_id, s.project_dir).dots { line.append(mono("●", dot.color)) }
            top = line
            bottom = ""
        case "state":
            let (word, colour) = stateWords(session, past: past)
            // The state and the permission mode share the top line; under them,
            // a background agent still out. Your turn and a pending agent are
            // both true at once: the session picks up again when it reports back.
            let line = NSMutableAttributedString(attributedString: prose(word, colour))
            // Not after a bare dash, where it would read as the state itself.
            // Only a mode other than auto, the usual one: the exception is what
            // is worth reading. Not after a bare dash either, where it would read
            // as the state itself.
            if let mode = session.transcript?.mode, mode != "auto", word != "—" {
                line.append(prose(" · \(mode == "default" ? "manual" : mode)", Palette.dim))
            }
            top = line
            bottom = ""
            if !past, let running = session.transcript?.agents?.running, running > 0 {
                // In the status line's orange and with its ✻: the one caption
                // that means the session will carry on by itself.
                bottom = "✻ \(running == 1 ? "1 agent" : "\(running) agents")"
                captionColour = Palette.orange
            }
        case "tokens":
            top = mono(session.transcript?.tokens.map { tokens($0.total) } ?? "—", Palette.text)
            bottom = s.lines.map { "+\(Int($0.added)) −\(Int($0.removed))" } ?? ""
        case "memory", "cpu":
            if let pid = session.pid, !past, let load = loads[pid] {
                if key == "memory" {
                    top = mono(bytes(load.footprint), Palette.text)
                    bottom = load.processes > 1 ? "+\(load.processes - 1) procs" : ""
                } else {
                    // Now on top, as it is what moves; the lifetime total under it.
                    top = mono(load.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "…", Palette.text)
                    bottom = cpuTime(load.cpuSeconds)
                }
            } else {
                top = mono("—", Palette.dim)
                bottom = ""
            }
        case "sound":
            // Whether this session sounds: the global switch unless overridden.
            if past || s.session_id == nil {
                top = NSAttributedString(string: "")
            } else {
                // One glyph (Nerd Font speakers): faint while it follows the
                // switch, bright when forced on, yellow when muted.
                let speaker = "\u{F057E}", silent = "\u{F0581}"
                switch events.override(for: s.session_id!) {
                case .some(true): top = mono(speaker, Palette.text)
                case .some(false): top = mono(silent, Palette.yellow)
                case .none: top = mono(events.current.enabled ? speaker : silent, Palette.dim)
                }
            }
            bottom = ""
        case "cwd":
            // The dots have their own column beside this one, so every path
            // starts at the same place whether or not its session has any.
            let marks = tagStore.marks(s.session_id, s.project_dir)
            top = prose(s.cwd ?? "—", Palette.text)
            // The name other sessions message this one by; the terminal it runs
            // in is in the tooltip. A finished session has no name, so its
            // caption falls back to the terminal. The named tags come first,
            // each in its own colour.
            let name = session.peer_name ?? session.tty.map { $0.replacingOccurrences(of: "/dev/", with: "") } ?? ""
            var parts: [String] = []
            var at = 0
            for tag in marks.tags {
                highlights.append((NSRange(location: at, length: (tag.name as NSString).length),
                    past ? tag.color.withAlphaComponent(0.6) : tag.color))
                parts.append(tag.name)
                at += (tag.name as NSString).length + 3
            }
            if !name.isEmpty { parts.append(name) }
            bottom = parts.joined(separator: " · ")
        case "git":
            top = mono(gitText(s.git), Palette.text)
            bottom = gitWords(s.git)
        case "model":
            top = drawn(seg.model)
            // The version too: the strip above says only which tier it is.
            bottom = (s.model_full ?? s.model ?? "") + ((s.fast_mode ?? false) ? " fast" : "")
        case "effort":
            top = drawn(seg.effort)
            bottom = s.effort ?? ""
        case "started":
            top = drawn(seg.started)
            let age = s.started_at.map { "\(ago($0)) ago" } ?? ""
            bottom = age
            // A session started before an update keeps running the old version,
            // named first and set against the latest in the row above. Only the
            // parts that differ are yellow: 2.1.270 against 2.1.271 marks the
            // 270, against 2.2.0 the 1.270.
            if !past, let v = s.version, let reference = latest.version ?? newestVersion, versionOrder(v, reference) {
                let mine = v.split(separator: ".").map(String.init)
                let theirs = reference.split(separator: ".").map(String.init)
                let same = zip(mine, theirs).prefix { $0 == $1 }.count
                let kept = "v" + mine.prefix(same).map { $0 + "." }.joined()
                let changed = mine.dropFirst(same).joined(separator: ".")
                bottom = kept + changed + (age.isEmpty ? "" : " · " + age)
                highlights = [(NSRange(location: (kept as NSString).length, length: (changed as NSString).length), Palette.yellow)]
            }
        case "context":
            return CellContent(
                text: NSAttributedString(), heat: nil, percent: s.context, past: past, drop: drop, alignment: .left)
        case "heat":
            // A stripe beside the cache, not a wash behind it: the colour is a
            // scale to read along, and a tinted cell fights the text in it.
            top = NSAttributedString(string: "")
            bottom = ""
            heat = cacheHeat(s.cache)
        case "cache":
            // The words say everything the glyph line did, and the stripe beside
            // the column already carries the colour.
            top = NSAttributedString(
                string: cacheWords(s.cache),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: Palette.text,
                ])
            bottom = cacheRecord(s.cache)
        case "age":
            top = mono("\(ago(session.active_at ?? session.updated_at)) ago", Palette.dim)
            // Enough of the id to tell sessions apart; a click copies all of it.
            bottom = s.session_id.map { String($0.prefix(8)) } ?? ""
        default:
            top = NSAttributedString(string: "")
            bottom = ""
        }

        let stack = NSMutableAttributedString(attributedString: past ? faded(top) : top)
        // Before the first prompt the status line shouts the model and effort in
        // yellow so the choice can still be checked; the captions join in.
        let pending = s.context == nil && !past && (key == "model" || key == "effort")
        if !bottom.isEmpty {
            // Numbers in a column should line up: tabular figures, and the
            // session id monospaced because it is copied, not read.
            let font: NSFont =
                key == "age"
                ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                : key == "topic"
                    ? NSFont.systemFont(ofSize: 11)
                    : NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            stack.append(
                NSAttributedString(
                    string: "\n" + bottom,
                    attributes: [
                        .font: font,
                        .foregroundColor: pending
                            ? Palette.yellow
                            : past ? Palette.dim.withAlphaComponent(0.8) : captionColour,
                    ]))
            if captionIndent > 0 {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = captionIndent
                style.headIndent = captionIndent
                style.lineBreakMode = .byTruncatingTail
                stack.addAttribute(
                    .paragraphStyle, value: style,
                    range: NSRange(location: stack.length - (bottom as NSString).length, length: (bottom as NSString).length))
            }
            // The caption starts after the top line and its newline.
            let start = stack.length - (bottom as NSString).length
            for (range, colour) in highlights {
                stack.addAttribute(
                    .foregroundColor, value: colour, range: NSRange(location: start + range.location, length: range.length))
            }
        }

        // Model and effort are shapes rather than sentences; the model ends at
        // the gap and the effort starts there, so the pair reads together.
        let alignment: NSTextAlignment =
            key == "sound"
            ? .center : ["model", "cache", "age", "tokens", "memory", "cpu"].contains(key) ? .right : .left
        if alignment != .left {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            stack.addAttribute(
                .paragraphStyle, value: style, range: NSRange(location: 0, length: stack.length))
        }
        return CellContent(text: stack, heat: heat, percent: nil, past: past, drop: drop, alignment: alignment)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        if row == 0 { return toolCell(key) }
        let row = row - 1
        guard row < rows.count else { return nil }
        let (session, past) = rows[row]
        let s = session.summary
        let c = shownContent(key, row: row)
        let drop = c.drop
        if key == "context" { return progressCell(c.percent, past: past, drop: drop, key: s.session_id) }
        if key == "dots" { return dotsCell(tagStore.marks(s.session_id, s.project_dir).dots, past: past, drop: drop) }
        let heat = c.heat
        let alignment = c.alignment
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = c.text
        // Selectable text steals the click and re-styles itself when focused, so
        // the cells act on a click instead of letting text be dragged over.
        field.isSelectable = false
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.alignment = alignment
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = ClickableCell()
        if let heat = heat {
            // Inset and rounded, so the stripe never touches the row divider
            // above or below it.
            let stripe = NSView()
            stripe.wantsLayer = true
            // A finished session is a small square rather than the stripe. Its
            // cache lives on the server, not in the process, so while it is warm
            // a resume still reads it: the square keeps the heat colour until
            // then, and turns grey once there is nothing left to save.
            let warm = !past || cacheLeft(s.cache) > 0
            stripe.layer?.backgroundColor = (warm ? heat : Palette.dim.withAlphaComponent(0.6)).cgColor
            stripe.layer?.cornerRadius = past ? 1.5 : 2
            stripe.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stripe)
            NSLayoutConstraint.activate([
                stripe.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stripe.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            ])
            if past {
                // A square as wide as the stripe, centred where the stripe would be.
                NSLayoutConstraint.activate([
                    stripe.heightAnchor.constraint(equalTo: stripe.widthAnchor),
                    stripe.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: drop),
                ])
            } else {
                // As tall as the cache words beside it read: from the top of the
                // first line's figures to the baseline of the second.
                let span = Self.cacheTextSpan
                NSLayoutConstraint.activate([
                    stripe.heightAnchor.constraint(equalToConstant: span.height),
                    stripe.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: drop + span.offset),
                ])
            }
        }
        // VoiceOver reads the cell, not the two lines inside it, so each one
        // says what it holds and what clicking it does.
        cell.setAccessibilityLabel(accessibilityText(key: key, session: session, past: past))
        if key == "tokens", let t = session.transcript?.tokens {
            field.toolTip =
                "Tokens this session has sent and received, subagents not included:\n"
                + "input \(tokens(t.input)) · cache write \(tokens(t.cache_write)) · "
                + "cache read \(tokens(t.cache_read)) · output \(tokens(t.output))\n"
                + "Lines added and removed, as Claude Code counts them."
        } else if key == "cache", let causes = s.cache?.last_miss_causes, !causes.isEmpty {
            field.toolTip = "Last went cold: \(causes.joined(separator: ", "))"
        } else if key == "memory", let pid = session.pid, loads[pid] != nil {
            field.toolTip = "Memory of Claude Code (pid \(pid)) and every process under it, compressed pages included"
        } else if key == "cpu", session.pid != nil {
            field.toolTip = "CPU now as a share of one core, for Claude Code and every process under it; "
                + "under it, the CPU time Claude Code's own process has used since it started"
        }
        if key == "sound", !past, let id = s.session_id {
            field.toolTip = [
                "Sound: " + (events.override(for: id).map { $0 ? "on for this session" : "muted for this session" }
                    ?? "follows the speaker switch at the top right"),
                "Click to cycle: follow the switch → on → muted",
            ].joined(separator: "\n")
            cell.onClick = { [weak self] in
                guard let self = self else { return }
                let next: Bool? = {
                    switch self.events.override(for: id) {
                    case .none: return true
                    case .some(true): return false
                    case .some(false): return nil
                    }
                }()
                self.events.setOverride(next, for: id)
                self.refreshTable()
            }
        }
        if key == "age", let id = s.session_id {
            field.toolTip = [id, "Click to copy the session id", past ? "Double-click to resume it" : "Double-click to show its terminal"]
                .joined(separator: "\n")
            cell.onClick = { [weak self, weak cell] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
                cell?.flash()
                self?.note("Copied \(id)")
            }
            if !past, let tty = session.tty {
                cell.onDoubleClick = { focusTerminal(tty: tty) }
            } else if past {
                cell.onDoubleClick = { [weak self] in self?.resume(session) }
            }
        } else if key == "cwd", let tty = session.tty, !past {
            // The table's double-click goes to the terminal; a single click only
            // selects, as in every other cell.
            field.toolTip = "\(tty.replacingOccurrences(of: "/dev/", with: "")) · double-click to show this terminal in iTerm"
        } else if key == "cwd", past {
            field.toolTip = "Double-click to resume in a new iTerm tab"
        }
        if key == "cwd" {
            // The row's menu, with the copies flashing the cell they came from.
            let menu = NSMenu()
            fillSessionMenu(menu, (session, past), flash: { [weak cell] in cell?.flash() })
            cell.menu = menu
        }
        // On the cell as well as the text: the text is only as tall as its
        // lines, and a hover below them would find no tooltip.
        cell.toolTip = field.toolTip
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: key == "effort" ? 3 : 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: key == "model" ? -3 : -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: drop),
        ])
        if key == "topic", !past, isWorking(session) {
            // Over the clear glyph the text keeps, on the same baseline.
            let dot = breathingDot(dotColour(session, past: false))
            cell.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: field.leadingAnchor),
                dot.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            ])
        }
        return cell
    }

    /// The quotas every session shares. Each field keeps its place whether or not
    /// the newest session reported it: the most recent session that did is the
    /// source, and a reading old enough to doubt says how old it is.
    private func drawQuotaBar(_ snapshot: Snapshot) {
        let all = snapshot.live + snapshot.history

        /// A quota only climbs until it resets, so the highest reading is the
        /// current truth however old it is — except near the reset itself, where
        /// a high reading is about to become wrong and the newest one is safer.
        func source(_ pick: (Session) -> Limit?) -> Session? {
            let now = Date().timeIntervalSince1970
            let reported = all.filter { pick($0)?.percent != nil }
            let settled = reported.filter { session in
                guard let resets = pick(session)?.resets_at else { return true }
                return resets / 1000 - now > 300
            }
            let pool = settled.isEmpty ? reported : settled
            return pool.max {
                let (a, b) = (pick($0)?.percent ?? 0, pick($1)?.percent ?? 0)
                return a == b ? $0.updated_at < $1.updated_at : a < b
            }
        }

        for view in quotaBar.arrangedSubviews { quotaBar.removeArrangedSubview(view); view.removeFromSuperview() }

        let five = source { $0.summary.five_hour }
        let seven = source { $0.summary.seven_day }
        let hour: Double = 3600
        quotaBar.addArrangedSubview(
            quotaItem("5-hour quota", readAt: five?.updated_at, five?.summary.five_hour, window: 5 * hour))
        quotaBar.addArrangedSubview(
            quotaItem("7-day quota", readAt: seven?.updated_at, seven?.summary.seven_day, window: 168 * hour))
        // Fable comes from the account's own reading, not from a session: only a
        // session running Fable reports it, and the quota matters without one.
        let fable = snapshot.fable.map { Limit(percent: $0.percent, resets_at: $0.resets_at) }
        quotaBar.addArrangedSubview(
            quotaItem("Fable quota", readAt: snapshot.fable?.read_at, fable, window: 168 * hour))
    }

    /// One quota: its name, a drawn bar, the share, and when it comes back. The
    /// colours are the status line's own thresholds. Under it, dimmed, the pace
    /// row: how much of the window's time has gone, drawn on the same scale, and
    /// where spending at this rate would end up by the reset. Level bars mean an
    /// even pace; a used bar ahead of its ghost runs out early.
    private func quotaItem(_ title: String, readAt: Double?, _ limit: Limit?, window: Double) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.yPlacement = .center

        func label(_ text: String, _ colour: NSColor, _ font: NSFont) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = colour
            return field
        }
        func bar(_ fraction: Double, _ colour: NSColor) -> BarView {
            let view = BarView()
            view.fraction = fraction
            view.colour = colour
            view.divisions = Int((window / (window < 86400 ? 3600 : 86400)).rounded())
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 96).isActive = true
            view.heightAnchor.constraint(equalToConstant: 12).isActive = true
            return view
        }
        let name = label(title, Palette.dim, NSFont.systemFont(ofSize: 12))
        let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        guard let limit = limit, let percent = limit.percent, let readAt = readAt else {
            // The same row as a reading, with the bar kept invisible, so the
            // name lines up with its neighbours' names.
            let placeholder = bar(0, .clear)
            placeholder.divisions = 0
            placeholder.alphaValue = 0
            // A blank line where the others say which hour or day it is.
            grid.addRow(with: [NSView(), label(" ", Palette.dim, small)])
            grid.addRow(with: [
                name, placeholder,
                label("—", Palette.dim, NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)),
            ])
            // And one where the pace row goes: every quota is three rows tall,
            // so the names stay on one line whichever way the bar aligns them.
            grid.addRow(with: [NSView(), label(" ", Palette.dim, small)])
            return grid
        }

        let colour = Palette.threshold(percent)
        let share = label(
            "\(Int(percent.rounded()))%", colour, NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        // A reading only changes when a session redraws, so an old one is still
        // the truth — as long as the bar says how old it is.
        let age = Date().timeIntervalSince1970 - readAt / 1000
        var caption = limitWords(limit)
        if age > 120 {
            caption += caption.isEmpty ? "" : " · "
            caption += "read \(ago(readAt)) ago"
        }
        let note = label(caption, age > 1800 ? Palette.yellow : Palette.dim, small)
        // Which hour of the five, or which day of the seven, the window is in:
        // 2.6 hours to the reset is 2.4 gone, so hour 3.
        let unit: Double = window < 86400 ? 3600 : 86400
        let units = Int((window / unit).rounded())
        var position = " "
        var marked: Int? = nil
        if let resets = limit.resets_at {
            let gone = window - (resets / 1000 - Date().timeIntervalSince1970)
            let current = min(units, max(1, Int(gone / unit) + 1))
            position = "\(unit == 3600 ? "hour" : "day") \(current) of \(units)"
            // Where this hour or day ends; on the last one the bar's end is it.
            if current < units { marked = current }
        }
        grid.addRow(with: [NSView(), label(position, Palette.dim, small)])
        let used = bar(percent / 100, colour)
        remember(used, title + " used")
        grid.addRow(with: [name, used, share, note])

        // The pace row needs to know where in the window we are, which only the
        // reset time says.
        guard let resets = limit.resets_at else { return grid }
        let left = resets / 1000 - Date().timeIntervalSince1970
        let elapsed = max(0, min(1, 1 - left / window))
        let ghost = Palette.dim.withAlphaComponent(0.55)
        var projection = ""
        var projectionColour = ghost
        var projected: Double? = nil
        // Too early in the window, a rate is mostly noise: a single prompt a
        // minute after the reset would read as a runaway pace.
        if elapsed >= 0.02 {
            let pace = percent / elapsed
            projection = "on pace for \(Int(pace.rounded()))%"
            projected = pace / 100
            if pace >= 100 {
                projectionColour = Palette.red.withAlphaComponent(0.75)
            } else if pace >= 85 {
                projectionColour = Palette.yellow.withAlphaComponent(0.75)
            }
        }
        let elapsedText = String(format: "%.0f%%", elapsed * 100)
        let paceBar = bar(elapsed, ghost)
        remember(paceBar, title + " pace")
        paceBar.markedTick = marked
        paceBar.projection = projected
        grid.addRow(with: [
            label("pace target", ghost, NSFont.systemFont(ofSize: 11)), paceBar,
            label(elapsedText, ghost, small), label(projection, projectionColour, small),
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        return grid
    }

    // MARK: Sorting

    /// The cache column sorts three ways, in turn on each click of its header:
    /// warm soonest-to-expire first with cold last — the caches about to be
    /// lost, in the order they go — then by time left rising (cold first), then
    /// falling.
    private enum CacheOrder { case rising, falling, soonest }
    private var cacheOrder = CacheOrder.soonest
    private var settingSort = false

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !settingSort else { return }
        let isCache = { (key: String?) in key == "cache" || key == "heat" }
        if let key = tableView.sortDescriptors.first?.key, isCache(key) {
            // AppKit only flips ascending; the third order is ours to add.
            if isCache(old.first?.key) {
                cacheOrder = cacheOrder == .soonest ? .rising : cacheOrder == .rising ? .falling : .soonest
            } else {
                cacheOrder = .soonest
            }
            settingSort = true
            tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: cacheOrder != .falling)]
            settingSort = false
        } else {
            cacheOrder = .soonest
        }
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("cache"))?.title =
            isCache(tableView.sortDescriptors.first?.key) && cacheOrder == .soonest ? "Cache · soonest" : "Cache"
        let keep = selected?.session.summary.session_id
        sortRows()
        refreshTable(full: true)
        select(keep)
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
            // Tagged sessions together, by tag, above the untagged.
            case "cwd": return (0, (s.cwd ?? "~").lowercased())
            case "dots":
                let first = tagStore.marks(s.session_id, s.project_dir).dots.first
                return (first.flatMap { d in TagColour.all.firstIndex { $0.hex == d.hex } }.map(Double.init) ?? 99, "")
            case "git": return (0, (s.git?.branch ?? "~").lowercased())
            case "model": return (modelRank(s.model), (s.model ?? "").lowercased())
            case "effort": return (effortRank(s.effort), s.effort ?? "")
            case "started": return (s.started_at ?? 0, "")
            case "context": return (s.context ?? -1, "")
            // The stripe and the cache column show the same thing, so they sort
            // the same way: by how much cache life is left, cold last.
            case "cache", "heat":
                let left = cacheLeft(s.cache)
                return (cacheOrder == .soonest && left < 0 ? .greatestFiniteMagnitude : left, "")
            case "age": return (entry.session.active_at ?? entry.session.updated_at, "")
            case "state": return (0, stateWords(entry.session, past: entry.past).0)
            case "tokens": return (entry.session.transcript?.tokens?.total ?? -1, "")
            case "memory":
                return (entry.session.pid.flatMap { loads[$0] }.map { Double($0.footprint) } ?? -1, "")
            case "cpu":
                return (entry.session.pid.flatMap { loads[$0]?.cpuPercent } ?? -1, "")
            default: return (0, "")
            }
        }

        rows.sort { a, b in
            if a.past != b.past { return !a.past }
            let (an, at) = rank(a)
            let (bn, bt) = rank(b)
            if an != bn { return ascending ? an < bn : an > bn }
            if at != bt { return ascending ? at < bt : at > bt }
            // Ties go to the most recently active: every open session redraws
            // on a timer, so the redraw time would order them by nothing.
            return (a.session.active_at ?? a.session.updated_at) > (b.session.active_at ?? b.session.updated_at)
        }
        daySplits = findDaySplits()
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
        // Past its expiry it is cold, as the cell already says, whatever the
        // flag from the last redraw.
        let left = expires / 1000 - Date().timeIntervalSince1970
        return left > 0 ? left : -1
    }

    /// A session's dots down the middle of their narrow column, as many as fit
    /// the row: the heat stripe's neighbour in spirit, a mark to scan down for.
    private func dotsCell(_ dots: [TagColour], past: Bool, drop: CGFloat) -> NSView {
        let cell = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for dot in dots.prefix(4) {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = (past ? dot.color.withAlphaComponent(0.6) : dot.color).cgColor
            view.layer?.cornerRadius = 3.5
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 7), view.heightAnchor.constraint(equalToConstant: 7),
            ])
            stack.addArrangedSubview(view)
        }
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: drop),
        ])
        cell.setAccessibilityLabel(dots.isEmpty ? "No dots" : dots.map { "\($0.name) dot" }.joined(separator: ", "))
        return cell
    }

    /// "▓▓▓░░ 52%": the bar, then the number it stands for.
    private func progressCell(_ percent: Double?, past: Bool, drop: CGFloat, key: String?) -> NSView {
        let cell = ClickableCell()
        cell.setAccessibilityLabel(
            "Context window \(percent.map { "\(Int($0.rounded())) percent used" } ?? "unknown")")
        let bar = BarView()
        let value = percent ?? 0
        bar.fraction = value / 100
        if let key = key { remember(bar, "context " + key) }
        let colour = Palette.threshold(percent)
        bar.colour = past ? colour.withAlphaComponent(0.72) : colour
        bar.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: percent == nil ? "—" : "\(Int(value.rounded()))%")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = past ? colour.withAlphaComponent(0.72) : colour
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(bar)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            bar.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: drop),
            bar.heightAnchor.constraint(equalToConstant: 12),
            bar.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 32),
        ])
        return cell
    }

    /// The dot fades with the time since the session last did anything, in
    /// brackets rather than a gradient, so two rows are either the same or
    /// plainly different: under a minute, five, fifteen, then older.
    private func dotColour(_ session: Session, past: Bool) -> NSColor {
        // The faintest step still measures 3.4:1 against the background: below
        // that the dot stops being visible rather than becoming subtle. The
        // hollow ring, not the colour, is what says "ended".
        guard !past else { return Palette.dim }
        let age = Date().timeIntervalSince1970 - (session.active_at ?? session.updated_at) / 1000
        switch age {
        case ..<60: return Palette.yellow
        case ..<300: return Palette.yellow.withAlphaComponent(0.8)
        case ..<900: return Palette.yellow.withAlphaComponent(0.65)
        default: return Palette.yellow.withAlphaComponent(0.5)
        }
    }

    /// What a cell is, in words: the column it belongs to and the value in it.
    private func accessibilityText(key: String, session: Session, past: Bool) -> String {
        let s = session.summary
        let age = "\(ago(session.active_at ?? session.updated_at)) ago"
        switch key {
        case "topic":
            return "\(past ? "Finished" : "Live") session, \(s.topic ?? "no topic")"
                + (s.session_name.map { ", named \($0)" } ?? "")
        case "state":
            let caption = stateCaption(session.transcript)
            return "State \(stateWords(session, past: past).0)" + (caption.isEmpty ? "" : ", \(caption)")
        case "tokens":
            return "Tokens \(session.transcript?.tokens.map { tokens($0.total) } ?? "unknown")"
                + (s.lines.map { ", \(Int($0.added)) lines added, \(Int($0.removed)) removed" } ?? "")
        case "memory":
            guard let pid = session.pid, let load = loads[pid] else { return "Memory unknown" }
            return "Memory \(bytes(load.footprint))"
        case "cpu":
            guard let pid = session.pid, let load = loads[pid] else { return "CPU unknown" }
            return "CPU " + (load.cpuPercent.map { String(format: "%.0f percent", $0) } ?? "not yet measured")
                + ", \(cpuTime(load.cpuSeconds)) in total"
        case "cwd":
            let m = tagStore.marks(s.session_id, s.project_dir)
            let marks = m.dots.map { "\($0.name.lowercased()) dot" } + m.tags.map { "tag \($0.name)" }
            return "Directory \(s.cwd ?? "unknown")\(session.tty.map { ", terminal \($0)" } ?? "")"
                + (marks.isEmpty ? "" : ", " + marks.joined(separator: ", ")) + ". "
                + "Double-click to show that terminal."
        case "git": return "Branch \(gitText(s.git)), \(gitWords(s.git))"
        case "model": return "Model \(s.model_full ?? s.model ?? "unknown")"
        case "effort": return "Effort \(s.effort ?? "unknown")"
        case "started":
            return "Launched \(s.started_at.map { "\(ago($0)) ago" } ?? "at an unknown time")"
        case "context":
            return "Context window \(s.context.map { "\(Int($0.rounded())) percent used" } ?? "unknown")"
        case "cache": return "Prompt cache, \(cacheWords(s.cache))"
        case "heat": return ""
        case "age": return "Last seen \(age). Click to copy the session id."
        case "sound":
            guard !past, let id = s.session_id else { return "" }
            let state = events.override(for: id).map { $0 ? "on" : "muted" } ?? "following the speaker switch at the top right"
            return "Sound \(state). Click to change."
        default: return ""
        }
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
        guard let ansi = ansi, !ansi.isEmpty else { return mono("—", Palette.dim) }
        return attributed(ansi: ansi, font: barFont)
    }

    /// Finished sessions recede, but stay readable: at 45% the captions fell to
    /// a 1.9:1 contrast ratio, well under the 4.5:1 a small label needs.
    private func faded(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            let colour = (value as? NSColor) ?? Palette.text
            out.addAttribute(.foregroundColor, value: colour.withAlphaComponent(0.72), range: range)
        }
        return out
    }

    /// The cache's own temperature: a freshly written cache is hot, it cools as
    /// its life is spent, and a cold one is the coldest of all. The ramp is a
    /// straight blend from a muted red to a muted blue — a hue sweep would pass
    /// through green, which says nothing about heat.
    private func cacheHeat(_ cache: CacheState?) -> NSColor? {
        let hot = (r: 0.60, g: 0.28, b: 0.25)
        let cold = (r: 0.24, g: 0.35, b: 0.56)
        func blend(_ t: Double) -> NSColor {
            NSColor(
                srgbRed: CGFloat(hot.r + (cold.r - hot.r) * t),
                green: CGFloat(hot.g + (cold.g - hot.g) * t),
                blue: CGFloat(hot.b + (cold.b - hot.b) * t), alpha: 0.9)
        }
        guard let cache = cache else { return nil }
        let expired = (cache.expires_at ?? .greatestFiniteMagnitude) / 1000 <= Date().timeIntervalSince1970
        guard cache.warm, !expired else { return blend(1) }
        guard let elapsed = cacheElapsed(cache) else { return nil }
        return blend(min(1, max(0, elapsed / 100)))
    }

    /// When the quota comes back. The share is already on the bar above it.
    private func limitWords(_ limit: Limit?) -> String {
        guard let limit = limit, let percent = limit.percent else { return "" }
        if percent >= 95, let at = limit.resets_at, at / 1000 > Date().timeIntervalSince1970 {
            return "resets \(clock(at))"
        }
        let left = until(limit.resets_at)
        return left.isEmpty ? "" : "resets in \(left)"
    }

    /// The stripe beside the column says warm or cold; the words say what that
    /// costs — time left, or the tokens a rebuild would reprocess.
    private func cacheWords(_ cache: CacheState?) -> String {
        guard let cache = cache else { return "" }
        // A cache still flagged warm whose expiry has passed is cold: the flag is
        // from the last redraw, the clock is now.
        let expired = (cache.expires_at ?? .greatestFiniteMagnitude) / 1000 <= Date().timeIntervalSince1970
        guard cache.warm, !expired else {
            guard let rebuild = cache.rebuild else { return "expired" }
            return "\(tokens(rebuild)) to rebuild"
        }
        guard let expires = cache.expires_at else { return "warm" }
        return "\(until(expires)) left"
    }

    /// What the session is doing, from your side: what needs you is in yellow,
    /// what is in progress is faint. A running tool may be a permission prompt
    /// the transcript cannot see, so it says how long it has been at it.
    private func stateWords(_ session: Session, past: Bool) -> (String, NSColor) {
        guard !past else {
            switch session.ended?.reason {
            // Ctrl+D or /exit.
            case "prompt_input_exit": return ("exited", Palette.dim)
            case "clear": return ("cleared", Palette.dim)
            case "resume": return ("resumed", Palette.dim)
            case "logout": return ("logged out", Palette.dim)
            // A hangup or SIGTERM: the tab closed, iTerm quit, or the machine
            // restarted, with the session still open.
            case "other": return ("closed", Palette.text)
            // No SessionEnd at all: the process was killed outright.
            case "crashed": return ("crashed", Palette.yellow)
            // Ended before SessionEnd was recorded, or for a reason this does
            // not know: no word, as a word would read as a fourth way to end.
            default: return ("—", Palette.dim)
            }
        }
        // Claude Code's own record beats anything read from the transcript: a
        // dialog waiting on you is not written there until it is answered.
        if session.peer_status == "waiting" {
            switch session.peer_waiting_for {
            case "input needed": return ("question", Palette.yellow)
            case "sandbox request": return ("sandbox?", Palette.yellow)
            case "goal proposal": return ("goal?", Palette.yellow)
            case let other?: return (other, Palette.yellow)
            case nil: return ("needs you", Palette.yellow)
            }
        }
        guard let t = session.transcript, let state = t.state else { return ("—", Palette.dim) }
        let since = t.state_at.map { " \(ago($0))" } ?? ""
        switch state {
        case "idle": return ("your turn", Palette.text)
        case "asking": return (t.tool == "ExitPlanMode" ? "plan" : "question", Palette.yellow)
        case "tool":
            // The permission came after the tool call, and nothing has started
            // since: the prompt is still open.
            if let id = session.summary.session_id, let asked = events.permissionAt[id],
                asked >= (t.state_at ?? 0) / 1000,
                (session.pid.flatMap { loads[$0]?.newestChild } ?? 0) < asked
            {
                return ("approve?", Palette.yellow)
            }
            return ((t.tool ?? "tool") + since, Palette.dim)
        case "thinking": return ("working", Palette.dim)
        case "interrupted": return ("stopped", Palette.text)
        default: return (state, Palette.dim)
        }
    }

    /// The permission mode, then any background subagents still running.
    private func stateCaption(_ t: TranscriptState?) -> String {
        guard let t = t else { return "" }
        var parts: [String] = []
        if let mode = t.mode { parts.append(mode) }
        if let running = t.agents?.running, running > 0 {
            parts.append(running == 1 ? "1 agent" : "\(running) agents")
        }
        return parts.joined(separator: " · ")
    }

    /// How well the cache has served the session: its hit rate and misses.
    private func cacheRecord(_ cache: CacheState?) -> String {
        guard let c = cache, let ratio = c.hit_ratio else { return "" }
        let misses = Int(c.misses ?? 0)
        return "\(Int((ratio * 100).rounded()))% hit · \(misses) \(misses == 1 ? "miss" : "misses")"
    }

    /// The newest Claude Code version any live session runs.
    private var newestVersion: String? {
        allRows.filter { !$0.past }.compactMap { $0.session.summary.version }.max { versionOrder($0, $1) }
    }

    /// True when a is an older version than b: 2.1.9 before 2.1.10.
    private func versionOrder(_ a: String, _ b: String) -> Bool {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q }
        }
        return false
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
        controller?.focusTable()
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

    let sessionItem = NSMenuItem()
    let sessionMenu = NSMenu(title: "Session")
    sessionMenu.addItem(
        withTitle: "Copy Session ID", action: #selector(SessionsWindow.copySelectedSessionId),
        keyEquivalent: "c")
    let showItem = sessionMenu.addItem(
        withTitle: "Show Terminal", action: #selector(SessionsWindow.showSelectedTerminal),
        keyEquivalent: "\r")
    showItem.keyEquivalentModifierMask = [.command]
    sessionMenu.addItem(.separator())
    sessionMenu.addItem(withTitle: "Tag Rules…", action: #selector(SessionsWindow.openTagRules), keyEquivalent: "")
    sessionMenu.addItem(
        withTitle: "Restart Outdated Sessions…", action: #selector(SessionsWindow.restartOutdatedSessions),
        keyEquivalent: "")
    sessionItem.submenu = sessionMenu
    main.addItem(sessionItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
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
