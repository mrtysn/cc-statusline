#!/usr/bin/env node
'use strict';

const { execFileSync } = require('child_process');
const { readFileSync } = require('fs');

const ESC = '\x1b[';
const RESET = ESC + '0m';
const BOLD = ESC + '1m';
const DIM = ESC + '2m';
const RED = ESC + '31m';
const GREEN = ESC + '32m';
const YELLOW = ESC + '33m';
const MAGENTA = ESC + '35m';
const ORANGE = ESC + '38;5;208m';

const args = process.argv.slice(2);
const ACCENT = args.includes('--accent') ? ORANGE : MAGENTA;

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

function git(cwd) {
  try {
    const opts = { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] };
    const branch = execFileSync('git', ['-C', cwd, 'branch', '--show-current'], opts).trim();
    if (!branch) return null;
    const dirty =
      execFileSync('git', ['-C', cwd, 'status', '--porcelain'], opts).trim().length > 0;
    return { branch, dirty };
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

  if (ctxPct != null) {
    const col = threshColor(ctxPct);
    parts.push(paint(DIM, 'ctx ') + paint(col, `${bar(ctxPct)} ${Math.round(ctxPct)}%`));
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
    parts.push(paint(DIM, ` ${g.branch}${g.dirty ? '*' : ''}`));
  }

  const sep = paint(DIM, ' │ ');
  process.stdout.write(parts.join(sep));
}

try {
  main();
} catch (err) {
  process.stderr.write(`cc-statusline: ${err.message}\n`);
  process.exit(0);
}
