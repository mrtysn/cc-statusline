#!/bin/zsh -f
# DESC: Claude Code hook: hand each event to Agent Bar Hopping as a file in the cache
#
# Registered as an async command hook, so Claude Code never waits on it. It does
# no parsing: the event's JSON is written whole to a file named by the time it
# arrived, and the app reads, acts on and deletes it. Writing to a temporary name
# first means the app never sees half a file.
set -euo pipefail
zmodload zsh/datetime

dir=${CC_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cc-statusline}/events
mkdir -p -- "$dir"
tmp=$dir/.$$.tmp
cat > "$tmp"
# Microseconds since the epoch, always 16 digits, so names sort by arrival.
printf -v stamp '%.0f' $(( EPOCHREALTIME * 1e6 ))
mv -- "$tmp" "$dir/$stamp-$$.json"
