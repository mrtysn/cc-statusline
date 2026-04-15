#!/usr/bin/env node
'use strict';

const { execFileSync } = require('child_process');
const { existsSync, readFileSync } = require('fs');
const { isAbsolute, join } = require('path');

const ESC = '\x1b[';
const RESET = ESC + '0m';
const DIM = ESC + '2m';
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

function bar(pct, width = 10) {
  const clamped = Math.max(0, Math.min(100, pct));
  const filled = Math.round((clamped / 100) * width);
  return '▰'.repeat(filled) + '▱'.repeat(width - filled);
}

function threshColor(pct) {
  if (pct >= 85) return RED;
  if (pct >= 70) return YELLOW;
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

function parseResetsAt(v) {
  if (v == null) return null;
  // Claude Code pipes resets_at as unix epoch seconds; tolerate ISO strings too.
  if (typeof v === 'number') return v * 1000;
  if (typeof v === 'string') {
    if (/^\d+$/.test(v)) return Number(v) * 1000;
    const t = new Date(v).getTime();
    return isNaN(t) ? null : t;
  }
  return null;
}

function fmtSessionStart(durationMs) {
  if (durationMs == null || durationMs < 0) return null;
  const d = new Date(Date.now() - durationMs);
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${days[d.getDay()]} ${d.getMonth() + 1}/${d.getDate()} ${hh}:${mm}`;
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

function renderBar(label, limit) {
  const pct = limit?.used_percentage;
  if (pct == null) return null;
  const col = threshColor(pct);
  const resetMs = parseResetsAt(limit.resets_at);
  const etaMs = resetMs != null ? resetMs - Date.now() : null;
  const eta = pct >= 90 && etaMs && etaMs > 0 ? ' ' + paint(DIM, '⟳' + fmtDuration(etaMs)) : '';
  return paint(DIM, `${label} `) + paint(col, `${bar(pct)} ${Math.round(pct)}%`) + eta;
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
  const durationMs = input.cost?.total_duration_ms ?? null;
  const startedAt = fmtSessionStart(durationMs);
  const elapsed = fmtDuration(durationMs);
  const ctxPct = input.context_window?.used_percentage ?? null;
  const cwd =
    input.cwd ||
    input.workspace?.current_dir ||
    input.workspace?.project_dir ||
    process.cwd();

  const rateLimits = input.rate_limits || {};
  const fiveHour = rateLimits.five_hour || null;
  const sevenDay = rateLimits.seven_day || null;

  const parts = [];

  if (sessionId) {
    parts.push(paint(DIM, sessionId));
  }

  if (startedAt) {
    parts.push(paint(DIM, startedAt));
  }

  if (ctxPct != null) {
    const col = threshColor(ctxPct);
    parts.push(paint(DIM, 'ctx ') + paint(col, `${bar(ctxPct)} ${Math.round(ctxPct)}%`));
  }

  if (elapsed) {
    parts.push(paint(DIM, elapsed));
  }

  const five = renderBar('5h', fiveHour);
  if (five) parts.push(five);

  const sevenPct = sevenDay?.used_percentage;
  if (sevenPct != null && sevenPct >= 90) {
    const seven = renderBar('7d', sevenDay);
    if (seven) parts.push(seven);
  }

  const g = git(cwd);
  if (g) {
    let s = ` ${g.branch}`;
    if (g.ahead) s += ` ⇡${g.ahead}`;
    if (g.behind) s += ` ⇣${g.behind}`;
    if (g.action) s += ` ${g.action}`;
    if (g.conflicts) s += ` ~${g.conflicts}`;
    if (g.staged) s += ` +${g.staged}`;
    if (g.unstaged) s += ` !${g.unstaged}`;
    if (g.untracked) s += ` ?${g.untracked}`;
    parts.push(paint(DIM, s));
  }

  if (parts.length === 0) return;
  const sep = paint(DIM, ' ▸ ');
  const open = paint(DIM, '◆ ');
  const close = paint(DIM, ' ◆');
  process.stdout.write(open + parts.join(sep) + close);
}

try {
  main();
} catch (err) {
  process.stderr.write(`cc-statusline: ${err.message}\n`);
  process.exit(0);
}
