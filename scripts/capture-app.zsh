#!/bin/zsh
# DESC: Capture the CC Sessions window, optionally cropped, without activating it
set -euo pipefail

pid=0
name="CC Sessions"
while [[ ${1:-} == --* && ${1:-} != --help ]]; do
  case $1 in
    --pid) pid=${2:?"--pid needs a process id"}; shift 2 ;;
    --name) name=${2:?"--name needs a window title"}; shift 2 ;;
    *) print -u2 "capture-app: unknown option $1"; exit 1 ;;
  esac
done

if [[ ${1:-} == (-h|--help) || $# -lt 1 ]]; then
  cat <<'EOF'
usage: capture-app.zsh [--pid PID] [--name TITLE] OUT.png [X Y WIDTH HEIGHT]

Captures the running app's window by its window id, so another window on top
of it does not end up in the picture and the app never becomes active. With a
rectangle, crops to it, in the window's own pixels from its top left.

--pid PID    only a window of that process. Needed when a second copy of the
             app runs beside the installed one (a build under test): without
             it the first window titled CC Sessions is taken, whichever copy
             owns it.
--name TITLE the window to capture (default "CC Sessions"); a sheet over it is
             its own window, e.g. "New Session".
EOF
  exit $(( $# < 1 ))
fi

out=$1
shift
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat > "$tmp/find.swift" <<'EOF'
import CoreGraphics
let a = CommandLine.arguments
let pid = Int(a[2])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
if let w = list.first(where: {
    ($0[kCGWindowName as String] as? String) == a[1]
        && (pid == 0 || ($0[kCGWindowOwnerPID as String] as? Int) == pid)
}) {
    print(w[kCGWindowNumber as String]!)
}
EOF
id=$(swift "$tmp/find.swift" "$name" "$pid")
[[ -n $id ]] || { print -u2 "capture-app: no window titled \"$name\" is open"; exit 1; }

if (( $# == 0 )); then
  screencapture -x -o -l "$id" "$out"
  exit 0
fi
(( $# == 4 )) || { print -u2 "capture-app: a crop takes X Y WIDTH HEIGHT"; exit 1; }

screencapture -x -o -l "$id" "$tmp/window.png"
cat > "$tmp/crop.swift" <<'EOF'
import AppKit
let a = CommandLine.arguments
guard let image = NSImage(contentsOfFile: a[1]) else { fatalError("cannot read \(a[1])") }
var r = NSRect(origin: .zero, size: image.size)
let cg = image.cgImage(forProposedRect: &r, context: nil, hints: nil)!
let rect = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
guard let part = cg.cropping(to: rect) else { fatalError("the rectangle is outside the window") }
try NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
EOF
swift "$tmp/crop.swift" "$tmp/window.png" "$out" "$@"
