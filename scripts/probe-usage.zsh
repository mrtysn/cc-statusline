#!/bin/zsh
# DESC: Dump the account usage endpoint's rate-limit windows, including per-model limits[]
set -euo pipefail

if [[ ${1:-} == (-h|--help) ]]; then
  print "usage: ${0:t}"
  print "Calls /api/oauth/usage once with the Claude Code OAuth token from the Keychain"
  print "and prints the HTTP status, timing, top-level keys, the 5h/7d windows and every"
  print "limits[] entry. The token is passed to curl on stdin and never printed."
  exit 0
fi

token=$(security find-generic-password -s "Claude Code-credentials" -w |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')

# Headers are read from stdin so the token never appears in the process list.
body=$(print -r -- "Authorization: Bearer $token" | curl -sS -m 10 -w '\n%{http_code} %{time_total}s' \
  -H @- \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" \
  "https://api.anthropic.com/api/oauth/usage")

print -r -- "${body##*$'\n'}"
print -r -- "${body%$'\n'*}" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print(raw[:500])
    sys.exit()
print("top-level keys:", sorted(d.keys()))
for k in ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"):
    if d.get(k) is not None:
        print(f"  {k}: {d[k]}")
for l in d.get("limits") or []:
    print("  limits[]:", json.dumps(l))
'
