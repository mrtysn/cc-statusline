#!/usr/bin/env node
'use strict';

const { execFileSync, spawn } = require('child_process');
const {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} = require('fs');
const { homedir } = require('os');
const { basename, isAbsolute, join, resolve, sep } = require('path');

// The Fable weekly quota is not in the statusline input; it comes from the
// account usage endpoint, cached once for every session on the machine.
const CACHE_DIR = process.env.CC_STATUSLINE_CACHE_DIR || join(homedir(), '.cache', 'cc-statusline');
const USAGE_FILE = join(CACHE_DIR, 'usage.json');
const LOCK_FILE = join(CACHE_DIR, 'refresh.lock');
const ERROR_LOG = join(CACHE_DIR, 'error.log');
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const REFRESH_MS = 5 * 60000;
// Floor for the early refresh when the 7-day figure moves mid-turn.
const MIN_REFRESH_MS = 60000;
const LOCK_STALE_MS = 30000;
const LOG_MAX_BYTES = 256 * 1024;

const ESC = '\x1b[';
const RESET = ESC + '0m';
const DIM = ESC + '2m';
const BOLD = ESC + '1m';
const RED = ESC + '31m';
const YELLOW = ESC + '33m';
// Arrows and diamonds: a grey one step below faint, tuned for a dark blue-grey theme.
const FRAME = ESC + '38;2;66;69;80m';
// Claude Code indents the status line two columns; the space inside each
// diamond is never narrower than that indent.
const EDGE = 2;

function paint(color, s) {
  return color + s + RESET;
}

function visibleWidth(s) {
  return [...s.replace(/\x1b\[[0-9;]*m/g, '')].length;
}

// Splits total into n integer parts that differ by at most one.
function spread(total, n) {
  return Array.from({ length: n }, (_, i) => Math.floor(((i + 1) * total) / n) - Math.floor((i * total) / n));
}

// Hands out total columns across gaps, widening the narrowest first so the
// gaps even out, and never going below each gap's minimum.
function fillGaps(total, mins) {
  let level = 0;
  while (mins.reduce((sum, m) => sum + Math.max(m, level + 1), 0) <= total) level++;
  const gaps = mins.map((m) => Math.max(m, level));
  const lowest = gaps.flatMap((g, i) => (g === level ? [i] : []));
  const extra = total - gaps.reduce((sum, g) => sum + g, 0);
  spread(extra, lowest.length).forEach((add, j) => {
    gaps[lowest[j]] += add;
  });
  return gaps;
}

function readStdin() {
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function bar(pct, width = 5) {
  const clamped = Math.max(0, Math.min(100, pct));
  const filled = Math.round((clamped / 100) * width);
  return '▰'.repeat(filled) + '▱'.repeat(width - filled);
}

function threshColor(pct) {
  if (pct >= 92) return RED;
  if (pct >= 80) return YELLOW;
  return DIM;
}

function fmtDuration(ms) {
  if (ms == null || ms <= 0) return '';
  const mins = Math.floor(ms / 60000);
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  const rem = mins % 60;
  if (hrs < 24) return rem ? `${hrs}h${rem}m` : `${hrs}h`;
  return `${Math.floor(hrs / 24)}d`;
}

// Days past the first 24 hours, so a weekly reset reads 5.2d rather than 124.8h.
function fmtHoursRemaining(etaMs) {
  if (etaMs == null || etaMs <= 0) return null;
  const hrs = etaMs / 3600000;
  return hrs >= 24 ? `${(hrs / 24).toFixed(1)}d` : `${hrs.toFixed(1)}h`;
}

function fmtTokens(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return String(n);
}

function parseEpoch(v) {
  if (v == null) return null;
  // Claude Code pipes timestamps as unix epoch seconds; tolerate ISO strings too.
  if (typeof v === 'number') return v * 1000;
  if (typeof v === 'string') {
    if (/^\d+$/.test(v)) return Number(v) * 1000;
    const t = new Date(v).getTime();
    return isNaN(t) ? null : t;
  }
  return null;
}

// "5m" / "1h" -> milliseconds.
function parseTtl(v) {
  const m = /^(\d+)([smh])$/.exec(v || '');
  if (!m) return null;
  return Number(m[1]) * { s: 1000, m: 60000, h: 3600000 }[m[2]];
}

function fmtSessionStart(durationMs) {
  if (durationMs == null || durationMs < 0) return null;
  const d = new Date(Date.now() - durationMs);
  const mo = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${mo}/${dd} ${hh}:${mm}`;
}

// "Opus 4.8 (1M context)" -> "Opus 4.8 1M". Drops the parenthetical's "context"
// noise while keeping the rest; if the convention changes, degrades to the
// untouched display name rather than producing a wrong label.
function shortenModel(name) {
  if (!name) return null;
  return (
    name.replace(/\s*\(([^)]*)\)\s*$/, (_, inner) => {
      const t = inner.replace(/\bcontext\b/i, '').replace(/\s+/g, ' ').trim();
      return t ? ' ' + t : '';
    }) || null
  );
}

function tildify(p) {
  const home = homedir();
  if (p === home) return '~';
  return p.startsWith(home + sep) ? '~' + p.slice(home.length) : p;
}

// Dims the parent path so the directory name stands out.
function renderPath(p) {
  const shown = tildify(p);
  const cut = shown.lastIndexOf(sep) + 1;
  if (cut === 0 || cut === shown.length) return shown;
  return paint(DIM, shown.slice(0, cut)) + shown.slice(cut);
}

// Names the launch directory first when the session has moved away from it.
function renderLocation(cwd, projectDir) {
  const here = renderPath(cwd);
  if (!projectDir || resolve(projectDir) === resolve(cwd)) return here;
  return paint(DIM, `${basename(projectDir)} → `) + here;
}

function renderCache(cache) {
  if (!cache?.caching_observed) return null;
  const expiresMs = parseEpoch(cache.expires_at);
  const leftMs = expiresMs != null ? expiresMs - Date.now() : null;
  if (cache.warm && leftMs == null) return paint(DIM, 'cch warm');
  if (cache.warm && leftMs > 0) {
    // Colours by how much of the TTL has elapsed, on the same scale as the bars.
    const ttlMs = parseTtl(cache.ttl);
    const col = ttlMs ? threshColor(100 * (1 - leftMs / ttlMs)) : DIM;
    // Rounds up so a cache that is still warm never reads as 0m.
    return paint(col, 'cch ' + fmtDuration(Math.ceil(leftMs / 60000) * 60000));
  }
  const rebuild = cache.recache_tokens_if_cold;
  const detail = rebuild ? ` · ${fmtTokens(rebuild)} to rebuild` : '';
  return paint(YELLOW, 'cch cold' + detail);
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
      const gitDir = execFileSync('git', ['-C', cwd, 'rev-parse', '--git-dir'], opts).trim();
      const absGitDir = isAbsolute(gitDir) ? gitDir : join(cwd, gitDir);
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

function renderBar(label, limit, opts = {}) {
  const pct = limit?.used_percentage;
  if (pct == null) return null;
  const col = threshColor(pct);
  const resetMs = parseEpoch(limit.resets_at);
  const etaMs = resetMs != null ? resetMs - Date.now() : null;
  let displayLabel = label;
  if (opts.liveCountdown) {
    const live = fmtHoursRemaining(etaMs);
    if (live) displayLabel = live;
  }
  const eta =
    !opts.liveCountdown && pct >= 90 && etaMs && etaMs > 0
      ? ' ' + paint(DIM, '⟳' + fmtDuration(etaMs))
      : '';
  return paint(DIM, `${displayLabel} `) + paint(col, `${bar(pct)} ${Math.round(pct)}%`) + eta;
}

function readUsageCache() {
  try {
    return JSON.parse(readFileSync(USAGE_FILE, 'utf8'));
  } catch {
    return null;
  }
}

function logError(message) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    if (existsSync(ERROR_LOG) && statSync(ERROR_LOG).size > LOG_MAX_BYTES) writeFileSync(ERROR_LOG, '');
    appendFileSync(ERROR_LOG, `${new Date().toISOString()} ${message}\n`);
  } catch {}
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
    spawn(process.execPath, args, { detached: true, stdio: 'ignore' }).unref();
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
  } catch (err) {
    next.error = err.message;
    logError(err.message);
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

// The Fable weekly bar, skipped when the server reports that quota inactive. A red
// "!" follows when the last refresh failed; details are in error.log.
function renderFable(cached) {
  if (!cached) return null;
  const mark = cached.error ? ' ' + paint(RED, '!') : '';
  const fable = cached.fable;
  if (!fable) return mark ? paint(DIM, 'fbl') + mark : null;
  if (!fable.is_active) return null;
  const shown = renderBar('fbl', { used_percentage: fable.percent, resets_at: fable.resets_at }, { liveCountdown: true });
  return shown ? shown + mark : null;
}

function main() {
  const raw = readStdin();
  let input = {};
  if (raw) {
    try {
      input = JSON.parse(raw);
    } catch {}
  }

  const sessionId = input.session_id || '';
  const model = shortenModel(input.model?.display_name || input.model?.id);
  const effort = input.effort?.level || null;
  const durationMs = input.cost?.total_duration_ms ?? null;
  const startedAt = fmtSessionStart(durationMs);
  const ctxPct = input.context_window?.used_percentage ?? null;
  const projectDir = input.workspace?.project_dir || null;
  const cwd =
    input.cwd ||
    input.workspace?.current_dir ||
    projectDir ||
    process.cwd();

  const rateLimits = input.rate_limits || {};
  const fiveHour = rateLimits.five_hour || null;
  const sevenDay = rateLimits.seven_day || null;

  // Row 1: model and usage. Row 2: session and location. The narrower row is
  // spread out so both rows span the same width.
  const top = [];
  const bottom = [];

  // used_percentage stays null until the first API call, so it doubles as a
  // "nothing typed yet" flag. Shout the model and effort in that window —
  // after the first turn you are committed and the reminder is just noise.
  const untouched = ctxPct == null;
  const pick = untouched ? BOLD + YELLOW : '';

  if (model) {
    top.push(paint(pick, model));
  }

  if (effort) {
    top.push(paint(pick, effort));
  }

  if (startedAt) {
    top.push(paint(DIM, startedAt));
  }

  if (ctxPct != null) {
    const col = threshColor(ctxPct);
    top.push(paint(col, `${bar(ctxPct)} ${Math.round(ctxPct)}%`));
  }

  const five = renderBar('5h', fiveHour, { liveCountdown: true });
  if (five) top.push(five);

  const sevenPct = sevenDay?.used_percentage;
  if (sevenPct != null && sevenPct >= 90) {
    const seven = renderBar('7d', sevenDay);
    if (seven) top.push(seven);
  }

  // The Fable quota only matters while this session runs Fable; other models
  // neither show it nor spend requests on it.
  if (/fable/i.test(`${input.model?.id ?? ''} ${input.model?.display_name ?? ''}`)) {
    const usage = readUsageCache();
    maybeRefreshUsage(usage, sevenPct ?? null);
    const fable = renderFable(usage);
    if (fable) top.push(fable);
  }

  const cache = renderCache(input.prompt_cache);
  if (cache) top.push(cache);

  if (sessionId) {
    bottom.push(paint(DIM, sessionId));
  }

  bottom.push(renderLocation(cwd, projectDir));

  const g = git(cwd);
  if (g) {
    const dirty = g.staged || g.unstaged || g.untracked;
    const bits = [];
    if (g.ahead) bits.push(`⇡${g.ahead}`);
    if (g.behind) bits.push(`⇣${g.behind}`);
    if (g.action) bits.push(g.action);
    if (g.conflicts) bits.push(`~${g.conflicts}`);
    bits.push(`${dirty ? '*' : ''}${g.branch}`);
    bottom.push(paint(DIM, bits.join(' ')));
  }

  const rows = [top, bottom].filter((parts) => parts.length);
  const content = (parts) => parts.reduce((sum, part) => sum + visibleWidth(part), 0);
  // Minimum gaps: EDGE inside each diamond, one space on each side of every arrow.
  const minGaps = (parts) => [EDGE, ...Array(2 * (parts.length - 1)).fill(1), EDGE];
  const sum = (ns) => ns.reduce((total, n) => total + n, 0);
  const width = Math.max(0, ...rows.map((parts) => 2 + content(parts) + (parts.length - 1) + sum(minGaps(parts))));
  const lines = rows.map((parts) => {
    // Spreads the spare columns over every gap, the two inside the diamonds included.
    const gaps = fillGaps(width - 2 - content(parts) - (parts.length - 1), minGaps(parts));
    let line = paint(FRAME, '◆' + ' '.repeat(gaps[0]));
    parts.forEach((part, i) => {
      if (i) line += paint(FRAME, ' '.repeat(gaps[2 * i - 1]) + '▸' + ' '.repeat(gaps[2 * i]));
      line += part;
    });
    return line + paint(FRAME, ' '.repeat(gaps[gaps.length - 1]) + '◆');
  });
  if (lines.length) process.stdout.write(lines.join('\n'));
}

if (process.argv[2] === '--refresh-usage') {
  refreshUsage(process.argv[3]).catch((err) => logError(`refresh: ${err.message}`));
} else {
  try {
    main();
  } catch (err) {
    process.stderr.write(`cc-statusline: ${err.message}\n`);
    process.exit(0);
  }
}
