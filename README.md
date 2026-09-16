# cc-statusline

A minimalist [Claude Code](https://claude.com/claude-code) status line. Single Node.js file, no dependencies.

```
◆ Opus 5 ▸ xhigh ▸ 09/16 16:22 ▸ ▱▱▱▱▱ 8% ▸ 0.8h ▰▰▰▰▱ 87% ▸ cache 42m ◆
◆ 3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43 ▸ ~/dev/my-app ▸ ⇡1 *main ◆
```

## What it shows

The first row covers the model and usage; the second covers the session and where it is running.

| Segment | Meaning |
|---|---|
| `Opus 5` | Active model |
| `xhigh` | Reasoning effort, when the model supports it |
| `09/16 16:22` | Session start time |
| `▱▱▱▱▱ 8%` | Context window usage |
| `0.8h ▰▰▰▰▱ 87%` | 5-hour rate limit usage, labelled with hours until it resets |
| `7d ▰▰▰▰▰ 91% ⟳2d` | 7-day rate limit with time until reset (shown only at ≥90%) |
| `cache 42m` | Minutes until the prompt cache expires, coloured by how much of its TTL (5m or 1h) has elapsed; `cache cold · 38k to rebuild` once it has, with the tokens the next prompt reprocesses |
| `3f2a9c1e-…` | Session ID, usable with `claude --resume` |
| `~/dev/my-app` | Current directory with its name emphasised; prefixed with the launch directory (`my-app → …`) when the session has moved away from it |
| `⇡1 *main` | Git branch, ahead (`⇡`) / behind (`⇣`), in-progress action (rebase/merge/…), conflicts (`~`), and `*` when there are staged, unstaged or untracked changes |

Bars and the cache countdown dim under 80%, turn yellow at ≥80%, red at ≥92%. Model, effort and the directory name are drawn at normal brightness and everything else is faint; model and effort are bold yellow until the first prompt of a session.

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

- Node.js (uses only `child_process`, `fs`, `os`, `path` — no npm install)
- `git` on `PATH` (optional; git segment is skipped when unavailable)

## Preview

`scripts/preview.zsh` pipes sample input through the script and prints every display state. Add `--color` to keep the ANSI colours.
