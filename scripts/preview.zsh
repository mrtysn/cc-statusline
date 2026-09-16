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
now=$(date +%s)
id=3f2a9c1e-7b4d-4e8a-9f60-2d1c5b8e7a43
base="\"session_id\":\"$id\",\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"effort\":{\"level\":\"xhigh\"},\"cost\":{\"total_duration_ms\":2880000}"
here="\"cwd\":\"$repo\",\"workspace\":{\"current_dir\":\"$repo\",\"project_dir\":\"$repo\"}"
moved="\"cwd\":\"$repo\",\"workspace\":{\"current_dir\":\"$repo\",\"project_dir\":\"$HOME\"}"
five="\"five_hour\":{\"used_percentage\":87,\"resets_at\":$((now + 2880))}"
seven="\"seven_day\":{\"used_percentage\":91,\"resets_at\":$((now + 172800))}"
warm_for() { print -r -- "\"prompt_cache\":{\"warm\":true,\"caching_observed\":true,\"ttl\":\"1h\",\"expires_at\":$((now + $1)),\"recache_tokens_if_cold\":38000}" }
warm=$(warm_for 2500)
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
render "before first prompt" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":null},\"rate_limits\":{$five}"
render "cache warm" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
render "cache running low (yellow)" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$(warm_for 600)"
render "cache nearly expired (red)" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$(warm_for 200)"
render "cache cold" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$cold"
render "moved from launch directory" "$mode" "$base,$moved,\"context_window\":{\"used_percentage\":8},\"rate_limits\":{$five},$warm"
render "7-day limit near exhaustion" "$mode" "$base,$here,\"context_window\":{\"used_percentage\":85},\"rate_limits\":{$five,$seven},$warm"
