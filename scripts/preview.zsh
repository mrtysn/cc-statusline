#!/bin/zsh
# DESC: Render cc-statusline for each display state from sample input
set -euo pipefail

if [[ ${1:-} == (-h|--help) ]]; then
  print "usage: ${0:t} [--color]"
  print "Pipes sample Claude Code JSON through cc-statusline.js and prints each state."
  print "Colours are stripped unless --color is given."
  exit 0
fi

repo=${0:A:h:h}
script=$repo/cc-statusline.js
zmodload zsh/datetime
now=$EPOCHSECONDS
id=3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43
base="\"session_id\":\"$id\",\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"effort\":{\"level\":\"xhigh\"},\"cost\":{\"total_duration_ms\":2880000}"
here="\"cwd\":\"$repo\",\"workspace\":{\"current_dir\":\"$repo\",\"project_dir\":\"$repo\"}"
moved="\"cwd\":\"$repo\",\"workspace\":{\"current_dir\":\"$repo\",\"project_dir\":\"$HOME\"}"
five="\"five_hour\":{\"used_percentage\":87,\"resets_at\":$((now + 2880))}"
seven="\"seven_day\":{\"used_percentage\":91,\"resets_at\":$((now + 172800))}"
warm_for() { print -r -- "\"prompt_cache\":{\"warm\":true,\"caching_observed\":true,\"ttl\":\"1h\",\"expires_at\":$((now + $1)),\"recache_tokens_if_cold\":38000}" }
warm=$(warm_for 2500)
# A throwaway cache dir, always fresh, so previews never reach the usage endpoint.
export CC_STATUSLINE_CACHE_DIR=$(mktemp -d)
trap 'rm -rf -- "$CC_STATUSLINE_CACHE_DIR"' EXIT
usage() { print -r -- "{\"fetched_at\":$((now * 1000)),\"seven_day_seen\":null,\"fable\":$1,\"error\":$2}" > "$CC_STATUSLINE_CACHE_DIR/usage.json" }
fable="\"model\":{\"id\":\"claude-fable-5-1\",\"display_name\":\"Fable 5.1\"},\"effort\":{\"level\":\"xhigh\"},\"session_id\":\"$id\",\"cost\":{\"total_duration_ms\":2880000}"
fable_at() { print -r -- "{\"percent\":$1,\"resets_at\":\"$(TZ=UTC strftime %Y-%m-%dT%H:%M:%SZ $((now + 172800)))\",\"is_active\":true}" }
cold="\"prompt_cache\":{\"warm\":false,\"caching_observed\":true,\"expires_at\":null,\"recache_tokens_if_cold\":38000}"

render() {
  print "== $1"
  if [[ ${2:-} == --color ]]; then
    print -r -- "{$3}" | "$script"
  else
    print -r -- "{$3}" | "$script" | sed $'s/\x1b\\[[0-9;]*m//g'
  fi
  print "\n"
}

mode=${1:-}
usage null null
render "before first prompt" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":null},\"rate_limits\":{$five}"
render "cache warm" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
render "cache running low (yellow)" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$(warm_for 600)"
render "cache nearly expired (red)" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$(warm_for 200)"
render "cache cold" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$cold"
render "moved from launch directory" "$mode" "$base,$moved,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
render "7-day limit near exhaustion" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":85},\"rate_limits\":{$five,$seven},$warm"
usage "$(fable_at 85)" null
render "Fable weekly quota (yellow)" "$mode" "$fable,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
usage "$(fable_at 95)" null
render "Fable weekly quota near exhaustion" "$mode" "$fable,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
usage "$(fable_at 85)" '"http 429"'
render "Fable refresh failed (stale value)" "$mode" "$fable,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
usage null '"keychain: no claudeAiOauth.accessToken in keychain entry"'
render "Fable refresh failed (no reading yet)" "$mode" "$fable,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
usage "$(fable_at 85)" null
render "Fable quota hidden on another model" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
mkdir -p "$CC_STATUSLINE_CACHE_DIR/topics"
print -r -- "{\"topic\":\"auth token refresh\",\"generated_at\":$((now * 1000)),\"error\":null}" > "$CC_STATUSLINE_CACHE_DIR/topics/$id.json"
print -r -- "{\"topic\":\"auth token refresh\",\"shown_at\":$(( (now - 120) * 1000 ))}" > "$CC_STATUSLINE_CACHE_DIR/topics/$id.seen"
render "auto topic" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
print -r -- "fixing the login redirect loop" > "$CC_STATUSLINE_CACHE_DIR/topics/$id.manual"
render "topic just changed (yellow)" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
