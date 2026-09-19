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
  const BLUE = ESC + '34m';
  // Arrows and diamonds: a grey one step below faint, tuned for a dark blue-grey theme.
  const FRAME = ESC + '38;2;66;69;80m';
  // Claude Code indents the status line two columns; the space inside each
  // diamond is never narrower than that indent.
  const EDGE = 2;
  // Paths are POSIX: the Fable quota already assumes macOS.
  const SEP = '/';
  // The only Nerd Font glyphs (Material Design): md-database for the prompt
  // cache, md-refresh for the tokens a cold cache costs to rebuild, and
  // md-alpha_f tagging the Fable quota bar, md-earth tagging the
  // account-wide weekly bar it is a subset of. Without a Nerd Font they
  // would draw as boxes, so render() can swap in text.
  const NERD_GLYPHS = { cache: '\u{F01BC}', rebuild: '\u{F0450}', fable: '\u{F0AF3}', weekly: '\u{F01E7}' };
  const TEXT_GLYPHS = { cache: 'cch', rebuild: '⟳', fable: 'fbl', weekly: 'all' };
  // Model tiers as a slope of braille steps, weakest to strongest, in display
  // order.
  const TIER_ICONS = { haiku: '⣀', sonnet: '⣤', opus: '⣶', fable: '⣿' };
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

  // The share right after its bar as a decimal fraction (.08, .87, 1.0), or
  // alone when the bar is squeezed out.
  function meter(pct, width) {
    const r = Math.max(0, Math.min(100, Math.round(pct)));
    const n = r === 100 ? '1.0' : '.' + String(r).padStart(2, '0');
    return width ? bar(pct, width) + n : n;
  }

  function threshColor(pct) {
    if (pct >= 92) return RED;
    if (pct >= 75) return YELLOW;
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
  // A whole number keeps no decimal: one decimal place in days is a 2.4 hour
  // step, and "2.0d" claims a precision the figure does not have.
  function fmtHoursRemaining(etaMs) {
    if (etaMs == null || etaMs <= 0) return null;
    const hrs = etaMs / 3600000;
    const [value, unit] = hrs >= 24 ? [hrs / 24, 'd'] : [hrs, 'h'];
    const shown = value.toFixed(1);
    return (shown.endsWith('.0') ? shown.slice(0, -2) : shown) + unit;
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
  // The tier word alone: what the strip draws as a step, spelled out.
  function shortenModel(name) {
    if (!name) return null;
    const tier = /\b(fable|opus|sonnet|haiku)\b/i.exec(name)?.[1].toLowerCase();
    return tier ? tier[0].toUpperCase() + tier.slice(1) : name;
  }

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

  // Time units raised, digits left full size: 1ʰ30ᵐ, 2.6ᵈ.
  const UNITS = { d: 'ᵈ', h: 'ʰ', m: 'ᵐ' };
  function raiseUnits(s) {
    return [...s].map((c) => UNITS[c] || c).join('');
  }



  function renderCache(cache, glyphs) {
    if (!cache?.caching_observed) return null;
    const expiresMs = parseEpoch(cache.expires_at);
    const leftMs = expiresMs != null ? expiresMs - Date.now() : null;
    if (cache.warm && leftMs == null) return paint(DIM, glyphs.cache);
    const rebuild = cache.recache_tokens_if_cold;
    if (cache.warm && leftMs > 0) {
      // Colours by how much of the TTL has elapsed, on the same scale as the bars.
      const ttlMs = parseTtl(cache.ttl);
      const col = ttlMs ? threshColor(100 * (1 - leftMs / ttlMs)) : DIM;
      // Rounds up so a cache that is still warm never reads as 0m.
      const time = raiseUnits(fmtDuration(Math.ceil(leftMs / 60000) * 60000));
      // Once the countdown turns, the size of the rebuild at stake joins it, while
      // there is still time to /compact or wrap up before it goes cold.
      const stake = col !== DIM && rebuild ? ` ${fmtTokens(rebuild)}` : '';
      return paint(col, `${glyphs.cache} ${time}${stake}`);
    }
    // Cold is not a warning, just a heads-up about the next prompt's cost; the
    // colour alone marks it, with the tokens to rebuild when known.
    return paint(BLUE, glyphs.cache + (rebuild ? ` ${fmtTokens(rebuild)} ${glyphs.rebuild}` : ''));
  }

  // Labelled with the time until reset, or `label` when that is unknown. `tag`
  // follows the percentage to tell apart bars whose labels are both durations.
  function renderBar(label, limit, width, tag) {
    const pct = limit?.used_percentage;
    if (pct == null) return null;
    const col = threshColor(pct);
    const resetMs = parseEpoch(limit.resets_at);
    const eta = fmtHoursRemaining(resetMs != null ? resetMs - Date.now() : null);
    const live = eta && raiseUnits(eta);
    // The tag takes the bar's colour: it names the same limit.
    const suffix = live && tag ? ' ' + paint(col, tag) : '';
    return paint(DIM, `${live || label} `) + paint(col, meter(pct, width)) + suffix;
  }

  // The Fable weekly bar, skipped when the server reports that quota inactive. A red
  // "!" follows when the last refresh failed; details are in error.log.
  function renderFable(cached, width, glyphs) {
    if (!cached) return null;
    const mark = cached.error ? ' ' + paint(RED, '!') : '';
    const fable = cached.fable;
    if (!fable) return mark ? paint(DIM, glyphs.fable) + mark : null;
    if (!fable.is_active) return null;
    const shown = renderBar(glyphs.fable, { used_percentage: fable.percent, resets_at: fable.resets_at }, width, glyphs.fable);
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
  // The first row's segments, named. The row is these in order; a view that
  // tabulates sessions draws them one per cell instead.
  function usageSegments(input, usage, width, glyphs) {
    const ctxPct = input.context_window?.used_percentage ?? null;
    const rateLimits = input.rate_limits || {};
    const effort = input.effort?.level || null;
    const startedAt = fmtSessionStart(input.cost?.total_duration_ms ?? null);
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
    const sevenDay = rateLimits.seven_day || null;
    const sevenPct = sevenDay?.used_percentage;

    return {
      // Model and effort as one segment, and each on its own for a grid.
      head: head || null,
      model: ctxPct == null ? paint(pick, fullModelName(modelName) || '') || null : model,
      effort: level,
      started: startedAt ? paint(DIM, startedAt) : null,
      context: ctxPct != null ? paint(threshColor(ctxPct), meter(ctxPct, width)) : null,
      five_hour: renderBar('5h', rateLimits.five_hour || null, width),
      // The overall weekly bar stays hidden below its threshold in the row; a
      // grid column has room for it either way, so both are returned.
      seven_day: renderBar('7d', sevenDay, width, glyphs.weekly),
      seven_day_shown: sevenPct != null && sevenPct >= SEVEN_DAY_SHOW_PCT,
      fable: isFable(input) ? renderFable(usage, width, glyphs) : null,
      cache: renderCache(input.prompt_cache, glyphs),
    };
  }

  function usageRow(input, usage, width, glyphs) {
    const seg = usageSegments(input, usage, width, glyphs);
    return [
      seg.head,
      seg.started,
      seg.context,
      seg.five_hour,
      seg.seven_day_shown ? seg.seven_day : null,
      seg.fable,
      seg.cache,
    ].filter(Boolean);
  }

  // input: the status line JSON from Claude Code. cwd: already resolved from it.
  // usage: the usage cache, read only for Fable sessions. topic: { text, isNew }.
  // git: the parsed status, or null outside a repository. home: for "~".
  // columns: the terminal width, or null when unknown (bars stay full width).
  function render({ input = {}, cwd, usage = null, topic = null, git = null, home = '', columns = null, icons = true }) {
    const glyphs = icons ? NERD_GLYPHS : TEXT_GLYPHS;
    const sessionId = input.session_id || '';
    const projectDir = input.workspace?.project_dir || null;

    // Claude Code keeps EDGE columns clear on both sides and cuts anything wider
    // with an ellipsis.
    let top;
    for (const width of BAR_WIDTHS) {
      top = usageRow(input, usage, width, glyphs);
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

  // The same state as a row of values, for a view that tabulates sessions
  // instead of drawing their bars. Percentages are 0-100 or null; times are
  // epoch milliseconds so the caller can age them itself.
  function summarize({ input = {}, cwd, usage = null, topic = null, git = null, home = '' }) {
    const cache = input.prompt_cache;
    const expiresMs = cache?.caching_observed ? parseEpoch(cache.expires_at) : null;
    const fable = isFable(input) && usage?.fable?.is_active ? usage.fable : null;
    const limit = (l) => ({
      percent: l?.used_percentage ?? null,
      resets_at: parseEpoch(l?.resets_at ?? null),
    });
    return {
      session_id: input.session_id || null,
      model: shortenModel(input.model?.display_name || input.model?.id) || null,
      model_id: input.model?.id || null,
      effort: input.effort?.level || null,
      started_at: input.cost?.total_duration_ms != null ? Date.now() - input.cost.total_duration_ms : null,
      context: input.context_window?.used_percentage ?? null,
      five_hour: limit(input.rate_limits?.five_hour),
      seven_day: limit(input.rate_limits?.seven_day),
      fable: fable ? { percent: fable.percent, resets_at: parseEpoch(fable.resets_at) } : null,
      fable_error: isFable(input) ? usage?.error ?? null : null,
      cache: cache?.caching_observed
        ? { warm: !!cache.warm, expires_at: expiresMs, ttl: cache.ttl ?? null, rebuild: cache.recache_tokens_if_cold ?? null }
        : null,
      topic: topic?.text || null,
      topic_is_new: !!topic?.isNew,
      cwd: cwd ? tildify(cwd, home) : null,
      project_dir: input.workspace?.project_dir ? tildify(input.workspace.project_dir, home) : null,
      git: git || null,
    };
  }

  // The same segments a row is built from, for a view that lays them out in
  // cells: each is the drawn segment, escapes and all, at `width` bar cells.
  function segments({ input = {}, usage = null, width = 5, icons = true }) {
    return usageSegments(input, usage, width, icons ? NERD_GLYPHS : TEXT_GLYPHS);
  }

  return { render, summarize, segments, cleanTopic, isFable, TOPIC_MAX_CHARS, SEVEN_DAY_SHOW_PCT };
});
