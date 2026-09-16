#!/usr/bin/env node
'use strict';

const { execFileSync } = require('child_process');
const { existsSync, readFileSync } = require('fs');
const { homedir } = require('os');
const { basename, isAbsolute, join, resolve, sep } = require('path');

const ESC = '\x1b[';
const RESET = ESC + '0m';
const DIM = ESC + '2m';
const BOLD = ESC + '1m';
const RED = ESC + '31m';
const YELLOW = ESC + '33m';

function paint(color, s) {
  return color + s + RESET;
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

function fmtHoursRemaining(etaMs) {
  if (etaMs == null || etaMs <= 0) return null;
  return `${(etaMs / 3600000).toFixed(1)}h`;
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
  if (cache.warm && leftMs == null) return paint(DIM, 'cache warm');
  if (cache.warm && leftMs > 0) {
    // Colours by how much of the TTL has elapsed, on the same scale as the bars.
    const ttlMs = parseTtl(cache.ttl);
    const col = ttlMs ? threshColor(100 * (1 - leftMs / ttlMs)) : DIM;
    // Rounds up so a cache that is still warm never reads as 0m.
    return paint(col, 'cache ' + fmtDuration(Math.ceil(leftMs / 60000) * 60000));
  }
  const rebuild = cache.recache_tokens_if_cold;
  const detail = rebuild ? ` · ${fmtTokens(rebuild)} to rebuild` : '';
  return paint(YELLOW, 'cache cold' + detail);
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

  // Row 1: model and usage. Row 2: session and location.
  const usage = [];
  const where = [];

  // used_percentage stays null until the first API call, so it doubles as a
  // "nothing typed yet" flag. Shout the model and effort in that window —
  // after the first turn you are committed and the reminder is just noise.
  const untouched = ctxPct == null;
  const pick = untouched ? BOLD + YELLOW : '';

  if (model) {
    usage.push(paint(pick, model));
  }

  if (effort) {
    usage.push(paint(pick, effort));
  }

  if (startedAt) {
    usage.push(paint(DIM, startedAt));
  }

  if (ctxPct != null) {
    const col = threshColor(ctxPct);
    usage.push(paint(col, `${bar(ctxPct)} ${Math.round(ctxPct)}%`));
  }

  const five = renderBar('5h', fiveHour, { liveCountdown: true });
  if (five) usage.push(five);

  const sevenPct = sevenDay?.used_percentage;
  if (sevenPct != null && sevenPct >= 90) {
    const seven = renderBar('7d', sevenDay);
    if (seven) usage.push(seven);
  }

  const cache = renderCache(input.prompt_cache);
  if (cache) usage.push(cache);

  if (sessionId) {
    where.push(paint(DIM, sessionId));
  }

  where.push(renderLocation(cwd, projectDir));

  const g = git(cwd);
  if (g) {
    const dirty = g.staged || g.unstaged || g.untracked;
    const bits = [];
    if (g.ahead) bits.push(`⇡${g.ahead}`);
    if (g.behind) bits.push(`⇣${g.behind}`);
    if (g.action) bits.push(g.action);
    if (g.conflicts) bits.push(`~${g.conflicts}`);
    bits.push(`${dirty ? '*' : ''}${g.branch}`);
    where.push(paint(DIM, bits.join(' ')));
  }

  const divider = paint(DIM, ' ▸ ');
  const open = paint(DIM, '◆ ');
  const close = paint(DIM, ' ◆');
  const rows = [usage, where]
    .filter((parts) => parts.length)
    .map((parts) => open + parts.join(divider) + close);
  if (rows.length) process.stdout.write(rows.join('\n'));
}

try {
  main();
} catch (err) {
  process.stderr.write(`cc-statusline: ${err.message}\n`);
  process.exit(0);
}
