#!/bin/zsh
# DESC: Register hooks/event.zsh in Claude Code's settings, so Agent Bar Hopping hears session events
set -euo pipefail

if [[ ${1:-} == (-h|--help) ]]; then
  print "usage: ${0:t} [--remove]"
  print "Links this checkout's hooks/event.zsh into \${CLAUDE_CONFIG_DIR:-~/.claude}/hooks/ and adds it"
  print "as an async hook on the events Agent Bar Hopping turns into sounds and states, in settings.json."
  print "Running it again changes nothing; --remove takes the entries out again."
  print "The previous settings are kept next to the file as settings.json.bak."
  exit 0
fi

repo=${0:A:h:h}
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
settings=$config/settings.json
link=$config/hooks/cc-statusline-event.zsh
[[ -f $settings ]] || { print -u2 "no settings file at $settings"; exit 1; }
cp -- "$settings" "$settings.bak"

# Settings name the hook by a link in the config dir, not by this checkout's
# path, so a settings file synced between machines works wherever the repo is.
if [[ ${1:-} == --remove ]]; then
  [[ -L $link ]] && rm -f -- "$link"
else
  mkdir -p -- "${link:h}"
  ln -sfn -- "$repo/hooks/event.zsh" "$link"
fi
hook='${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/cc-statusline-event.zsh'

python3 - "$settings" "$hook" "${1:-}" <<'EOF'
import json, sys
path, hook, mode = sys.argv[1], sys.argv[2], sys.argv[3]
settings = json.load(open(path))
hooks = settings.setdefault('hooks', {})
# Events the app acts on; a matcher narrows an event to the tools it cares about.
wanted = [
    ('UserPromptSubmit', ''), ('Stop', ''), ('StopFailure', ''),
    ('PostToolUseFailure', 'Bash'), ('PermissionRequest', ''),
    ('PreToolUse', 'AskUserQuestion|ExitPlanMode'), ('Notification', ''), ('PreCompact', ''),
]
ours = lambda entry: any(h.get('command', '').endswith('cc-statusline-event.zsh') for h in entry.get('hooks', []))
changed = 0
for event, matcher in wanted:
    entries = hooks.setdefault(event, [])
    if mode == '--remove':
        kept = [e for e in entries if not ours(e)]
        changed += len(entries) - len(kept)
        hooks[event] = kept
        if not kept:
            del hooks[event]
        continue
    if any(ours(e) for e in entries):
        continue
    entry = {'hooks': [{'type': 'command', 'command': hook, 'async': True, 'timeout': 5}]}
    if matcher:
        entry['matcher'] = matcher
    entries.append(entry)
    changed += 1
open(path, 'w').write(json.dumps(settings, indent=2) + '\n')
print(f"{'removed' if mode == '--remove' else 'added'} {changed} hook entries in {path}")
EOF
