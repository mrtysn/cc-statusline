#!/bin/zsh
# DESC: Simulate the auto topic refresh in a focused iTerm2 tab, end to end
set -euo pipefail

if [[ ${1:-} == (-h|--help) || $# -ne 1 ]]; then
  print "usage: ${0:t} <transcript.jsonl>"
  print "Runs cc-statusline.js against a copy of a Claude Code transcript, faking iTerm2"
  print "focus with a stub osascript, and checks each refresh rule in turn."
  print "Makes two real Haiku calls through 'claude -p'."
  exit $(( $# == 1 ? 0 : 1 ))
fi

repo=${0:A:h:h}
script=$repo/cc-statusline.js
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

cp -- "$1" "$work/transcript.jsonl"
mkdir -p "$work/bin"
print -r -- '#!/bin/zsh
print -r -- "${FAKE_FOCUSED_TTY:-}"' > "$work/bin/osascript"
chmod +x "$work/bin/osascript"

export CC_STATUSLINE_CACHE_DIR=$work/cache PATH=$work/bin:$PATH TERM_PROGRAM=iTerm.app
id=00000000-0000-0000-0000-00000000000a
topics=$CC_STATUSLINE_CACHE_DIR/topics
failures=0

# The terminal cc-statusline.js will resolve for itself: its first ancestor with a tty.
own_tty=$(node -e '
  const { execFileSync } = require("child_process");
  const procs = new Map(execFileSync("ps", ["-A", "-o", "pid=,ppid=,tty="], { encoding: "utf8" })
    .trim().split("\n").map((l) => { const [p, pp, t] = l.trim().split(/\s+/); return [p, { pp, t }]; }));
  for (let p = String(process.pid); procs.has(p); p = procs.get(p).pp) {
    const { t } = procs.get(p);
    if (t && t !== "??") { console.log("/dev/" + t); break; }
  }')
[[ -n $own_tty ]] || { print -u2 "no controlling terminal found; run this from a terminal"; exit 1 }

# Prints the topic row with the frame stripped, keeping the topic's own colour code.
draw() {
  print -r -- "{\"session_id\":\"$id\",\"transcript_path\":\"$work/transcript.jsonl\",\"cwd\":\"$repo\"}" \
    | FAKE_FOCUSED_TTY=$1 "$script" | head -1 | sed $'s/\x1b\\[38;2;66;69;80m[^\x1b]*\x1b\\[0m//g'
}
check() {
  if eval "$2"; then print "  ok    $1"; else print "  FAIL  $1"; failures=$((failures + 1)); fi
}
wait_child() { while [[ -e $topics/$id.lock ]]; do sleep 0.5; done }
age_by() {
  node -e 'const fs = require("fs"), [f, k, ms] = process.argv.slice(1), j = JSON.parse(fs.readFileSync(f));
    j[k] -= Number(ms); fs.writeFileSync(f, JSON.stringify(j));' "$1" "$2" "$3"
}

print "1. another pane focused"
draw /dev/ttys999 > /dev/null
check "no refresh starts" '[[ ! -e $topics/$id.lock && ! -e $topics/$id.json ]]'

print "2. this pane focused, no topic yet"
draw "$own_tty" > /dev/null
check "refresh starts" '[[ -e $topics/$id.lock ]]'
wait_child
check "topic written" 'grep -q "\"topic\":\"" $topics/$id.json'
print "        $(< $topics/$id.json)"

print "3. next redraw"
row=$(draw "$own_tty")
check "new topic is yellow" '[[ $row == *$'"'"'\e[33m'"'"'* ]]'

print "4. transcript changes right away"
touch "$work/transcript.jsonl"
draw "$own_tty" > /dev/null
check "2-minute floor holds it back" '[[ ! -e $topics/$id.lock ]]'

print "5. transcript changes 3 minutes after the last topic"
age_by "$topics/$id.json" generated_at 180000
touch "$work/transcript.jsonl"
draw "$own_tty" > /dev/null
check "refresh starts" '[[ -e $topics/$id.lock ]]'
wait_child
print "        $(< $topics/$id.json)"

print "6. 61 seconds after the topic was first shown"
draw "$own_tty" > /dev/null
age_by "$topics/$id.seen" shown_at 61000
row=$(draw "$own_tty")
check "topic back to normal" '[[ $row != *$'"'"'\e[33m'"'"'* && $row == *$'"'"'\e[0m'"'"'* ]]'

(( failures == 0 )) && print "\nall checks passed" || { print "\n$failures check(s) failed"; exit 1 }
