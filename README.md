# cc-statusline

A minimalist [Claude Code](https://claude.com/claude-code) status line. Single Node.js file, no dependencies.

```
◆  ⣀⣤⣶⣿ ▃² ▸ 09/16 16:22 ▸ ╾──── 8% ▸ 0.8h ━━━━╾ 87% ▸ 󰆼 42m  ◆
◆                          auth token refresh                          ◆
◆  3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43  ▸  ~/dev/my-app  ▸  ⇡1 *main  ◆
```

## What it shows

The first row covers the model and usage; the second, when there is one, names what the session is about; the third covers the session and where it is running. Narrower rows are spread out with equal gaps around every segment, so all rows start and end in the same columns. The space inside each diamond is at least two columns, matching Claude Code's own indent.

| Segment | Meaning |
|---|---|
| `⣀⣤⣶⣿ ▃²` | Model tier as a slope of four braille steps, weakest to strongest: `⣀ ⣤ ⣶ ⣿` for Haiku, Sonnet, Opus and Fable, with the session's own lit and the other three in the frame grey; in a Fable session the lit step turns yellow or red with the Fable weekly quota, on the bars' thresholds (version and context size left out, since `/model` offers one version per tier; an unknown model shows its full name), then reasoning effort as a block height with its level in superscript, `▁¹ ▃² ▅³ ▇⁴ █⁵` for low, medium, high, xhigh and max, when the model supports it |
| `09/16 16:22` | Session start time |
| `╾──── 8%` | Context window usage |
| `0.8h ━━━━╾ 87%` | 5-hour rate limit usage, labelled with hours until it resets |
| `2.6d ━━━━─ 75%` | 7-day rate limit, labelled with days until it resets (hours in the last day); shown only at ≥75%, `7d` when the reset time is unknown |
| `5.2d ━━━━─ 85% 󰯺` | Fable weekly quota, labelled like the 7-day bar and tagged with the boxed Fable initial `󰯺` so the two read apart; only while the session runs a Fable model; `󰯺` when the reset time is unknown; `!` in red after a failed refresh (see [Fable quota](#fable-quota)) |
| `󰆼 42m` | Minutes until the prompt cache expires (`󰆼` is the Nerd Font database glyph), coloured by how much of its TTL (5m or 1h) has elapsed; `󰆼 cold · 38k to 󰑐` once it has, with the tokens the next prompt reprocesses to rebuild it |
| `auth token refresh` | Session topic, on its own row: the one set with `/statusline-topic`, otherwise one derived from the transcript; yellow for a minute after it changes (see [Session topic](#session-topic)) |
| `3f2a9c1e-…` | Session ID, usable with `claude --resume` |
| `~/dev/my-app` | Current directory with its name emphasised; prefixed with the launch directory (`my-app → …`) when the session has moved away from it |
| `⇡1 *main` | Git branch, ahead (`⇡`) / behind (`⇣`), in-progress action (rebase/merge/…), conflicts (`~`), and `*` when there are staged, unstaged or untracked changes |

Bars and the cache countdown dim under 80%, turn yellow at ≥80%, red at ≥92%. Model, effort, the topic and the directory name are drawn at normal brightness and everything else is faint, with the arrows and diamonds a fixed grey one step darker (`rgb(66,69,80)`, chosen for a dark theme); model and effort are bold yellow until the first prompt of a session.

Bars are thin rules drawn in half-cell steps (`╾` is heavy on its left half), so five cells show ten levels. When the first row would be wider than the terminal, every bar shrinks to three cells, and if that still does not fit, only the percentages remain. The width comes from the session's terminal: Claude Code runs the status line without one, so the script walks up its parent processes to the first with a tty (one `ps` per step) and reads that tty's size with `stty`, about 15 ms in all, on every redraw so a resize applies on the next one. `CC_STATUSLINE_COLUMNS` sets the width instead; with neither, bars stay full width.

## Fable quota

Claude Code does not pass per-model limits to the status line, so the Fable weekly figure comes from the account usage endpoint (`/api/oauth/usage`, the same one `/usage` reads). The script reads Claude Code's OAuth token from the macOS Keychain, never renews it, and makes the request in a detached background process so a redraw never waits on it. Sessions on other models neither show the bar nor make the request.

One cache is shared by every session in `~/.cache/cc-statusline/` (override with `CC_STATUSLINE_CACHE_DIR`):

| File | Purpose |
|---|---|
| `usage.json` | Last reading and the error of the last refresh, if any |
| `refresh.lock` | Held while a refresh runs, so sessions never fetch in parallel |
| `error.log` | One timestamped line per failed refresh: `keychain`, `network`, `http <status>`, or `parse` |

A refresh starts when the cache is older than five minutes, or after one minute when the 7-day percentage in the status line input has moved since the last fetch. A failed refresh keeps the last good value and adds a red `!`; the next successful one clears it. The endpoint is undocumented: if its shape changes, the bar shows `󰯺 !` and `error.log` says `parse`.

`scripts/probe-usage.zsh` calls the endpoint once and prints every limit window, for checking what the account currently reports.

## Session topic

`/statusline-topic <text>` sets the topic for the current session; `/statusline-topic` with no text clears it. Whenever the topic shown changes, whether set by hand or refreshed, it is yellow for 60 seconds from the first redraw that shows it — one `refreshInterval`, so the next idle tick returns it to normal. The first draw is remembered in `topics/<session id>.seen`. The command writes `topics/<session id>.manual` in the cache directory, using the `CLAUDE_CODE_SESSION_ID` that Claude Code gives its shell.

Without a manual topic, the script names the session itself with a detached `claude -p --model haiku`, caching the reply in `topics/<session id>.json`. A redraw only compares timestamps and never waits for the call.

A call starts on a redraw when all of these hold:

| Condition | Why |
|---|---|
| The transcript changed since the last attempt | An idle session never makes a call |
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

`docs/showcase.html` draws the status line in a browser from the same code. Open it straight from disk. It has a live panel with a control for every input, a sweep that steps one value across its range, and a gallery of named states with tag filters. Each state can be loaded into the panel.

## Layout

`lib/render.js` is the pure half: it turns the status line input, the usage cache, the topic and the git state into the rendered lines, with no I/O. `cc-statusline.js` gathers that state (stdin, Keychain, cache files, git, the background refreshes) and calls it. The showcase page loads `lib/render.js` directly, so a display change shows up there without a separate step.
