# cc-statusline

A minimalist [Claude Code](https://claude.com/claude-code) status line. Single Node.js file, no dependencies.

```
◆  Opus 5 ▸ xhigh ▸ 09/16 16:22 ▸ ▱▱▱▱▱ 8% ▸ 0.8h ▰▰▰▰▱ 87% ▸ cch 42m  ◆
◆  3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43  ▸  ~/dev/my-app  ▸  ⇡1 *main  ◆
```

## What it shows

The first row covers the model and usage; the second covers the session and where it is running. The narrower row is spread out with equal gaps around every segment, so both rows start and end in the same columns. The space inside each diamond is at least two columns, matching Claude Code's own indent.

| Segment | Meaning |
|---|---|
| `Opus 5` | Active model |
| `xhigh` | Reasoning effort, when the model supports it |
| `09/16 16:22` | Session start time |
| `▱▱▱▱▱ 8%` | Context window usage |
| `0.8h ▰▰▰▰▱ 87%` | 5-hour rate limit usage, labelled with hours until it resets |
| `7d ▰▰▰▰▰ 91% ⟳2d` | 7-day rate limit with time until reset (shown only at ≥90%) |
| `5.2d ▰▰▰▰▱ 85%` | Fable weekly quota, labelled with days until it resets (hours in the last day), only while the session runs a Fable model; `fbl` when the reset time is unknown; `!` in red after a failed refresh (see [Fable quota](#fable-quota)) |
| `cch 42m` | Minutes until the prompt cache expires, coloured by how much of its TTL (5m or 1h) has elapsed; `cch cold · 38k to rebuild` once it has, with the tokens the next prompt reprocesses |
| `3f2a9c1e-…` | Session ID, usable with `claude --resume` |
| `~/dev/my-app` | Current directory with its name emphasised; prefixed with the launch directory (`my-app → …`) when the session has moved away from it |
| `⇡1 *main` | Git branch, ahead (`⇡`) / behind (`⇣`), in-progress action (rebase/merge/…), conflicts (`~`), and `*` when there are staged, unstaged or untracked changes |

Bars and the cache countdown dim under 80%, turn yellow at ≥80%, red at ≥92%. Model, effort and the directory name are drawn at normal brightness and everything else is faint, with the arrows and diamonds a fixed grey one step darker (`rgb(66,69,80)`, chosen for a dark theme); model and effort are bold yellow until the first prompt of a session.

## Fable quota

Claude Code does not pass per-model limits to the status line, so the Fable weekly figure comes from the account usage endpoint (`/api/oauth/usage`, the same one `/usage` reads). The script reads Claude Code's OAuth token from the macOS Keychain, never renews it, and makes the request in a detached background process so a redraw never waits on it. Sessions on other models neither show the bar nor make the request.

One cache is shared by every session in `~/.cache/cc-statusline/` (override with `CC_STATUSLINE_CACHE_DIR`):

| File | Purpose |
|---|---|
| `usage.json` | Last reading and the error of the last refresh, if any |
| `refresh.lock` | Held while a refresh runs, so sessions never fetch in parallel |
| `error.log` | One timestamped line per failed refresh: `keychain`, `network`, `http <status>`, or `parse` |

A refresh starts when the cache is older than five minutes, or after one minute when the 7-day percentage in the status line input has moved since the last fetch. A failed refresh keeps the last good value and adds a red `!`; the next successful one clears it. The endpoint is undocumented: if its shape changes, the bar shows `fbl !` and `error.log` says `parse`.

`scripts/probe-usage.zsh` calls the endpoint once and prints every limit window, for checking what the account currently reports.

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

`refreshInterval` keeps the rate-limit and cache countdowns current while a session is idle; without it they only update when Claude Code sends a new event. Edits to the script take effect on the next refresh.

## Requirements

- Node.js 18+ (uses only `child_process`, `fs`, `os`, `path` and the built-in `fetch` — no npm install)
- macOS Keychain with a Claude Code login (optional; only for the Fable quota)
- `git` on `PATH` (optional; git segment is skipped when unavailable)

## Preview

`scripts/preview.zsh` pipes sample input through the script and prints every display state. Add `--color` to keep the ANSI colours.
