---
description: Set this session's topic in the cc-statusline status line, or clear it to return to the auto topic
argument-hint: [topic]
allowed-tools: Bash
---

Set the manual status line topic for this session. The requested topic is between the markers:

<topic>$ARGUMENTS</topic>

Run exactly one Bash command and nothing else — no file reads, no other tools.

- If the topic is non-empty, write it, single-quoted (escape any `'` as `'\''`):

  ```
  d="${CC_STATUSLINE_CACHE_DIR:-$HOME/.cache/cc-statusline}/topics" && mkdir -p "$d" && printf '%s\n' '<topic>' > "$d/$CLAUDE_CODE_SESSION_ID.manual"
  ```

- If the topic is empty, empty the file so the status line falls back to the auto topic:

  ```
  d="${CC_STATUSLINE_CACHE_DIR:-$HOME/.cache/cc-statusline}/topics" && mkdir -p "$d" && : > "$d/$CLAUDE_CODE_SESSION_ID.manual"
  ```

Then reply with one short line: the topic that was set, or that the auto topic is back. It appears on the next status line redraw.
