'use strict';

// The pure half of cc-statusline: turns the status line input plus the state the
// entry script gathers (usage cache, topic, git) into the rendered lines. No I/O,
// so the showcase page loads this same file in a browser.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.CcStatuslineRender = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  // The overall weekly bar stays hidden below this, where it is just noise.
  const SEVEN_DAY_SHOW_PCT = 75;
  const TOPIC_MAX_CHARS = 40;

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
  // Paths are POSIX: the Fable quota already assumes macOS.
  const SEP = '/';
  // Nerd Font glyphs (Material Design): md-database for the prompt cache,
  // md-refresh for the tokens a cold cache costs to rebuild.
  const CACHE_ICON = '\u{F01BC}';
  const REBUILD_ICON = '\u{F0450}';
  // Model tiers as a slope of braille steps, weakest to strongest, in display
  // order.
  const TIER_ICONS = { haiku: '⣀', sonnet: '⣤', opus: '⣶', fable: '⣿' };
  // Tags the Fable quota bar (md-alpha_f_box_outline): a step alone would not say Fable.
  const FABLE_TAG = '\u{F0BFA}';
  // Effort as a block height with its level 1-5 in superscript.
  const EFFORT_BARS = { low: '▁', medium: '▃', high: '▅', xhigh: '▇', max: '█' };
  const EFFORT_DIGITS = { low: '¹', medium: '²', high: '³', xhigh: '⁴', max: '⁵' };

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

  // A thin rule in half-cell steps: ╾ is heavy on its left half, light on its
  // right, so five cells show ten levels.
  function bar(pct, width) {
    const clamped = Math.max(0, Math.min(100, pct));
    const halves = Math.round((clamped / 100) * width * 2);
    const full = halves >> 1;
    const half = halves & 1;
    return '━'.repeat(full) + (half ? '╾' : '') + '─'.repeat(width - full - half);
  }

  // The percentage with its bar in front, or alone when the bar is squeezed out.
  function meter(pct, width) {
    const n = `${Math.round(pct)}%`;
    return width ? `${bar(pct, width)} ${n}` : n;
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

  // "Opus 4.8 (1M context)" -> "Opus 4.8 1M", spelled out before the first prompt.
  // Drops the parenthetical's "context" noise while keeping the rest; if the
  // convention changes, degrades to the untouched display name.
  function fullModelName(name) {
    if (!name) return null;
    return (
      name.replace(/\s*\(([^)]*)\)\s*$/, (_, inner) => {
        const t = inner.replace(/\bcontext\b/i, '').replace(/\s+/g, ' ').trim();
        return t ? ' ' + t : '';
      }) || null
    );
  }

  // All four steps side by side with the session's own lit and the rest in
  // the frame grey, so the tier reads as a position. /model offers one version
  // per tier, so the version and context size are left out; a name with no
  // known tier is shown untouched rather than guessed at.
  function renderModel(name, style) {
    if (!name) return null;
    const tier = /\b(fable|opus|sonnet|haiku)\b/i.exec(name)?.[1].toLowerCase();
    if (!tier) return paint(style, name);
    return Object.entries(TIER_ICONS)
      .map(([t, icon]) => paint(t === tier ? style : FRAME, icon))
      .join('');
  }

  function cleanTopic(s) {
    const one = String(s || '')
      .replace(/[\x00-\x1f\x7f]/g, ' ')
      .replace(/^["'`*#\s]+|["'`*.\s]+$/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    const chars = [...one];
    return chars.length > TOPIC_MAX_CHARS ? chars.slice(0, TOPIC_MAX_CHARS - 1).join('').trimEnd() + '…' : one;
  }

  function isFable(input) {
    return /fable/i.test(`${input.model?.id ?? ''} ${input.model?.display_name ?? ''}`);
  }

  // Absolute paths compare equal regardless of trailing or doubled separators.
  function samePath(a, b) {
    const norm = (p) => p.split(SEP).filter(Boolean).join(SEP);
    return norm(a) === norm(b);
  }

  function baseName(p) {
    return p.split(SEP).filter(Boolean).pop() || p;
  }

  function tildify(p, home) {
    if (!home) return p;
    if (p === home) return '~';
    return p.startsWith(home + SEP) ? '~' + p.slice(home.length) : p;
  }

  // Dims the parent path so the directory name stands out.
  function renderPath(p, home) {
    const shown = tildify(p, home);
    const cut = shown.lastIndexOf(SEP) + 1;
    if (cut === 0 || cut === shown.length) return shown;
    return paint(DIM, shown.slice(0, cut)) + shown.slice(cut);
  }

  // Names the launch directory first when the session has moved away from it.
  function renderLocation(cwd, projectDir, home) {
    const here = renderPath(cwd, home);
    if (!projectDir || samePath(projectDir, cwd)) return here;
    return paint(DIM, `${baseName(projectDir)} → `) + here;
  }

  function renderCache(cache) {
    if (!cache?.caching_observed) return null;
    const expiresMs = parseEpoch(cache.expires_at);
    const leftMs = expiresMs != null ? expiresMs - Date.now() : null;
    if (cache.warm && leftMs == null) return paint(DIM, CACHE_ICON + ' warm');
    if (cache.warm && leftMs > 0) {
      // Colours by how much of the TTL has elapsed, on the same scale as the bars.
      const ttlMs = parseTtl(cache.ttl);
      const col = ttlMs ? threshColor(100 * (1 - leftMs / ttlMs)) : DIM;
      // Rounds up so a cache that is still warm never reads as 0m.
      return paint(col, CACHE_ICON + ' ' + fmtDuration(Math.ceil(leftMs / 60000) * 60000));
    }
    const rebuild = cache.recache_tokens_if_cold;
    const detail = rebuild ? ` · ${fmtTokens(rebuild)} to ${REBUILD_ICON}` : '';
    return paint(YELLOW, CACHE_ICON + ' cold' + detail);
  }

  // Labelled with the time until reset, or `label` when that is unknown. `tag`
  // follows the percentage to tell apart bars whose labels are both durations.
  function renderBar(label, limit, width, tag) {
    const pct = limit?.used_percentage;
    if (pct == null) return null;
    const col = threshColor(pct);
    const resetMs = parseEpoch(limit.resets_at);
    const live = fmtHoursRemaining(resetMs != null ? resetMs - Date.now() : null);
    const suffix = live && tag ? ' ' + paint(DIM, tag) : '';
    return paint(DIM, `${live || label} `) + paint(col, meter(pct, width)) + suffix;
  }

  // The Fable weekly bar, skipped when the server reports that quota inactive. A red
  // "!" follows when the last refresh failed; details are in error.log.
  function renderFable(cached, width) {
    if (!cached) return null;
    const mark = cached.error ? ' ' + paint(RED, '!') : '';
    const fable = cached.fable;
    if (!fable) return mark ? paint(DIM, FABLE_TAG) + mark : null;
    if (!fable.is_active) return null;
    const shown = renderBar(FABLE_TAG, { used_percentage: fable.percent, resets_at: fable.resets_at }, width, FABLE_TAG);
    return shown ? shown + mark : null;
  }

  // info: { branch, ahead, behind, staged, unstaged, untracked, conflicts, action }.
  function renderGit(g) {
    const dirty = g.staged || g.unstaged || g.untracked;
    const bits = [];
    if (g.ahead) bits.push(`⇡${g.ahead}`);
    if (g.behind) bits.push(`⇣${g.behind}`);
    if (g.action) bits.push(g.action);
    if (g.conflicts) bits.push(`~${g.conflicts}`);
    bits.push(`${dirty ? '*' : ''}${g.branch}`);
    return paint(DIM, bits.join(' '));
  }

  // Every row spans the same width: spare columns are spread over the gaps,
  // the two inside the diamonds included.
  const content = (parts) => parts.reduce((sum, part) => sum + visibleWidth(part), 0);
  // Minimum gaps: EDGE inside each diamond, one space on each side of every arrow.
  const minGaps = (parts) => [EDGE, ...Array(2 * (parts.length - 1)).fill(1), EDGE];
  const sum = (ns) => ns.reduce((total, n) => total + n, 0);
  // The narrowest a row can be drawn: two diamonds, the arrows, the minimum gaps.
  const rowWidth = (parts) => 2 + content(parts) + (parts.length - 1) + sum(minGaps(parts));

  function layout(rows) {
    rows = rows.filter((parts) => parts.length);
    const width = Math.max(0, ...rows.map(rowWidth));
    return rows.map((parts) => {
      const gaps = fillGaps(width - 2 - content(parts) - (parts.length - 1), minGaps(parts));
      let line = paint(FRAME, '◆' + ' '.repeat(gaps[0]));
      parts.forEach((part, i) => {
        if (i) line += paint(FRAME, ' '.repeat(gaps[2 * i - 1]) + '▸' + ' '.repeat(gaps[2 * i]));
        line += part;
      });
      return line + paint(FRAME, ' '.repeat(gaps[gaps.length - 1]) + '◆');
    });
  }

  // Bar widths tried in turn until the top row fits the terminal; 0 keeps only
  // the percentages.
  const BAR_WIDTHS = [5, 3, 0];

  // Row 1: model and usage, with every bar `width` cells wide.
  function usageRow(input, usage, width) {
    const ctxPct = input.context_window?.used_percentage ?? null;
    const rateLimits = input.rate_limits || {};
    const effort = input.effort?.level || null;
    const startedAt = fmtSessionStart(input.cost?.total_duration_ms ?? null);
    const top = [];

    // used_percentage stays null until the first API call, so it doubles as a
    // "nothing typed yet" flag. Shout the model and effort in that window —
    // after the first turn you are committed and the reminder is just noise.
    const pick = ctxPct == null ? BOLD + YELLOW : '';
    const modelName = input.model?.display_name || input.model?.id;
    // Model and effort share one segment: the effort level only means something beside it.
    // Before the first prompt both are spelled out in full, so the choice can be
    // checked while it can still be changed; after it, the compact strip and bar.
    // The lit step takes the colour of the model's own quota once that is yellow
    // or red; account-wide limits say nothing about the model, so they don't.
    const quota = isFable(input) && usage?.fable?.is_active ? threshColor(usage.fable.percent) : DIM;
    const lit = quota === DIM ? pick : (ctxPct == null ? BOLD : '') + quota;
    const model = renderModel(modelName, lit);
    // The effort bar likewise takes the context bar's colour near the limit.
    const ctxCol = ctxPct != null ? threshColor(ctxPct) : DIM;
    const level = !effort
      ? null
      : EFFORT_BARS[effort]
        ? paint(ctxCol === DIM ? pick : ctxCol, EFFORT_BARS[effort]) + paint(pick, EFFORT_DIGITS[effort])
        : paint(pick, effort);
    const head =
      ctxPct == null
        ? paint(pick, [fullModelName(modelName), effort].filter(Boolean).join(' '))
        : [model, level].filter(Boolean).join(' ');
    if (head) top.push(head);
    if (startedAt) top.push(paint(DIM, startedAt));
    if (ctxPct != null) top.push(paint(threshColor(ctxPct), meter(ctxPct, width)));

    const five = renderBar('5h', rateLimits.five_hour || null, width);
    if (five) top.push(five);

    const sevenDay = rateLimits.seven_day || null;
    const sevenPct = sevenDay?.used_percentage;
    if (sevenPct != null && sevenPct >= SEVEN_DAY_SHOW_PCT) {
      const seven = renderBar('7d', sevenDay, width);
      if (seven) top.push(seven);
    }

    // The Fable quota only matters while this session runs Fable.
    if (isFable(input)) {
      const fable = renderFable(usage, width);
      if (fable) top.push(fable);
    }

    const cache = renderCache(input.prompt_cache);
    if (cache) top.push(cache);
    return top;
  }

  // input: the status line JSON from Claude Code. cwd: already resolved from it.
  // usage: the usage cache, read only for Fable sessions. topic: { text, isNew }.
  // git: the parsed status, or null outside a repository. home: for "~".
  // columns: the terminal width, or null when unknown (bars stay full width).
  function render({ input = {}, cwd, usage = null, topic = null, git = null, home = '', columns = null }) {
    const sessionId = input.session_id || '';
    const projectDir = input.workspace?.project_dir || null;

    // Claude Code keeps EDGE columns clear on both sides and cuts anything wider
    // with an ellipsis.
    let top;
    for (const width of BAR_WIDTHS) {
      top = usageRow(input, usage, width);
      if (!columns || rowWidth(top) + 2 * EDGE <= columns) break;
    }

    // Row 2: session topic. Row 3: session and location.
    const middle = [];
    const bottom = [];
    if (topic?.text) middle.push(paint(topic.isNew ? YELLOW : '', topic.text));

    if (sessionId) bottom.push(paint(DIM, sessionId));
    if (cwd) bottom.push(renderLocation(cwd, projectDir, home));
    if (git?.branch) bottom.push(renderGit(git));

    return layout([top, middle, bottom]).join('\n');
  }

  return { render, cleanTopic, isFable, TOPIC_MAX_CHARS, SEVEN_DAY_SHOW_PCT };
});
