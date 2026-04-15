# cc-statusline

A minimalist [Claude Code](https://claude.com/claude-code) status line. Single Node.js file, no dependencies.

```
◆ <session-id> ▸ Wed 4/15 13:44 ▸ ctx ▰▱▱▱▱▱▱▱▱▱ 7% ▸ 51m ▸ 5h ▰▱▱▱▱▱▱▱▱▱ 6% ▸  main !1 ◆
```

## What it shows

| Segment | Meaning |
|---|---|
| `session-id` | Current Claude Code session ID |
| `Wed 4/15 13:44` | Session start time (weekday, date, clock) |
| `ctx ▰▱▱▱▱▱▱▱▱▱ 7%` | Context window usage |
| `51m` | Session elapsed time |
| `5h ▰▱▱▱▱▱▱▱▱▱ 6%` | 5-hour rate limit usage |
| `7d ▰▱▱▱▱▱▱▱▱▱ 6%` | 7-day rate limit (shown only at ≥90%) |
| ` main !1 ⇡2 ?3` | Git branch + ahead/behind, staged (`+`), unstaged (`!`), untracked (`?`), conflicts (`~`), in-progress action (rebase/merge/…) |

Bars dim under 70%, turn yellow at ≥70%, red at ≥85%. When any bar hits ≥90%, a `⟳` ETA to reset is appended.

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
    "command": "/absolute/path/to/cc-statusline.js"
  }
}
```

Reloads automatically on save.

## Requirements

- Node.js (uses only `child_process`, `fs`, `path` — no npm install)
- `git` on `PATH` (optional; git segment is skipped when unavailable)

## License

MIT
