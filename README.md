# cc-statusline

A minimalist [Claude Code](https://claude.com/claude-code) status line. Single Node.js file, no dependencies.

```
◆  ⣀⣤⣶⣿ ▃² ▸ 09/16 16:22 ▸ ╾────.08 ▸ 0.8ʰ ━━━━╾.87 ▸ 󰆼 42ᵐ  ◆
◆                          auth token refresh                          ◆
◆  3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43  ▸  ~/dev/my-app  ▸  ⇡1 *main  ◆
```

## What it shows

The first row covers the model and usage; the second, when there is one, names what the session is about; the third covers the session and where it is running. Narrower rows are spread out with equal gaps around every segment, so all rows start and end in the same columns. The space inside each diamond is at least two columns, matching Claude Code's own indent.

| Segment | Meaning |
|---|---|
| `⣀⣤⣶⣿ ▃²` | Model tier as a slope of four braille steps, weakest to strongest: `⣀ ⣤ ⣶ ⣿` for Haiku, Sonnet, Opus and Fable, with the session's own lit and the other three in the frame grey; in a Fable session the lit step turns yellow or red with the Fable weekly quota, on the bars' thresholds (version and context size left out, since `/model` offers one version per tier; an unknown model shows its full name), then reasoning effort as a block height with its level in superscript, `▁¹ ▃² ▅³ ▇⁴ █⁵` for low, medium, high, xhigh and max, the bar turning yellow or red with the context window, when the model supports it |
| `09/16 16:22` | Session start time |
| `╾────.08` | Context window usage |
| `0.8ʰ ━━━━╾.87` | 5-hour rate limit usage, labelled with hours until it resets |
| `2.6ᵈ ━━━━─.75 󰇧` | 7-day rate limit across all models, labelled with days until it resets (hours in the last day) and tagged with the earth `󰇧` so it reads apart from the Fable quota inside it; shown only at ≥75%, `7d` when the reset time is unknown |
| `5.2ᵈ ━━━━─.85 󰫳` | Fable weekly quota, labelled like the 7-day bar and tagged with the boxed Fable initial `󰫳` so the two read apart; only while the session runs a Fable model; `󰫳` when the reset time is unknown; `!` in red after a failed refresh (see [Fable quota](#fable-quota)) |
| `󰆼 42ᵐ` | Minutes until the prompt cache expires, after the icon, with the unit raised (`󰆼` is the Nerd Font database glyph), coloured by how much of its TTL (5m or 1h) has elapsed; once that turns yellow or red the tokens a rebuild would reprocess join it (`󰆼 4ᵐ 38k`), while there is still time to `/compact` or wrap up; `󰆼 38k 󰑐` in blue once it has expired |
| `✻` | After the topic, in Claude's orange: your turn, but a background agent is still running and the session will carry on when it reports back with how many (`✻1`, `✻2`); read from the transcript by the same incremental scan the app uses |
| `oj-0e` | Before the topic: the name other sessions message this one by, from Claude Code's file for this session's process in `~/.claude/sessions/`; set your own with `claude -n <name>` |
| `auth token refresh` | Session topic, on its own row: the one set with `/statusline-topic`, otherwise one derived from the transcript; yellow for a minute after it changes (see [Session topic](#session-topic)) |
| `3f2a9c1e-…` | Session ID, usable with `claude --resume` |
| `~/dev/my-app` | Current directory with its name emphasised; prefixed with the launch directory (`my-app → …`) when the session has moved away from it |
| `⇡1 *main` | Git branch, ahead (`⇡`) / behind (`⇣`), in-progress action (rebase/merge/…), conflicts (`~`), and `*` when there are staged, unstaged or untracked changes |

Bars and the cache countdown dim under 75%, turn yellow at ≥75% (where Claude Code starts its weekly-limit warning), red at ≥92%. Model, effort, the topic and the directory name are drawn at normal brightness and everything else is faint, with the arrows and diamonds a fixed grey one step darker (`rgb(66,69,80)`, chosen for a dark theme); until the first prompt of a session, model and effort are spelled out in full and bold yellow (`Opus 4.8 1M xhigh`), so the choice is easy to check while it can still be changed.

Bars are thin rules drawn in half-cell steps (`╾` is heavy on its left half), so five cells show ten levels. When the first row would be wider than the terminal, every bar shrinks to three cells, and if that still does not fit, only the percentages remain. Every row is laid out to the width of the widest, so the other two have to fit as well: what goes first is the launch directory before the path, then the path from its left (`…/song-processing-tools` keeps where you are), then the topic's tail, then the session id — row two names the session — and last the name itself. The width comes from the session's terminal: Claude Code runs the status line without one, so the script walks up its parent processes to the first with a tty (one `ps` per step) on a session's first redraw, and after that reuses what it found while that process is still its parent. It reads that tty's size with `stty` on every redraw, so a resize applies on the next one. `CC_STATUSLINE_COLUMNS` sets the width instead; with neither, bars stay full width.

The script starts without `NODE_USE_ENV_PROXY` (its first line runs node through `env -u`): that setting, which a request-limiting proxy may put in every session, makes node load its proxy machinery at startup and doubles the cost of a redraw, which never goes on the web. The children that do make requests, the usage refresh and the topic call, get it back whenever a proxy is set, so their requests still go through it.

Four glyphs need a [Nerd Font](https://www.nerdfonts.com/): the cache `󰆼`, the rebuild `󰑐`, the Fable tag `󰫳` and the weekly tag `󰇧`. Everything else is standard Unicode. Without a Nerd Font, set `CC_STATUSLINE_ICONS=0` to draw them as `cch`, `⟳`, `fbl` and `all` instead.

## Agent Bar Hopping

Every live session in one window: a macOS app in `src/main.swift`, built with `./bundle.sh` into `~/Applications/Agent Bar Hopping.app`.

Each redraw writes that session's render arguments to `~/.cache/cc-statusline/live/<session-id>.json`. The app watches that directory and re-reads it when it changes, so the window repaints exactly when a status line does, with a 30-second tick to age the countdowns. Every cell stacks the segment the status line draws over the same value in words, both from `cc-statusline.js live`, which renders with this same `lib/render.js` — the window cannot disagree with the terminal. The account-wide quotas sit in a bar above the table, taken from whichever session redrew last, since they are the same for every session. Above each quota's bar a faint line says where in its window it is (`hour 3 of 5`, `day 1 of 7`: one more than the whole hours or days gone). Under each quota a dimmed pace row shows how much of its window has gone (the 7-day bar moves 14.3% a day, the 5-hour bar 20% an hour) on the same scale as the reading above it, and where spending at the current rate would end by the reset (`on pace for 116%`, yellow from 85% and red from 100%). Level bars are an even pace; a reading ahead of its ghost runs out early. Both bars carry a tick every hour of the 5-hour window and every day of the weekly ones. On the pace bar the tick that ends the current hour or day is white: the share a steady pace would have used by then, to hold the reading above against. No projection is drawn in the first 2% of a window, where one prompt would read as a runaway rate.

Each redraw also records the Claude Code process that owns the terminal, and when the session last had a prompt or a reply, read from the end of its transcript. Last Seen and the dot's fading follow that time, not the redraw: Claude Code redraws every open session each `refreshInterval`, and appends bookkeeping entries to transcripts nobody has touched, so neither the redraw nor the file's mtime means anything happened. The same time decides whether a topic needs refreshing. A session is finished once its process is gone; of several sessions in one process (after `/clear` or `/resume`), only the latest to redraw is open. A spool from before pids were recorded is finished after 30 minutes without a redraw. The script checks the process with a signal-0 `kill`, and the app checks that the process still owns the same terminal, so a reused pid cannot keep a closed session alive. Finished sessions stay in the list, newest first, until there are more than 500; one that ended without ever having a prompt has its spool deleted as soon as it is found finished, since it has nothing to show or resume. Double-clicking a live row's Last Seen, Directory, Doing, State or Cache cell brings its iTerm tab to the front; on a finished row the same double-click, ⌘↩, or Resume Session in its Directory cell's right-click menu opens it again in a new tab of iTerm's hotkey window: `claude --resume` from the directory it was launched in, with the model, effort and permission mode it last ran (a session that is open again elsewhere has its tab brought forward instead). The tab starts with the command rather than having it typed, since typing into a fresh tab races the shell's startup, and falls back to a login shell when `claude` exits; right-clicking its Directory cell offers Copy Path (in full) and Copy Session Name; clicking its Last Seen cell, which shows the start of the session id, copies the whole id. The row under the mouse is lightly washed; a live row whose State changes tints once and fades, yellow when it now waits on you; the dot of a session that is working breathes; and bars ease to a new reading instead of jumping. All of it plays whatever the system's Reduce motion setting says. The table opens sorted by the caches about to go cold, soonest first, cold last and ties by Last Seen; the Cache header cycles through that order, time left rising, and falling. The first row is the tool's own cost, named `cc-statusline`: the status line redraws and the app together as a share of one core over the last five minutes, split in the CPU cell's tooltip, and the app's memory.

Five columns come from outside the status line input:

| Column | Top line | Under it | Source |
|---|---|---|---|
| State | `your turn`, `question`, `plan`, `approve?`, a running tool with its time (`Bash 3m`), `working`, or `stopped`, then the permission mode when it is not `auto` (`· plan`, `· manual`); on a finished row, how it ended (below) | `✻ 1 agent` in Claude Code's orange while background subagents are still out: your turn and a pending agent are both true at once | The session's transcript, and the event hook for `approve?` |
| Sound | A speaker glyph: faint while it follows the speaker switch at the top right, bright when forced on, a yellow muted speaker when muted; a click cycles them | — | The app's `sounds.json` |
| Tokens | Tokens the session has sent and received, subagents excluded | Lines added and removed, as Claude Code counts them (files written from the shell included) | The transcript; the lines from the status line input |
| Memory | Memory of the Claude Code process and every process under it, compressed pages included | How many processes are under it | The kernel, read by the app (`proc_pid_rusage`) |
| CPU | CPU now as a share of one core, for the same processes | The CPU time the Claude Code process has used since it started | The kernel, as above |

A finished row's State says how the session ended: `exited` when you left it (Ctrl+D or `/exit`), `closed` in white when its terminal went away under it (a closed tab, iTerm quitting, a restart), and `crashed` in yellow when its process died without a word; also `cleared`, `resumed` and `logged out`. Claude Code runs the `SessionEnd` hook with a reason for all but the last, including on a hangup or `SIGTERM`, and `hooks/event.zsh` writes it into the session's spool, where a later resume's first redraw clears it; a session gone without one crashed. That hook is the one registration the installer makes synchronous, as an async hook need not outlive a process that is exiting. Sessions that ended before the first recorded `SessionEnd`, or for a reason the app does not know, show a dim `—`.

A dialog waiting on you is not in the transcript until it is answered, so State first asks Claude Code itself: its per-session file in `~/.claude/sessions/` says `waiting` with what for, shown in yellow (`question` for `input needed`, `sandbox?`, `goal?`, or the reason as Claude Code gives it). Without that, a running tool can also be a permission prompt, and the event hook's `approve?` is the fallback. The transcripts are read incrementally: the first snapshot of a session reads its whole file once, and every later one only what was appended, with the running totals in `~/.cache/cc-statusline/scan/`. The Directory cell carries the name other sessions message this one by (`finance-be`; its terminal is in the tooltip, and a finished session shows its terminal instead), read from Claude Code's per-session files in `~/.claude/sessions/`; the Doing cell carries Claude Code's own name for the conversation under the topic; the Cache cell, its hit rate and misses; the Launched at cell, the session's Claude Code version when it is older than the latest release, with only the parts that differ in yellow (`2.1.270` against `2.1.271` marks `270`; against `2.2.0`, `1.270`). The latest release shows in the first row; the app reads it from npm's registry (`@anthropic-ai/claude-code/latest`) at most every six hours, caches it in `claude-latest.json`, and waits an hour after a failed request. Until it has one, the newest version any session runs stands in.

The header states what the tool itself costs as a share of one core over the last five minutes: the status line redraws in every session (each records node's own CPU; git and stty are not in it) and the app with the snapshots it runs.

`cc-statusline.js live [--columns N]` prints that whole snapshot as JSON and exits — the app's only subprocess. No `ps`, no git calls, no network.

## Session events and sounds

The status line only runs when Claude Code redraws, so it never hears about events. `hooks/event.zsh` does: registered as an async hook, it writes each event's JSON to `~/.cache/cc-statusline/events/` (about 15 ms, and Claude Code does not wait for it), and the app reads and deletes each file. Register it with `scripts/install-event-hook.zsh` (`--remove` takes it out again); it edits `settings.json` in your Claude config directory and keeps the previous version as `settings.json.bak`.

From those events the app plays a sound per kind, from an [openpeon](https://github.com/PeonPing/peon-ping) sound pack in `~/Library/Application Support/Agent Bar Hopping/packs/<name>/`:

| Event | Sound category |
|---|---|
| `Stop`, unless the reply took under `silent_window_seconds` | `task.complete` |
| `StopFailure`, or `PostToolUseFailure` from Bash | `task.error` |
| `PermissionRequest`, `PreToolUse` for AskUserQuestion or ExitPlanMode, an MCP question | `input.required` |
| `PreCompact` | `resource.limit` |
| `annoyed_threshold` prompts to one session within `annoyed_window_seconds` | `user.spam` |

The switch (the speaker glyph), volume, pack and one toggle per category (`● done`, `○ spam`) sit at the top right of the window, and the Sound column overrides the switch for one session; all of it is kept in `sounds.json` beside the packs, which the app writes with defaults on first launch. Picking a pack or a volume plays a sample. Packs load as peon-ping loads them: a file named without a directory is in `sounds/`, nothing may point outside the pack, `manifest.json` stands in for `openpeon.json`, and a malformed entry is skipped rather than the whole pack. `.ogg` files play where Core Audio has a Vorbis decoder (macOS 15 does) and are skipped where it does not. Completions in several sessions within five seconds chime once, and each category avoids repeating its last sound. Clicking the pack's name opens the [openpeon registry](https://peonping.github.io/registry/index.json) (fetched at most daily, cached as `registry.json`) with a search over name, language and description, the installed packs listed first and the one in use selected. Under the list sit the same switch, volume and event toggles, whose ▶ plays the selected pack: from disk when installed, otherwise fetched from its repo on the first play of each sound and cached under `pack-previews/` in the cache directory. Use, Return or a double-click switches to an installed pack; on one that is not installed it becomes Install, which downloads the pack from its GitHub repo into `packs/` and switches to it. The download checks the manifest against the registry's sha256 and each sound against the manifest's, which peon-ping itself does not; it stops at the first refused request, skips `.ogg` where it cannot play, and builds the pack in a hidden directory so a failed install leaves nothing behind. A `PermissionRequest` also turns the session's State to `approve?` in yellow, until a process starts under the session (an approved command) or the transcript moves on. Events more than a minute old when read, from while the app was closed, are dropped.

## When a format changes

Everything the tool reads comes from formats Anthropic can change without notice, and a changed format rarely throws: the JSON still parses, a field is simply gone, and a segment quietly disappears. So each reader states what it expects, and a broken expectation is recorded in `health.json` in the cache directory, with the Claude Code version it first appeared under, when, and how often:

| Source | Expectation |
|---|---|
| Status line input | `context_window.context_window_size` and `cost.total_duration_ms` are numbers |
| Transcripts | lines are JSON, entries are typed `user` / `assistant`, assistant messages carry `message.usage`, `stop_reason` is a known value (judged only on a new chunk big enough to tell) |
| Usage endpoint | a 2xx answer with `limits[]` and a numeric Fable percent; an outage or a missing token does not count |
| Hook events | the event is one the hook is registered for, with a `session_id` |
| npm registry | the answer has `version`; an outage does not count |

Any recorded problem puts a red `!` at the end of every session's last status line row and turns the app's `cc-statusline` row red with the problem in words; its tooltip lists them all. `error.log` gets a `format:` line when a problem appears and a `format ok again:` line when it clears, which it does by itself on the next reading that passes.

## Fable quota

Claude Code does not pass per-model limits to the status line, so the Fable weekly figure comes from the account usage endpoint (`/api/oauth/usage`, the same one `/usage` reads). The script reads Claude Code's OAuth token from the macOS Keychain, never renews it, and makes the request in a detached background process so a redraw never waits on it. Sessions on other models neither show the bar nor make the request. Agent Bar Hopping shows the Fable quota whatever the sessions run: it fetches once at launch (`cc-statusline.js refresh-usage`), unless the cache is under five minutes old, and after that relies on Fable sessions, which refresh the same cache while they run; the quota only moves then. A reading past its reset shows as 0%. It is shown whether or not the server marks it `is_active`, as claude.ai's usage page shows it.

One cache is shared by every session in `~/.cache/cc-statusline/` (override with `CC_STATUSLINE_CACHE_DIR`):

| File | Purpose |
|---|---|
| `usage.json` | Last reading and the error of the last refresh, if any |
| `refresh.lock` | Held while a refresh runs, so sessions never fetch in parallel |
| `error.log` | One timestamped line per failed refresh: `keychain`, `network`, `http <status>`, or `parse` |

A refresh starts when the cache is older than five minutes, or after one minute when the 7-day percentage in the status line input has moved since the last fetch. A failed refresh keeps the last good value and adds a red `!`; the next successful one clears it. The endpoint is undocumented: if its shape changes, the bar shows `󰫳 !` and `error.log` says `parse`.

`scripts/probe-usage.zsh` calls the endpoint once and prints every limit window, for checking what the account currently reports.

## Session topic

`/statusline-topic <text>` sets the topic for the current session; `/statusline-topic` with no text clears it. Whenever the topic shown changes, whether set by hand or refreshed, it is yellow for 60 seconds from the first redraw that shows it — one `refreshInterval`, so the next idle tick returns it to normal. The first draw is remembered in `topics/<session id>.seen`. The command writes `topics/<session id>.manual` in the cache directory, using the `CLAUDE_CODE_SESSION_ID` that Claude Code gives its shell.

Without a manual topic, the script names the session itself with a detached `claude -p --model haiku`, caching the reply in `topics/<session id>.json`. A redraw only compares timestamps and never waits for the call.

A call starts on a redraw when all of these hold:

| Condition | Why |
|---|---|
| A prompt or reply is newer than the last attempt | An idle session never makes a call, nor asks iTerm2 about focus. The transcript file's mtime is not the test: Claude Code writes bookkeeping entries to idle sessions |
| Claude has finished at least one reply | A topic named from the opening prompt alone is usually wrong; until then the check is repeated without a call |
| At least 2 minutes since the last topic in iTerm2, 10 minutes elsewhere | The first topic skips this |
| In iTerm2: iTerm2 is the frontmost app and this session's pane is the focused one | Only the visible status line needs a fresh topic, so background tabs cost nothing |

Focus is read on redraw, and a tab switch does not cause one, so a refresh can start up to one `refreshInterval` after you focus a tab; the new topic shows on the redraw after the call returns (a few seconds). Outside iTerm2 there is no focus check, and the 10-minute floor is the only limit.

The call sends the opening prompt and the most recent exchanges, with tool calls and injected system text removed (at most about 8,000 characters). It replaces Claude Code's default system prompt with a one-line naming instruction and turns thinking off, which keeps it to roughly 1–3k input and 10 output tokens; with the defaults it is about 9k input and 700 output. The child skips all settings sources, so it runs none of your hooks or this status line, and it keeps no session of its own. Failures keep the previous topic, go to `error.log` as `topic: …`, and wait out the same floor. Topic files untouched for 30 days are removed.

`scripts/simulate-topic.zsh <transcript.jsonl>` runs the refresh rules end to end against a copy of a transcript, faking iTerm2 focus, and reports each check. It makes two real Haiku calls.

## Install

Clone somewhere and point your Claude Code settings at the script:

```bash
git clone https://github.com/mrtysn/cc-statusline.git ~/dev/cc-statusline
chmod +x ~/dev/cc-statusline/cc-statusline.js
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/cc-statusline.js",
    "refreshInterval": 60
  }
}
```

For the topic command, link it into your commands:

```bash
ln -s ~/dev/cc-statusline/commands/statusline-topic.md ~/.claude/commands/statusline-topic.md
```

`refreshInterval` keeps the rate-limit and cache countdowns current while a session is idle; without it they only update when Claude Code sends a new event. Edits to the script take effect on the next refresh.

## Requirements

- Node.js 18+ (uses only `child_process`, `fs`, `os`, `path` and the built-in `fetch` — no npm install)
- macOS Keychain with a Claude Code login (optional; only for the Fable quota)
- `git` on `PATH` (optional; git segment is skipped when unavailable)
- `claude` on `PATH` (optional; only for the auto topic)
- iTerm2 (optional; without it the auto topic refreshes on a timer instead of on focus)

## Preview

`scripts/preview.zsh` pipes sample input through the script and prints every display state. Add `--color` to keep the ANSI colours.

`scripts/capture-statusline.py` runs a real Claude Code session in a pty at a given `--columns` width and shows how Claude Code itself draws the status line — wrapping, truncation, repaint — rather than what the script emits.

`docs/showcase.html` draws the status line in a browser from the same code. Open it straight from disk. It has a live panel with a control for every input, a sweep that steps one value across its range, and a gallery of named states with tag filters. Each state can be loaded into the panel.

## Layout

`lib/render.js` is the pure half: it turns the status line input, the usage cache, the topic and the git state into the rendered lines, with no I/O. `cc-statusline.js` gathers that state (stdin, Keychain, cache files, git, the background refreshes) and calls it. The showcase page loads `lib/render.js` directly, so a display change shows up there without a separate step.
