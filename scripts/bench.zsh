#!/bin/zsh
# DESC: Measure what a cc-statusline redraw and a live snapshot cost, in CPU and wall time
set -euo pipefail

if [[ ${1:-} == (-h|--help) ]]; then
  print "usage: ${0:t} [runs]"
  print "Runs a status line redraw on sample input, then \`cc-statusline.js live\` over a copy of"
  print "the real spool, each [runs] times (default 10), and prints CPU and wall time per run."
  print "Everything is written to a throwaway cache dir; the real one is only read."
  exit 0
fi

runs=${1:-10}
repo=${0:A:h:h}
script=$repo/cc-statusline.js
node=$(command -v node)
zmodload zsh/datetime
now=$EPOCHSECONDS

export CC_STATUSLINE_CACHE_DIR=$(mktemp -d)
trap 'rm -rf -- "$CC_STATUSLINE_CACHE_DIR"' EXIT
export CC_STATUSLINE_COLUMNS=200
real_cache=${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline

# A fresh usage cache so no redraw reaches the usage endpoint, and no transcript
# path so no redraw starts a topic call.
print -r -- "{\"fetched_at\":$((now * 1000)),\"seven_day_seen\":null,\"fable\":null,\"error\":null}" \
  > $CC_STATUSLINE_CACHE_DIR/usage.json
input="{\"session_id\":\"00000000-0000-4000-8000-000000000000\",\"cwd\":\"$repo\",\
\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"Opus 5\"},\"effort\":{\"level\":\"high\"},\
\"cost\":{\"total_duration_ms\":600000},\"context_window\":{\"used_percentage\":30}}"

# CPU from /usr/bin/time (user + sys, the process and the children it waited
# for), wall from the shell clock.
measure() {
  local label=$1 times=$2 stdin=$3; shift 3
  local cpu=() wall=() out
  for i in {1..$times}; do
    local start=$EPOCHREALTIME
    out=$( { /usr/bin/time -p "$@" < $stdin > /dev/null; } 2>&1 )
    wall+=$(( (EPOCHREALTIME - start) * 1000 ))
    cpu+=$(print -r -- "$out" | awk '/^user/ {u=$2} /^sys/ {s=$2} END {printf "%.0f", (u+s)*1000}')
  done
  printf '%-22s cpu ms: %s\n' "$label" "${(j:, :)cpu}"
  printf '%-22s wall ms: %s\n' "" "${(j:, :)${(@)wall%.*}}"
}

print -r -- "$input" > $CC_STATUSLINE_CACHE_DIR/input.json
measure "redraw" $runs $CC_STATUSLINE_CACHE_DIR/input.json "$node" "$script"

if [[ -d $real_cache/live ]]; then
  mkdir -p $CC_STATUSLINE_CACHE_DIR/live
  cp $real_cache/live/*.json(N) $CC_STATUSLINE_CACHE_DIR/live/
  # The first snapshot reads every live transcript in full; later ones read only
  # what was appended since.
  measure "live (first)" 1 /dev/null "$node" "$script" live
  measure "live (incremental)" $runs /dev/null "$node" "$script" live
fi
print "node: $node"
