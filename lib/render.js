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
  // Claude Code's own orange, for the ✻ it draws beside a pending agent.
  const ORANGE = ESC + '38;2;215;119;87m';
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

  // A tag's colour as a 24-bit foreground escape, from its six hex digits.
  function tagColour(hex) {
    const v = parseInt(hex, 16);
    return `${ESC}38;2;${(v >> 16) & 255};${(v >> 8) & 255};${v & 255}m`;
  }

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

  // `now` is when the duration was read: a live redraw's own moment, or for a
  // view drawn later from a saved redraw, the time that redraw happened.
  function fmtSessionStart(durationMs, now = Date.now()) {
    if (durationMs == null || durationMs < 0) return null;
    const d = new Date(now - durationMs);
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

  // Keeps the end of a path, which says where you are: a deep tree becomes
  // …/song-processing-tools rather than being cut off at its far end.
  function trimPath(shown, max) {
    const chars = [...shown];
    if (chars.length <= max) return shown;
    const parts = shown.split(SEP);
    let kept = parts[parts.length - 1];
    // "…/" stands for everything dropped, so it costs two columns.
    for (let i = parts.length - 2; i > 0; i--) {
      const wider = parts[i] + SEP + kept;
      if ([...wider].length + 2 > max) break;
      kept = wider;
    }
    const tail = [...kept];
    if (tail.length + 2 <= max) return '…' + SEP + kept;
    // Not even one name fits whole: keep its end, which tells them apart.
    return '…' + tail.slice(Math.max(0, tail.length - (max - 1))).join('');
  }

  function cut(text, max) {
    const chars = [...text];
    return chars.length <= max ? text : chars.slice(0, max - 1).join('') + '…';
  }

  // Names the launch directory first when the session has moved away from it.
  // `prefix` and `max` are what a narrow terminal takes away, in that order.
  function renderLocation(cwd, projectDir, home, { prefix = true, max = Infinity } = {}) {
    const shown = trimPath(tildify(cwd, home), max);
    const at = shown.lastIndexOf(SEP) + 1;
    const here = at === 0 || at === shown.length ? shown : paint(DIM, shown.slice(0, at)) + shown.slice(at);
    if (!prefix || !projectDir || samePath(projectDir, cwd)) return here;
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
  // system-one's verdict row (section 9/10 of the decision-model design doc):
  // up to four answers from the chosen hook's shadow log. A known hook draws
  // its questions in the fixed order below (bash keeps section 9's
  // irr/for/net/ins), labelled by its short-name map; an unknown hook draws
  // the log line's first four answers as q1..q4. A noul or score answer reads
  // as a two-decimal probability, no leading zero; a choice answer (the prompt
  // hook's kind) reads as the chosen option's first three letters; a question
  // the log line lacks reads "--". An answer whose question is in the log
  // line's `fired` list is yellow, the gate already decided it crossed its
  // own threshold; everything else stays faint, labels included.
  const HOOK_LABELS = {
    bash: [['irreversible', 'irr'], ['foreign_process', 'for'], ['leaves_machine', 'net'], ['network_install', 'ins']],
    prompt: [['kind', 'knd'], ['wants_action', 'act']],
    stop: [['overlong', 'lng'], ['needless_table', 'tbl']],
  };

  function fmtScore(v) {
    const s = Math.max(0, Math.min(1, v)).toFixed(2);
    return s.startsWith('0.') ? s.slice(1) : s;
  }

  // One answer -> its cell text: noul is already P(yes); score is normalised
  // by its level count (falls back to the raw value if probabilities are
  // absent, e.g. a hand-built fixture); choice shows the option picked.
  function verdictText(answer) {
    if (!answer || typeof answer !== 'object') return '--';
    if (typeof answer.noul === 'number') return fmtScore(answer.noul);
    if (typeof answer.score === 'number') {
      const levels = answer.probabilities && typeof answer.probabilities === 'object'
        ? Object.keys(answer.probabilities).length
        : 0;
      const denom = levels > 1 ? levels - 1 : 1;
      return fmtScore(answer.score / denom);
    }
    if (typeof answer.choice === 'string' && answer.choice) return answer.choice.slice(0, 3);
    return '--';
  }

  function renderVerdict(v) {
    if (!v || !v.answers) return null;
    const order = HOOK_LABELS[v.hook] || Object.keys(v.answers).slice(0, 4).map((k, i) => [k, `q${i + 1}`]);
    if (!order.length) return null;
    const fired = new Set(v.fired || []);
    return order.map(([key, label]) => (
      paint(DIM, `${label} `) + paint(fired.has(key) ? YELLOW : DIM, verdictText(v.answers[key]))
    )).join('  ');
  }

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
  function usageSegments(input, usage, width, glyphs, now = Date.now()) {
    const ctxPct = input.context_window?.used_percentage ?? null;
    const rateLimits = input.rate_limits || {};
    const effort = input.effort?.level || null;
    const startedAt = fmtSessionStart(input.cost?.total_duration_ms ?? null, now);
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
      // A grid cell is never emphasised: the spelled-out yellow is for the
      // terminal row, where the choice can still be changed. Each row of the
      // grid reads the same before and after the first prompt.
      model: renderModel(modelName, quota === DIM ? '' : quota),
      effort: !effort
        ? null
        : EFFORT_BARS[effort]
          ? paint(ctxCol === DIM ? '' : ctxCol, EFFORT_BARS[effort]) + paint('', EFFORT_DIGITS[effort])
          : paint('', effort),
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
  // waiting: background agents still running while the prompt is yours, 0 when
  // none; the topic row ends with Claude Code's own ✻ for them.
  // alarm: an outside format this reads has changed; see health.json.
  // peer: the name other sessions message this one by (`oj-0e`).
  function render({ input = {}, cwd, usage = null, topic = null, git = null, home = '', columns = null, icons = true, waiting = 0, alarm = false, peer = null, verdict = null, tag = null }) {
    const glyphs = icons ? NERD_GLYPHS : TEXT_GLYPHS;
    const sessionId = input.session_id || '';
    const projectDir = input.workspace?.project_dir || null;

    // Claude Code keeps EDGE columns clear on both sides and cuts anything wider
    // with an ellipsis. Every row is laid out to the width of the widest, so all
    // three have to fit: a long path would otherwise have Claude Code cut the
    // ends off all of them.
    let top;
    for (const width of BAR_WIDTHS) {
      top = usageRow(input, usage, width, glyphs);
      if (!columns || rowWidth(top) + 2 * EDGE <= columns) break;
    }

    // Your turn and an agent still out are both true: the session will pick up
    // again by itself when the agent reports back.
    const mark = waiting ? paint(ORANGE, `✻${waiting}`) : '';

    // Rows 2 and 3 at a given generosity: the launch directory the session came
    // from, how much of the path and topic to keep, and whether the id fits.
    function lower({ prefix, path, topic: topicMax, id, name = Infinity }) {
      const middle = [];
      const bottom = [];
      // The dot and tag you gave the session lead, each in its own colour, so
      // a tab is found by them at a glance; then the session's name.
      const tagMark = [
        tag?.dot ? paint(tagColour(tag.dot), '●') : '',
        tag?.name ? paint(tagColour(tag.hex), cut(tag.name, name)) : '',
      ].filter(Boolean).join(' ');
      if (tagMark) middle.push(tagMark);
      if (peer) middle.push(paint(DIM, cut(peer, name)));
      if (topic?.text) {
        middle.push(paint(topic.isNew ? YELLOW : '', cut(topic.text, topicMax)) + (mark ? ' ' + mark : ''));
      } else if (mark) middle.push(mark);
      if (sessionId && id) bottom.push(paint(DIM, sessionId));
      if (cwd) bottom.push(renderLocation(cwd, projectDir, home, { prefix, max: path }));
      if (git?.branch) bottom.push(renderGit(git));
      if (alarm) bottom.push(paint(RED, '!'));
      return [middle, bottom];
    }

    // What to give up, in order: the launch directory, then the path from its
    // left, then the topic's tail, and the id last — row 2 names the session
    // anyway. The first that fits wins; the narrowest stands when none does.
    const LADDER = [
      { prefix: true, path: Infinity, topic: Infinity, id: true },
      { prefix: false, path: Infinity, topic: Infinity, id: true },
      { prefix: false, path: 34, topic: Infinity, id: true },
      { prefix: false, path: 24, topic: 34, id: true },
      { prefix: false, path: 18, topic: 24, id: false },
      { prefix: false, path: 12, topic: 16, id: false },
      { prefix: false, path: 10, topic: 10, id: false, name: 12 },
    ];
    const verdictRow = renderVerdict(verdict);
    let rows = [];
    for (const step of LADDER) {
      rows = [top, ...lower(step)];
      if (verdictRow) rows.push([verdictRow]);
      // A row with nothing in it (no peer, no topic, no mark) has to be
      // skipped here the same way layout() skips it when drawing, or
      // minGaps computes a negative array length for it and throws.
      const nonEmpty = rows.filter((parts) => parts.length);
      if (!columns || Math.max(...nonEmpty.map(rowWidth)) + 2 * EDGE <= columns) break;
    }

    return layout(rows).join('\n');
  }

  // The same state as a row of values, for a view that tabulates sessions
  // instead of drawing their bars. Percentages are 0-100 or null; times are
  // epoch milliseconds so the caller can age them itself.
  // `now` is when the input was read, for a view drawn from a saved redraw.
  function summarize({ input = {}, cwd, usage = null, topic = null, git = null, home = '', now = Date.now() }) {
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
      // The name in full, as a grid has room for the version the strip leaves out.
      model_full: fullModelName(input.model?.display_name || input.model?.id) || null,
      model_id: input.model?.id || null,
      effort: input.effort?.level || null,
      started_at: input.cost?.total_duration_ms != null ? now - input.cost.total_duration_ms : null,
      context: input.context_window?.used_percentage ?? null,
      five_hour: limit(input.rate_limits?.five_hour),
      seven_day: limit(input.rate_limits?.seven_day),
      fable: fable ? { percent: fable.percent, resets_at: parseEpoch(fable.resets_at) } : null,
      fable_error: isFable(input) ? usage?.error ?? null : null,
      cache: cache?.caching_observed
        ? {
            warm: !!cache.warm,
            expires_at: expiresMs,
            ttl: cache.ttl ?? null,
            rebuild: cache.recache_tokens_if_cold ?? null,
            // How the cache has served the session so far, and why it last went
            // cold: `ttl_expired_1h` and the like, as Claude Code names them.
            hit_ratio: cache.hit_ratio ?? null,
            requests: cache.requests ?? null,
            misses: cache.misses ?? null,
            last_miss_at: parseEpoch(cache.last_miss_at ?? null),
            last_miss_causes: cache.last_miss_cause?.causes ?? null,
          }
        : null,
      // Claude Code's own counts; they include files written from the shell,
      // not only through its edit tools.
      lines: input.cost?.total_lines_added != null
        ? { added: input.cost.total_lines_added, removed: input.cost.total_lines_removed ?? 0 }
        : null,
      session_name: input.session_name || null,
      version: input.version || null,
      fast_mode: input.fast_mode === true,
      topic: topic?.text || null,
      topic_is_new: !!topic?.isNew,
      cwd: cwd ? tildify(cwd, home) : null,
      project_dir: input.workspace?.project_dir ? tildify(input.workspace.project_dir, home) : null,
      git: git || null,
    };
  }

  // The same segments a row is built from, for a view that lays them out in
  // cells: each is the drawn segment, escapes and all, at `width` bar cells.
  function segments({ input = {}, usage = null, width = 5, icons = true, now = Date.now() }) {
    return usageSegments(input, usage, width, icons ? NERD_GLYPHS : TEXT_GLYPHS, now);
  }

  return { render, summarize, segments, cleanTopic, isFable, TOPIC_MAX_CHARS, SEVEN_DAY_SHOW_PCT };
});
