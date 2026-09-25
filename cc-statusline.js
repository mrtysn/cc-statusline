#!/usr/bin/env -S -u NODE_USE_ENV_PROXY node
'use strict';

// Started without NODE_USE_ENV_PROXY: it makes node load its proxy machinery at
// startup, doubling the cost of a launch (~30 ms of CPU to ~60), and a redraw
// never goes on the web. The processes that do are started with it put back —
// see networkEnv — so their requests still go through the proxy.

const { execFileSync, spawn } = require('child_process');
const {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} = require('fs');
const { homedir, tmpdir } = require('os');
const { dirname, isAbsolute, join } = require('path');
const { render, summarize, segments, cleanTopic, isFable, TOPIC_MAX_CHARS } = require('./lib/render.js');

// The Fable weekly quota is not in the statusline input; it comes from the
// account usage endpoint, cached once for every session on the machine.
const CACHE_DIR = process.env.CC_STATUSLINE_CACHE_DIR || join(homedir(), '.cache', 'cc-statusline');
// The app's own files (sounds.json lives here too): where it writes display.json,
// the one setting this script reads back on every redraw.
const APP_SUPPORT_DIR = join(homedir(), 'Library', 'Application Support', 'Agent Bar Hopping');
const DISPLAY_FILE = join(APP_SUPPORT_DIR, 'display.json');
// system-one's per-session shadow log (agents-shared/notebook/2026-09-24-system-one-decision-model-integration.md,
// section 9): one JSONL file per session, read for the show-mode verdict row.
const SYSTEM_ONE_STATE_DIR =
  process.env.SYSTEM_ONE_STATE_DIR || join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'system-one');
const SYSTEM_ONE_SHADOW_DIR = join(SYSTEM_ONE_STATE_DIR, 'shadow');
const USAGE_FILE = join(CACHE_DIR, 'usage.json');
const LOCK_FILE = join(CACHE_DIR, 'refresh.lock');
const ERROR_LOG = join(CACHE_DIR, 'error.log');
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const REFRESH_MS = 5 * 60000;
// Floor for the early refresh when the 7-day figure moves mid-turn.
const MIN_REFRESH_MS = 60000;
const LOCK_STALE_MS = 30000;
const LOG_MAX_BYTES = 256 * 1024;
// Session topics: a manual one set by /statusline-topic, else one Haiku derives
// from the transcript in the background.
const TOPIC_DIR = join(CACHE_DIR, 'topics');
// One file per session, rewritten on every redraw, for the live view to watch.
const LIVE_DIR = join(CACHE_DIR, 'live');
// Running totals read from each session's transcript, for the live view.
const SCAN_DIR = join(CACHE_DIR, 'scan');
// A session is finished once its Claude Code process is gone. A spool from
// before pids were recorded has only its redraws to go on: Claude Code redraws
// every refreshInterval while the process lives, so one that has not redrawn for
// this long has ended.
const LIVE_STALE_MS = 30 * 60000;
// Finished sessions kept for the app's history, newest first.
const LIVE_HISTORY_MAX = 500;
// In iTerm2 a refresh waits for the tab to be focused, so a short floor is
// enough; elsewhere focus is unknown and the floor is the only limit.
const TOPIC_FOCUSED_REFRESH_MS = 2 * 60000;
const TOPIC_REFRESH_MS = 10 * 60000;
const TOPIC_LOCK_STALE_MS = 2 * 60000;
const TOPIC_KEEP_MS = 30 * 86400000;
// A changed topic is yellow for one refreshInterval from the first redraw that
// shows it, so the next idle tick is the one that returns it to normal.
const TOPIC_HIGHLIGHT_MS = 60000;
const TRANSCRIPT_TAIL_BYTES = 512 * 1024;
const TRANSCRIPT_EXCERPT_CHARS = 8000;

// `--flag value` from the command line, for the serve subcommand's options.
function argValue(flag) {
  const i = process.argv.indexOf(flag);
  return i === -1 ? null : process.argv[i + 1];
}

function readStdin() {
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

// The repository's git directory, found on disk rather than with a second git
// process: the nearest .git up from cwd, following the `gitdir:` pointer that a
// worktree or submodule keeps in a .git file.
function findGitDir(cwd) {
  for (let dir = cwd; ; dir = dirname(dir)) {
    const dotGit = join(dir, '.git');
    try {
      if (statSync(dotGit).isDirectory()) return dotGit;
      const pointer = /^gitdir:\s*(.+)$/m.exec(readFileSync(dotGit, 'utf8'))?.[1].trim();
      return pointer ? (isAbsolute(pointer) ? pointer : join(dir, pointer)) : null;
    } catch {}
    if (dirname(dir) === dir) return null;
  }
}

// The last redraw's git state, when nothing can have moved it. Claude Code
// redraws every open session each refreshInterval, and a git status per tick in
// a session nobody touches is wasted. The index and HEAD change with staging,
// commits and checkouts, and a new message is when Claude edits files. An edit
// made outside Claude in an idle session shows on its next message: the mark is
// there to say whether the session left uncommitted work, which is Claude's.
function gitStamp(cwd) {
  const dir = findGitDir(cwd);
  if (!dir) return null;
  const mtime = (name) => {
    try {
      return statSync(join(dir, name)).mtimeMs;
    } catch {
      return null;
    }
  };
  return { cwd, index: mtime('index'), head: mtime('HEAD') };
}

function cachedGit(cwd, previous, lastAt) {
  const stamp = gitStamp(cwd);
  const before = previous?.git_stamp;
  const same =
    stamp &&
    before &&
    before.cwd === stamp.cwd &&
    before.index === stamp.index &&
    before.head === stamp.head &&
    previous.last_message_at === lastAt;
  if (same) return { info: previous.args?.git ?? null, stamp: before };
  return { info: git(cwd), stamp };
}

function git(cwd) {
  try {
    const opts = { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] };
    const out = execFileSync(
      'git',
      ['-C', cwd, 'status', '--porcelain=v2', '--branch'],
      opts
    );

    const info = {
      branch: null,
      ahead: 0,
      behind: 0,
      staged: 0,
      unstaged: 0,
      untracked: 0,
      conflicts: 0,
      action: null,
    };
    let oid = null;
    let detached = false;

    for (const line of out.split('\n')) {
      if (!line) continue;
      if (line.startsWith('# branch.oid ')) {
        oid = line.slice(13);
      } else if (line.startsWith('# branch.head ')) {
        const head = line.slice(14);
        if (head === '(detached)') detached = true;
        else info.branch = head;
      } else if (line.startsWith('# branch.ab ')) {
        const m = line.match(/\+(\d+) -(\d+)/);
        if (m) {
          info.ahead = parseInt(m[1], 10);
          info.behind = parseInt(m[2], 10);
        }
      } else if (line[0] === '1' || line[0] === '2') {
        const xy = line.slice(2, 4);
        if (xy[0] !== '.') info.staged++;
        if (xy[1] !== '.') info.unstaged++;
      } else if (line[0] === 'u') {
        info.conflicts++;
      } else if (line[0] === '?') {
        info.untracked++;
      }
    }

    if (detached && oid) info.branch = '@' + oid.slice(0, 7);
    if (!info.branch) return null;

    try {
      const absGitDir = findGitDir(cwd);
      if (!absGitDir) throw null;
      const actionMap = [
        ['rebase-merge', 'rebase'],
        ['rebase-apply', 'rebase'],
        ['MERGE_HEAD', 'merge'],
        ['CHERRY_PICK_HEAD', 'cherry-pick'],
        ['REVERT_HEAD', 'revert'],
        ['BISECT_LOG', 'bisect'],
      ];
      for (const [file, name] of actionMap) {
        if (existsSync(join(absGitDir, file))) {
          info.action = name;
          break;
        }
      }
    } catch {}

    return info;
  } catch {
    return null;
  }
}

function readUsageCache() {
  try {
    return JSON.parse(readFileSync(USAGE_FILE, 'utf8'));
  } catch {
    return null;
  }
}

// display.json: the app's own settings file, read the same way sounds.json and
// the usage cache are — a small JSON file, on every redraw, no caching beyond
// that. Missing means the row is off (the app writes the file with a default on
// first launch, same as sounds.json). verdictHook names which hook's shadow log
// to draw ('bash' | 'prompt' | 'stop'); empty (the default) means off, even
// when verdictRow is on -- a session that never picked a hook draws nothing,
// so the Bash hook's scores no longer reach the row by default.
function readVerdictDisplay() {
  try {
    const d = JSON.parse(readFileSync(DISPLAY_FILE, 'utf8'));
    if (d?.verdictRow !== true) return null;
    const hook = typeof d?.verdictHook === 'string' ? d.verdictHook.trim() : '';
    return hook || null;
  } catch {
    return null;
  }
}

// The last lines of a JSONL file without reading the whole thing: a shadow log
// can grow to hundreds of megabytes over a long session, and only the last
// verdict is ever drawn. A chunk grows from the end until it holds three lines
// (or reaches the file's size): the first may be cut mid-line by the chunk
// boundary, so the last two are whole, and the reader can fall back from a
// last line the hook is still appending to the one before it.
function readLastLines(file) {
  let size;
  try {
    size = statSync(file).size;
  } catch {
    return [];
  }
  if (!size) return [];
  let chunk = 16384;
  let fd;
  try {
    fd = openSync(file, 'r');
    for (;;) {
      const want = Math.min(chunk, size);
      const buf = Buffer.alloc(want);
      readSync(fd, buf, 0, want, size - want);
      const lines = buf.toString('utf8').split('\n').filter((l) => l.trim());
      if (lines.length >= 3 || want >= size) return lines.slice(want >= size ? 0 : 1).slice(-2);
      chunk *= 4;
    }
  } catch {
    return [];
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {}
    }
  }
}

// One hook's per-session shadow log (shadow/<hook>/<session_id>.jsonl), last
// line: its raw answers object (renderVerdict picks the first four keys and
// labels them) and which questions fired. Missing file, unparsable line, no
// session id, or no hook all read as no verdict, same as every other reader
// here. A last line that does not parse is one the hook is still writing: the
// line before it stands in for that redraw.
function readVerdict(sessionId, hook) {
  if (!sessionId || !hook) return null;
  const safeSession = String(sessionId).replace(/[^\w-]/g, '');
  const safeHook = String(hook).replace(/[^\w-]/g, '');
  if (!safeSession || !safeHook) return null;
  const file = join(SYSTEM_ONE_SHADOW_DIR, safeHook, `${safeSession}.jsonl`);
  if (!existsSync(file)) return null;
  let entry = null;
  for (const line of readLastLines(file).reverse()) {
    try {
      entry = JSON.parse(line);
      break;
    } catch {}
  }
  if (!entry || typeof entry !== 'object') return null;
  const answers = entry.answers && typeof entry.answers === 'object' ? entry.answers : {};
  const fired = Array.isArray(entry.fired) ? entry.fired.map((f) => f?.q).filter(Boolean) : [];
  return { hook: safeHook, answers, fired };
}

function logError(message) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    if (existsSync(ERROR_LOG) && statSync(ERROR_LOG).size > LOG_MAX_BYTES) writeFileSync(ERROR_LOG, '');
    appendFileSync(ERROR_LOG, `${new Date().toISOString()} ${message}\n`);
  } catch {}
}

// Loud failures. Everything here reads formats Anthropic can change without
// notice — the status line input, transcripts, hook events, the usage endpoint —
// and a changed format rarely throws: the JSON still parses, the field is just
// gone, and a segment quietly disappears. So each reader states what it expects,
// and a broken expectation lands in HEALTH_FILE, which puts a red ! on every
// status line and the problem in words in the app, tagged with the Claude Code
// version that brought it. A later pass clears it again.
const HEALTH_FILE = join(CACHE_DIR, 'health.json');
// A standing failure is rewritten at most this often, not on every redraw.
const HEALTH_REFRESH_MS = 60000;

function readHealth() {
  try {
    return JSON.parse(readFileSync(HEALTH_FILE, 'utf8')) || {};
  } catch {
    return {};
  }
}

function checkFormat(key, ok, problem, example = null, version = null) {
  const health = readHealth();
  const known = health[key];
  const now = Date.now();
  if (ok) {
    if (!known) return;
    delete health[key];
    logError(`format ok again: ${key}`);
  } else {
    if (known && now - known.last_seen < HEALTH_REFRESH_MS) return;
    health[key] = {
      problem,
      version: known?.version ?? version,
      first_seen: known?.first_seen ?? now,
      last_seen: now,
      count: (known?.count ?? 0) + 1,
      example: example != null ? String(example).slice(0, 300) : known?.example ?? null,
    };
    if (!known) logError(`format: ${key}: ${problem}${version ? ` (Claude Code ${version})` : ''}`);
  }
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    const tmp = `${HEALTH_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(health));
    renameSync(tmp, HEALTH_FILE);
  } catch {}
}

// The status line input's shape, independent of the session's state: these are
// there from the first redraw on, whether or not anything has been said.
function checkInput(input) {
  if (!input.session_id) return;
  const keys = Object.keys(input).join(',');
  checkFormat(
    'input/context_window',
    typeof input.context_window?.context_window_size === 'number',
    'status line input has no context_window.context_window_size',
    keys,
    input.version
  );
  checkFormat(
    'input/cost',
    typeof input.cost?.total_duration_ms === 'number',
    'status line input has no cost.total_duration_ms',
    keys,
    input.version
  );
}

// The environment for a child that makes web requests: this process was started
// without NODE_USE_ENV_PROXY, and a request should honour the proxy the session
// was given, not skip it.
function networkEnv() {
  const proxied = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
  return proxied ? { ...process.env, NODE_USE_ENV_PROXY: '1' } : process.env;
}

// Takes the refresh lock, clearing one left behind by a refresh that died.
function takeLock() {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    try {
      if (Date.now() - statSync(LOCK_FILE).mtimeMs > LOCK_STALE_MS) unlinkSync(LOCK_FILE);
    } catch {}
    closeSync(openSync(LOCK_FILE, 'wx'));
    return true;
  } catch {
    return false;
  }
}

// Starts a detached refresh when the cache is old, or when the free 7-day
// figure has moved since the last fetch. Never waits for it.
function maybeRefreshUsage(cached, sevenPct) {
  const age = Date.now() - (cached?.fetched_at ?? 0);
  const moved = sevenPct != null && cached?.seven_day_seen != null && sevenPct !== cached.seven_day_seen;
  if (age < REFRESH_MS && !(moved && age >= MIN_REFRESH_MS)) return;
  if (!takeLock()) return;
  try {
    const args = [__filename, '--refresh-usage'];
    if (sevenPct != null) args.push(String(sevenPct));
    spawn(process.execPath, args, { detached: true, stdio: 'ignore', env: networkEnv() }).unref();
  } catch (err) {
    logError(`spawn: ${err.message}`);
    try {
      unlinkSync(LOCK_FILE);
    } catch {}
  }
}

function readOauthToken() {
  const out = execFileSync('security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: 3000,
  });
  const token = JSON.parse(out).claudeAiOauth?.accessToken;
  if (!token) throw new Error('no claudeAiOauth.accessToken in keychain entry');
  return token;
}

// Runs in the detached child. Keeps the last good reading on failure and
// records the failure, so the statusline can mark the value stale. The token
// is never renewed here: renewal rotates the refresh token under Claude Code.
async function refreshUsage(sevenArg) {
  const previous = readUsageCache();
  const next = {
    fetched_at: Date.now(),
    seven_day_seen: sevenArg != null && sevenArg !== '' ? Number(sevenArg) : previous?.seven_day_seen ?? null,
    fable: previous?.fable ?? null,
    error: null,
  };
  try {
    let token;
    try {
      token = readOauthToken();
    } catch (err) {
      throw new Error(`keychain: ${err.message}`);
    }
    let res;
    try {
      res = await fetch(USAGE_URL, {
        headers: {
          Authorization: `Bearer ${token}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'Content-Type': 'application/json',
        },
        signal: AbortSignal.timeout(10000),
      });
    } catch (err) {
      throw new Error(`network: ${err.cause?.code || err.message}`);
    }
    if (!res.ok) throw new Error(`http ${res.status}`);
    let body;
    try {
      body = await res.json();
    } catch {
      throw new Error('parse: response is not JSON');
    }
    if (!Array.isArray(body.limits)) throw new Error('parse: no limits[] in response');
    const entry = body.limits.find(
      (l) => l?.kind === 'weekly_scoped' && l.scope?.model?.display_name === 'Fable'
    );
    if (entry && typeof entry.percent !== 'number') throw new Error('parse: Fable entry has no numeric percent');
    next.fable = entry
      ? { percent: entry.percent, resets_at: entry.resets_at ?? null, is_active: entry.is_active === true }
      : null;
    checkFormat('usage/response', true);
  } catch (err) {
    next.error = err.message;
    logError(err.message);
    // A changed or moved endpoint, not an outage: no network or no keychain
    // says nothing about the format.
    if (/^(parse|http)/.test(err.message)) checkFormat('usage/response', false, `usage endpoint: ${err.message}`);
  }
  try {
    const tmp = `${USAGE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(next));
    renameSync(tmp, USAGE_FILE);
  } catch (err) {
    logError(`cache write: ${err.message}`);
  }
  try {
    unlinkSync(LOCK_FILE);
  } catch {}
}

// Session IDs come from Claude Code, but they name files here, so anything
// that is not a plain ID is refused.
function topicPaths(sessionId) {
  if (!/^[A-Za-z0-9-]+$/.test(sessionId || '')) return null;
  return {
    manual: join(TOPIC_DIR, `${sessionId}.manual`),
    auto: join(TOPIC_DIR, `${sessionId}.json`),
    lock: join(TOPIC_DIR, `${sessionId}.lock`),
    seen: join(TOPIC_DIR, `${sessionId}.seen`),
  };
}

function readText(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

// A manual topic wins over the auto one. Returns { text, isNew }. Starts a background refresh of the
// auto topic when the transcript has moved on.
function renderTopic(sessionId, transcriptPath, tty, lastAt) {
  const paths = topicPaths(sessionId);
  if (!paths) return null;
  let topic = cleanTopic(readText(paths.manual));
  if (!topic) {
    let auto = null;
    try {
      auto = JSON.parse(readText(paths.auto));
    } catch {}
    maybeRefreshTopic(paths, auto, lastAt, sessionId, tty, transcriptPath);
    topic = cleanTopic(auto?.topic);
  }
  if (!topic) return null;
  return { text: topic, isNew: topicIsNew(paths, topic) };
}

// Remembers when this topic was first drawn; a different topic restarts the clock.
function topicIsNew(paths, topic) {
  let seen = null;
  try {
    seen = JSON.parse(readText(paths.seen));
  } catch {}
  if (seen?.topic !== topic) {
    seen = { topic, shown_at: Date.now() };
    try {
      mkdirSync(TOPIC_DIR, { recursive: true });
      writeFileSync(paths.seen, JSON.stringify(seen));
    } catch {}
  }
  return Date.now() - seen.shown_at < TOPIC_HIGHLIGHT_MS;
}

// When the session last had a prompt or a reply, from the end of its
// transcript. The file's mtime says nothing: Claude Code appends bookkeeping
// entries to a session nobody has touched in days, and the status line itself
// redraws every refreshInterval. A tool result counts, since it means Claude is
// at work; injected meta entries do not.
const LAST_MESSAGE_TAIL_BYTES = 64 * 1024;
function lastMessageAt(transcriptPath) {
  if (!transcriptPath) return null;
  try {
    for (const bytes of [LAST_MESSAGE_TAIL_BYTES, TRANSCRIPT_TAIL_BYTES]) {
      const slice = readSlice(transcriptPath, true, bytes);
      const lines = slice.text.split('\n');
      if (slice.partial) lines.shift();
      for (let i = lines.length - 1; i >= 0; i--) {
        // Loose, so a change of JSON spacing cannot hide every line from it.
        if (!/"type"\s*:\s*"(user|assistant)"/.test(lines[i])) continue;
        let entry;
        try {
          entry = JSON.parse(lines[i]);
        } catch {
          continue;
        }
        if ((entry.type === 'user' || entry.type === 'assistant') && !entry.isMeta) {
          return Date.parse(entry.timestamp) || null;
        }
      }
      if (!slice.partial) return null;
    }
  } catch {}
  return null;
}

function maybeRefreshTopic(paths, auto, lastAt, sessionId, tty, transcriptPath) {
  if (!transcriptPath || !lastAt) return;
  const generated = auto?.generated_at ?? 0;
  // Nothing was said since the last topic: no call, and no focus check either.
  if (lastAt <= generated) return;
  const iterm = process.env.TERM_PROGRAM === 'iTerm.app';
  // Until the first topic exists, every change to the transcript is worth a
  // look; later refreshes, and retries after a failure, wait out the floor.
  const floor = iterm ? TOPIC_FOCUSED_REFRESH_MS : TOPIC_REFRESH_MS;
  if (auto && !auto.awaiting_reply && Date.now() - generated < floor) return;
  if (iterm && !itermTabFocused(tty)) return;
  try {
    mkdirSync(TOPIC_DIR, { recursive: true });
    try {
      if (Date.now() - statSync(paths.lock).mtimeMs > TOPIC_LOCK_STALE_MS) unlinkSync(paths.lock);
    } catch {}
    closeSync(openSync(paths.lock, 'wx'));
  } catch {
    return;
  }
  try {
    spawn(process.execPath, [__filename, '--refresh-topic', sessionId, transcriptPath], {
      env: networkEnv(),
      detached: true,
      stdio: 'ignore',
    }).unref();
  } catch (err) {
    logError(`topic spawn: ${err.message}`);
    try {
      unlinkSync(paths.lock);
    } catch {}
  }
}

// The terminal of the Claude Code session this status line belongs to, and the
// process that holds it: the first ancestor with a terminal. Claude Code runs
// the status line without a controlling terminal, so /dev/tty is not available.
// One ps per ancestor (~5 ms each) rather than listing every process (~200 ms,
// nearly all of it system time), and none at all when the last redraw already
// found that process and it is still this one's parent — a process never
// changes terminal.
function ownTerminal(previous) {
  if (previous?.tty && previous.pid === process.ppid) return { tty: previous.tty, pid: previous.pid };
  let pid = String(process.pid);
  for (let depth = 0; depth < 10; depth++) {
    let line;
    try {
      line = execFileSync('ps', ['-o', 'ppid=,tty=', '-p', pid], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 2000,
      });
    } catch {
      // Without ps (a sandbox, a timeout) the line still draws, at full width.
      return { tty: null, pid: null };
    }
    const [ppid, tty] = line.trim().split(/\s+/);
    if (tty && tty !== '??' && tty !== '?') {
      return { tty: tty.startsWith('/dev/') ? tty : `/dev/${tty}`, pid: Number(pid) };
    }
    if (!ppid || ppid === '0' || ppid === '1') return { tty: null, pid: null };
    pid = ppid;
  }
  return { tty: null, pid: null };
}

// Columns of the session's terminal, read on every redraw so a resize is
// picked up on the next one. CC_STATUSLINE_COLUMNS overrides it; null when
// neither is known, and the bars then stay full width.
function terminalColumns(tty) {
  const forced = Number(process.env.CC_STATUSLINE_COLUMNS);
  if (forced > 0) return forced;
  try {
    if (!tty) return null;
    // macOS's own stty reads another terminal with -f; GNU stty, often first on
    // PATH there, spells it -F.
    const [cmd, flag] = process.platform === 'darwin' ? ['/bin/stty', '-f'] : ['stty', '-F'];
    const cols = Number(
      execFileSync(cmd, [flag, tty, 'size'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000 })
        .trim()
        .split(/\s+/)[1]
    );
    return cols > 0 ? cols : null;
  } catch {
    return null;
  }
}

// True only when iTerm2 is the frontmost app and its focused pane is this session.
// Asking iTerm2 costs an osascript (~160 ms) and an Apple Event; every session's
// redraw wants the same answer, so one reading is shared through FOCUS_FILE for
// FOCUS_SHARE_MS. A tab switch is noticed that much later at most, on top of the
// refreshInterval it already waits for.
const FOCUS_FILE = join(CACHE_DIR, 'focus.json');
const FOCUS_SHARE_MS = 10000;
function itermTabFocused(tty) {
  if (!tty) return false;
  try {
    const shared = JSON.parse(readFileSync(FOCUS_FILE, 'utf8'));
    if (Date.now() - shared.at < FOCUS_SHARE_MS) return shared.tty === tty;
  } catch {}
  let focused = null;
  try {
    focused =
      execFileSync(
        'osascript',
        ['-e', 'tell application "iTerm2" to if frontmost then tty of current session of current window'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000 }
      ).trim() || null;
  } catch {}
  try {
    const tmp = `${FOCUS_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ tty: focused, at: Date.now() }));
    renameSync(tmp, FOCUS_FILE);
  } catch {}
  return focused === tty;
}

function readSlice(file, fromEnd, bytes) {
  const fd = openSync(file, 'r');
  try {
    const size = statSync(file).size;
    const length = Math.min(bytes, size);
    const buf = Buffer.alloc(length);
    readSync(fd, buf, 0, length, fromEnd ? size - length : 0);
    return { text: buf.toString('utf8'), partial: length < size };
  } finally {
    closeSync(fd);
  }
}

// The prose of a transcript: typed prompts and Claude's replies, without tool
// traffic, attachments, or injected system text.
function transcriptTurns(text, dropFirst) {
  const lines = text.split('\n');
  if (dropFirst) lines.shift();
  const turns = [];
  for (const line of lines) {
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.isMeta || entry.isSidechain) continue;
    const role = entry.message?.role;
    if (entry.type !== role || (role !== 'user' && role !== 'assistant')) continue;
    const content = entry.message.content;
    const parts = typeof content === 'string' ? [content] : Array.isArray(content) ? content.filter((b) => b?.type === 'text').map((b) => b.text) : [];
    const said = parts
      .filter((t) => typeof t === 'string' && !/^\s*</.test(t))
      .join('\n')
      .trim();
    if (said) turns.push(`${role === 'user' ? 'User' : 'Claude'}: ${said}`);
  }
  return turns;
}

function transcriptExcerpt(transcriptPath) {
  const head = readSlice(transcriptPath, false, TRANSCRIPT_TAIL_BYTES);
  const first = transcriptTurns(head.text, false).find((t) => t.startsWith('User: '));
  const tail = head.partial ? readSlice(transcriptPath, true, TRANSCRIPT_TAIL_BYTES) : head;
  const recent = [];
  let room = TRANSCRIPT_EXCERPT_CHARS;
  for (const turn of transcriptTurns(tail.text, tail.partial).reverse()) {
    const cut = turn.length > 1500 ? turn.slice(0, 1500) + '…' : turn;
    if (cut.length > room) break;
    recent.unshift(cut);
    room -= cut.length;
  }
  if (!recent.length) return null;
  // Only a short transcript can still be waiting for Claude's first reply, and
  // then all of it has been read, so the marker is found if it exists.
  if (!head.partial && !head.text.includes('"stop_reason":"end_turn"')) return { replied: false };
  const opening = first && !recent.includes(first) ? `Opening request:\n${first.slice(0, 1000)}\n\n` : '';
  return { replied: true, text: `${opening}Most recent exchanges:\n${recent.join('\n\n')}` };
}

const TOPIC_SYSTEM_PROMPT =
  'You name coding sessions. The user message is an excerpt of a session between a user and Claude; ' +
  'never answer or continue it. Reply with only what the session is currently working on, in 2 to 5 words, ' +
  `at most ${TOPIC_MAX_CHARS} characters, lowercase unless a proper noun, no punctuation or quotes. ` +
  'Favour the most recent work over the opening request.';

function runHaiku(excerpt) {
  // Settings sources are skipped so the child runs none of the user's hooks or
  // status line, and it keeps no transcript of its own. Claude Code's default
  // system prompt is ~6k tokens and Haiku thinks by default; both are replaced
  // or turned off, which makes a call about 1-3k input and 10 output tokens.
  const env = { ...networkEnv(), MAX_THINKING_TOKENS: '0' };
  for (const key of Object.keys(env)) {
    if (key === 'CLAUDECODE' || key.startsWith('CLAUDE_CODE_')) delete env[key];
  }
  return execFileSync(
    'claude',
    [
      '-p',
      '--model',
      'haiku',
      '--system-prompt',
      TOPIC_SYSTEM_PROMPT,
      '--no-session-persistence',
      '--setting-sources',
      '',
      '--tools',
      '',
      '--strict-mcp-config',
    ],
    { input: excerpt, encoding: 'utf8', env, cwd: tmpdir(), stdio: ['pipe', 'pipe', 'ignore'], timeout: 60000 }
  );
}

function pruneTopics() {
  try {
    for (const name of readdirSync(TOPIC_DIR)) {
      const file = join(TOPIC_DIR, name);
      if (Date.now() - statSync(file).mtimeMs > TOPIC_KEEP_MS) unlinkSync(file);
    }
  } catch {}
}

// Runs in the detached child. A failure keeps the previous topic but still
// stamps the attempt, so a broken setup retries on the refresh interval rather
// than on every redraw.
function refreshTopic(sessionId, transcriptPath) {
  const paths = topicPaths(sessionId);
  if (!paths) return;
  let previous = null;
  try {
    previous = JSON.parse(readText(paths.auto));
  } catch {}
  const next = { topic: previous?.topic ?? null, generated_at: Date.now(), awaiting_reply: false, error: null };
  try {
    const excerpt = transcriptExcerpt(transcriptPath);
    if (!excerpt) throw new Error('empty transcript');
    if (!excerpt.replied) {
      // The first topic waits for Claude's first complete reply; checked again
      // on the next transcript change, without a call.
      next.awaiting_reply = true;
      throw null;
    }
    const topic = cleanTopic(runHaiku(`<excerpt>\n${excerpt.text}\n</excerpt>`).split('\n').find((l) => l.trim()));
    if (!topic) throw new Error('empty reply');
    next.topic = topic;
  } catch (err) {
    if (err) {
      next.error = err.message.split('\n')[0];
      logError(`topic: ${next.error}`);
    }
  }
  try {
    mkdirSync(TOPIC_DIR, { recursive: true });
    const tmp = `${paths.auto}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(next));
    renameSync(tmp, paths.auto);
  } catch (err) {
    logError(`topic write: ${err.message}`);
  }
  pruneTopics();
  try {
    unlinkSync(paths.lock);
  } catch {}
}

// The arguments of this redraw, so the live view can draw the same rows at its
// own width. Written on every redraw, which is what paces the view; a failure
// here never costs the status line itself.
function spoolFile(sessionId) {
  return sessionId ? join(LIVE_DIR, `${sessionId.replace(/[^\w-]/g, '')}.json`) : null;
}

// `pid` is the Claude Code process that owns the terminal: the app reads its
// memory and CPU, and a dead pid ends the session at once. `redraw` is the CPU
// this redraw cost node, startup included; git and stty, its only children, are
// not in it. No wall time: node's clocks start after ~60 ms of process launch.
function writeSpool(args, terminal, lastAt, gitStampNow) {
  const file = spoolFile(args.input?.session_id);
  if (!file) return;
  const cpu = process.cpuUsage();
  const redraw = { cpu_ms: Math.round((cpu.user + cpu.system) / 1000) };
  try {
    mkdirSync(LIVE_DIR, { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    const entry = {
      updated_at: Date.now(),
      last_message_at: lastAt,
      git_stamp: gitStampNow,
      tty: terminal.tty,
      pid: terminal.pid,
      redraw,
      args,
    };
    writeFileSync(tmp, JSON.stringify(entry));
    renameSync(tmp, file);
  } catch (err) {
    logError(`spool: ${err.message}`);
  }
}

// `cc-statusline.js session-end`, from the SessionEnd hook with the event on
// stdin: how the session ended goes into its spool. A session whose process is
// gone without one crashed, from when this first ran; ENDS_SINCE says when.
const ENDS_SINCE = join(CACHE_DIR, 'session-ends-since');

function recordSessionEnd(event) {
  const file = spoolFile(event.session_id);
  if (!file) return;
  try {
    if (!existsSync(ENDS_SINCE)) writeFileSync(ENDS_SINCE, String(Date.now()));
    const entry = JSON.parse(readFileSync(file, 'utf8'));
    entry.ended = { reason: event.reason || null, at: Date.now() };
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(entry));
    renameSync(tmp, file);
  } catch (err) {
    // No spool: the session never drew a status line.
    if (err.code !== 'ENOENT') logError(`session-end: ${err.message}`);
  }
}

// What a session's transcript says it is doing, kept up to date by reading only
// what was appended since the last snapshot: the first read of a session walks
// the whole file once, every later one a few kilobytes. The running totals live
// in SCAN_DIR, one small file per session.
//
// state is one of:
//   idle         Claude finished its reply and waits for a prompt
//   asking       a question or a plan is waiting on the user
//   tool         a tool is running — or waiting on a permission prompt, which
//                the transcript does not record until it is answered
//   thinking     a prompt or a tool result is in, and the reply has not started
//   interrupted  the user stopped the turn
// Subagents' own traffic is not in the session's transcript, so their tokens
// are not in the totals; the count is of Agent calls the session made.
const SCAN_VERSION = 2;
const ASKING_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode']);
const AGENT_TOOLS = new Set(['Agent', 'Task']);

function freshScan(path) {
  return {
    version: SCAN_VERSION,
    path,
    offset: 0,
    tokens: { input: 0, cache_write: 0, cache_read: 0, output: 0 },
    counted: null,
    last: null,
    mode: null,
    agents: { total: 0, running: [] },
  };
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map((b) => (b?.type === 'text' ? b.text : '')).join('\n');
}

// A background task reports its end in a notification that Claude Code queues
// for the next turn, recorded as a queue operation.
function settleAgents(scan, text) {
  for (const m of text.matchAll(/<task-id>(\w+)<\/task-id>[\s\S]*?<status>(\w+)<\/status>/g)) {
    if (m[2] !== 'running') scan.agents.running = scan.agents.running.filter((id) => id !== m[1]);
  }
}

function scanEntry(scan, entry) {
  if (entry.type === 'permission-mode' && entry.permissionMode) {
    scan.mode = entry.permissionMode;
    return;
  }
  if (entry.type === 'queue-operation' && entry.operation === 'enqueue' && typeof entry.content === 'string') {
    settleAgents(scan, entry.content);
    return;
  }
  const at = Date.parse(entry.timestamp) || null;
  const message = entry.message;
  if (entry.type === 'assistant' && message) {
    // One line per content block, each repeating its message's usage.
    const u = message.usage;
    if (u && message.id && message.id !== scan.counted) {
      scan.counted = message.id;
      scan.tokens.input += u.input_tokens || 0;
      scan.tokens.cache_write += u.cache_creation_input_tokens || 0;
      scan.tokens.cache_read += u.cache_read_input_tokens || 0;
      scan.tokens.output += u.output_tokens || 0;
    }
    const call = Array.isArray(message.content) ? message.content.filter((b) => b?.type === 'tool_use').pop() : null;
    if (call && AGENT_TOOLS.has(call.name)) scan.agents.total++;
    scan.last = { role: 'assistant', stop: message.stop_reason ?? null, tool: call ? { id: call.id, name: call.name } : null, at };
    return;
  }
  if (entry.type !== 'user' || !message) return;
  const content = message.content;
  const results = Array.isArray(content) ? content.filter((b) => b?.type === 'tool_result') : [];
  for (const r of results) {
    // A background agent answers at once and reports back later by notification.
    const launched = /agentId: (\w+)/.exec(textOf(r.content));
    if (launched && /Async agent launched/.test(textOf(r.content))) scan.agents.running.push(launched[1]);
  }
  const text = textOf(content);
  if (entry.isMeta) return;
  const kind = results.length ? 'result' : /^\[Request interrupted by user/.test(text.trim()) ? 'interrupted' : 'prompt';
  scan.last = { role: 'user', kind, at };
}

function scanState(scan) {
  const last = scan.last;
  if (!last) return null;
  if (last.role === 'user') return last.kind === 'interrupted' ? 'interrupted' : 'thinking';
  if (last.stop === 'tool_use') return ASKING_TOOLS.has(last.tool?.name) ? 'asking' : 'tool';
  if (last.stop == null) return 'interrupted';
  return 'idle';
}

function scanPath(sessionId) {
  return join(SCAN_DIR, `${sessionId.replace(/[^\w-]/g, '')}.json`);
}

// What a transcript chunk held, for judging whether its format is still the
// one this file reads.
const KNOWN_STOPS = new Set([
  'end_turn', 'tool_use', 'stop_sequence', 'max_tokens', 'refusal', 'pause_turn', 'model_context_window_exceeded',
]);
function tallyEntry(tally, entry) {
  if (entry.version) tally.version = entry.version;
  if (entry.type !== 'user' && entry.type !== 'assistant') return;
  tally.typed++;
  if (entry.type !== 'assistant' || !entry.message) return;
  tally.assistant++;
  if (entry.message.usage) tally.usage++;
  const stop = entry.message.stop_reason;
  if (stop != null && !KNOWN_STOPS.has(stop)) tally.stops.add(stop);
}

// Each expectation is judged only on a chunk big enough to judge it, so a
// two-line append proves nothing either way.
function judgeTranscript(t) {
  if (t.lines >= 20) {
    checkFormat('transcript/json', t.broken / t.lines <= 0.1, `transcript: ${t.broken} of ${t.lines} lines are not JSON`, null, t.version);
    checkFormat('transcript/types', t.typed > 0, `transcript: ${t.lines} lines, none of type user or assistant`, null, t.version);
  }
  if (t.assistant >= 5) {
    checkFormat('transcript/usage', t.usage > 0, 'transcript: assistant messages carry no message.usage', null, t.version);
  }
  if (t.assistant > 0) {
    checkFormat(
      'transcript/stop_reason',
      t.stops.size === 0,
      `transcript: unknown stop_reason ${[...t.stops].join(', ')}`,
      [...t.stops].join(', '),
      t.version
    );
  }
}

// `fresh` false reads only the saved totals: a finished session's transcript is
// not opened again.
function transcriptScan(sessionId, transcriptPath, fresh) {
  if (!sessionId || !transcriptPath) return null;
  const file = scanPath(sessionId);
  let scan = null;
  try {
    scan = JSON.parse(readFileSync(file, 'utf8'));
  } catch {}
  if (scan?.version !== SCAN_VERSION || scan.path !== transcriptPath) scan = freshScan(transcriptPath);
  if (fresh) {
    try {
      const size = statSync(transcriptPath).size;
      // A transcript only grows; a shorter one was rewritten, so start over.
      if (size < scan.offset) scan = freshScan(transcriptPath);
      if (size > scan.offset) {
        const fd = openSync(transcriptPath, 'r');
        let chunk;
        try {
          chunk = Buffer.alloc(size - scan.offset);
          readSync(fd, chunk, 0, chunk.length, scan.offset);
        } finally {
          closeSync(fd);
        }
        // Only whole lines: a line still being written is read next time.
        const end = chunk.lastIndexOf(0x0a) + 1;
        const tally = { lines: 0, broken: 0, typed: 0, assistant: 0, usage: 0, stops: new Set(), version: null };
        for (const line of chunk.subarray(0, end).toString('utf8').split('\n')) {
          if (!line) continue;
          tally.lines++;
          let entry;
          try {
            entry = JSON.parse(line);
          } catch {
            tally.broken++;
            continue;
          }
          tallyEntry(tally, entry);
          try {
            scanEntry(scan, entry);
          } catch {}
        }
        judgeTranscript(tally);
        if (end > 0) {
          scan.offset += end;
          mkdirSync(SCAN_DIR, { recursive: true });
          const tmp = `${file}.${process.pid}.tmp`;
          writeFileSync(tmp, JSON.stringify(scan));
          renameSync(tmp, file);
        }
      }
    } catch (err) {
      // A new session has no transcript until its first prompt.
      if (err.code !== 'ENOENT') logError(`scan ${sessionId}: ${err.message}`);
    }
  }
  if (!scan.offset) return null;
  const t = scan.tokens;
  return {
    state: scanState(scan),
    state_at: scan.last?.at ?? null,
    tool: scanState(scan) === 'tool' || scanState(scan) === 'asking' ? scan.last.tool?.name ?? null : null,
    mode: scan.mode,
    tokens: { ...t, total: t.input + t.cache_write + t.cache_read + t.output },
    agents: { total: scan.agents.total, running: scan.agents.running.length },
  };
}

// Background agents still running while the prompt is the user's, for the ✻ on
// the topic row. The same incremental scan the live view keeps: only what the
// transcript gained since the last reading is parsed.
function waitingAgents(sessionId, transcriptPath) {
  const scan = transcriptScan(sessionId, transcriptPath, true);
  return scan?.state === 'idle' ? scan.agents.running : 0;
}

// Whether the session's Claude Code process still runs, so a closed tab ends its
// session at once rather than after the stale window. A signal-0 kill is a
// syscall: listing processes with ps to learn the same cost ~0.4 s of system
// time per snapshot. A pid can be reused once its process is gone, so the app,
// which can read a process's terminal natively, also checks that it is still on
// the same tty. A spool written before pids were recorded is judged on its age.
function processAlive(pid) {
  if (!pid) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

// The names other sessions use to message each one (`finance-be`), by session
// id: Claude Code keeps a small file per running session in its config dir.
// Local files only; a session that has ended has none.
// This session's own name, from its Claude Code process's file; one read.
function peerName(pid, sessionId) {
  if (!pid) return null;
  try {
    const dir = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'sessions');
    const entry = JSON.parse(readFileSync(join(dir, `${pid}.json`), 'utf8'));
    return entry.sessionId === sessionId ? entry.name || null : null;
  } catch {
    return null;
  }
}

// What Claude Code says about each running session, by session id: its name,
// and its status — busy, idle, or waiting with what for (`input needed` while
// a question is up).
function peerNames() {
  const dir = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'sessions');
  const names = new Map();
  let files = [];
  try {
    files = readdirSync(dir).filter((n) => n.endsWith('.json'));
  } catch {
    return names;
  }
  for (const name of files) {
    try {
      const entry = JSON.parse(readFileSync(join(dir, name), 'utf8'));
      if (entry.sessionId) {
        names.set(entry.sessionId, {
          name: entry.name || null,
          status: entry.status || null,
          waiting_for: entry.waitingFor || null,
        });
      }
    } catch {}
  }
  return names;
}

// Every spooled session, drawn and tabulated, for the Agent Bar Hopping app:
// `cc-statusline.js live [--columns N]` prints one JSON document and exits.

function liveSnapshot(columns) {
  let names = [];
  try {
    names = readdirSync(LIVE_DIR).filter((n) => n.endsWith('.json'));
  } catch {
    return { live: [], history: [] };
  }

  const entries = [];
  for (const name of names) {
    const file = join(LIVE_DIR, name);
    try {
      const entry = JSON.parse(readFileSync(file, 'utf8'));
      if (!entry?.args?.input) continue;
      // The last prompt or reply, as the last redraw found it. A redraw is no
      // sign of activity: Claude Code redraws every open session on a timer.
      const transcript = entry.args.input.transcript_path;
      entries.push({
        file,
        updated_at: entry.updated_at,
        active_at: entry.last_message_at ?? entry.updated_at,
        // Older spools lack the field, so a missing time alone proves nothing.
        never_prompted: entry.last_message_at === null || entry.last_message_at === undefined,
        tty: entry.tty || null,
        pid: entry.pid || null,
        redraw: entry.redraw || null,
        ended: entry.ended || null,
        transcript_path: transcript || null,
        rows: render({ ...entry.args, columns }).split('\n'),
        // The duration in a spool was read at its redraw, not now.
        summary: summarize({ ...entry.args, now: entry.updated_at }),
        // The row's own segments, so a grid cell can show what the bar shows.
        segments: segments({ input: entry.args.input, usage: entry.args.usage, width: 5, now: entry.updated_at }),
      });
    } catch {
      // A half-written file is picked up on the next read.
    }
  }

  const now = Date.now();
  // A session whose process is gone has ended, however recently it drew. One
  // process can outlive a session — /clear and /resume start another in it —
  // so of the sessions sharing a pid only the latest to redraw is still open.
  const newestByPid = new Map();
  for (const e of entries) {
    if (e.pid && !(newestByPid.get(e.pid)?.updated_at >= e.updated_at)) newestByPid.set(e.pid, e);
  }
  const isLive = (e) =>
    e.pid ? newestByPid.get(e.pid) === e && processAlive(e.pid) : now - e.updated_at < LIVE_STALE_MS;
  const live = entries
    .filter(isLive)
    .sort((a, b) => String(a.tty).localeCompare(String(b.tty)) || a.updated_at - b.updated_at);
  const ended = entries.filter((e) => !isLive(e)).sort((a, b) => b.active_at - a.active_at);
  // Without a SessionEnd a finished session crashed, if it was still drawing
  // once they were recorded; before that, nothing can be said. A closed
  // terminal is not this: its hangup still runs the hook, as `other`.
  let endsSince = null;
  try {
    endsSince = Number(readFileSync(ENDS_SINCE, 'utf8')) || null;
  } catch {}
  for (const e of ended) {
    if (!e.ended && endsSince && e.updated_at >= endsSince) e.ended = { reason: 'crashed', at: null };
  }

  const peers = peerNames();
  for (const e of live) {
    const peer = peers.get(e.summary.session_id);
    e.peer_name = peer?.name ?? null;
    e.peer_status = peer?.status ?? null;
    e.peer_waiting_for = peer?.status === 'waiting' ? peer.waiting_for : null;
  }

  // Live sessions read what their transcripts gained; finished ones keep the
  // totals they ended with.
  for (const [list, fresh] of [[live, true], [ended.slice(0, LIVE_HISTORY_MAX), false]]) {
    for (const e of list) e.transcript = transcriptScan(e.summary.session_id, e.transcript_path, fresh);
  }

  // A session that ended without ever having a prompt has nothing to show and
  // nothing to resume: its spool goes as soon as it is found finished. Both
  // tests, since a spool from before last_message_at was recorded has none.
  const empty = new Set(ended.slice(0, LIVE_HISTORY_MAX).filter((e) => e.never_prompted && !e.transcript));
  // The oldest finished sessions fall off the end of the history.
  for (const stale of [...empty, ...ended.slice(LIVE_HISTORY_MAX)]) {
    try {
      unlinkSync(stale.file);
    } catch {}
    try {
      if (stale.summary.session_id) unlinkSync(scanPath(stale.summary.session_id));
    } catch {}
  }

  const strip = ({ file, transcript_path, never_prompted, ...rest }) => rest;
  // The Fable quota for the whole account, straight from the shared cache: a
  // session only reports it while it runs Fable, but the window shows it always.
  // Past its reset the reading is spent, and the quota is back to 0. Shown
  // whatever the server's is_active says, as claude.ai's usage page does.
  let fable = null;
  const cached = readUsageCache();
  if (cached?.fable && typeof cached.fable.percent === 'number') {
    const resets = Date.parse(cached.fable.resets_at) || null;
    const over = resets != null && resets <= now;
    fable = { percent: over ? 0 : cached.fable.percent, resets_at: over ? null : resets, read_at: cached.fetched_at ?? null };
  }
  const health = Object.entries(readHealth()).map(([key, value]) => ({ key, ...value }));
  return { live: live.map(strip), history: ended.slice(0, LIVE_HISTORY_MAX).filter((e) => !empty.has(e)).map(strip), fable, health };
}

function main() {
  const raw = readStdin();
  let input = {};
  if (raw) {
    try {
      input = JSON.parse(raw);
    } catch {}
  }

  const cwd = input.cwd || input.workspace?.current_dir || input.workspace?.project_dir || process.cwd();

  // The Fable quota only matters while this session runs Fable; other models
  // neither show it nor spend requests on it.
  let usage = null;
  if (isFable(input)) {
    usage = readUsageCache();
    maybeRefreshUsage(usage, input.rate_limits?.seven_day?.used_percentage ?? null);
  }

  let previous = null;
  try {
    previous = JSON.parse(readFileSync(spoolFile(input.session_id), 'utf8'));
  } catch {}
  const terminal = ownTerminal(previous);
  checkInput(input);
  const lastAt = lastMessageAt(input.transcript_path);
  const repo = cachedGit(cwd, previous, lastAt);
  // system-one's show-mode verdict row: only read when the app's toggle is on,
  // so a session that never turned it on pays nothing beyond the one cheap
  // display.json read. Kept in args (words, not the drawn row) the same way
  // topic and git are, so the live view carries it without a separate file.
  const verdictHook = readVerdictDisplay();
  const verdict = verdictHook ? readVerdict(input.session_id, verdictHook) : null;
  const args = {
    input,
    cwd,
    usage,
    topic: renderTopic(input.session_id || '', input.transcript_path, terminal.tty, lastAt),
    waiting: waitingAgents(input.session_id, input.transcript_path),
    peer: peerName(terminal.pid, input.session_id),
    git: repo.info,
    home: homedir(),
    verdict,
  };

  const out = render({
    ...args,
    // Any expectation broken anywhere: a red ! on every session's line.
    alarm: Object.keys(readHealth()).length > 0,
    columns: terminalColumns(terminal.tty),
    // Text in place of the few Nerd Font glyphs, for terminals without one.
    icons: process.env.CC_STATUSLINE_ICONS !== '0',
  });
  if (out) process.stdout.write(out);
  // After the line is out, so the terminal never waits on it.
  writeSpool(args, terminal, lastAt, repo.stamp);
}

if (process.argv[2] === 'live') {
  const columns = Number(argValue('--columns')) || 120;
  process.stdout.write(JSON.stringify(liveSnapshot(columns)) + '\n');
} else if (process.argv[2] === 'refresh-usage') {
  // For the app, once at launch: the Fable quota only moves while Fable runs,
  // and a Fable session keeps the cache fresh itself. Skipped while the cache
  // is younger than REFRESH_MS — a failed attempt stamps it too — so launching
  // the app again and again makes no more requests than one session would, and
  // while another refresh holds the lock.
  const age = Date.now() - (readUsageCache()?.fetched_at ?? 0);
  if (age >= REFRESH_MS && takeLock()) refreshUsage(null).catch((err) => logError(`refresh: ${err.message}`));
} else if (process.argv[2] === '--refresh-usage') {
  refreshUsage(process.argv[3]).catch((err) => logError(`refresh: ${err.message}`));
} else if (process.argv[2] === 'session-end') {
  try {
    recordSessionEnd(JSON.parse(readFileSync(0, 'utf8')));
  } catch (err) {
    logError(`session-end: ${err.message}`);
  }
} else if (process.argv[2] === '--refresh-topic') {
  refreshTopic(process.argv[3], process.argv[4]);
} else {
  try {
    main();
  } catch (err) {
    process.stderr.write(`cc-statusline: ${err.message}\n`);
    process.exit(0);
  }
}
