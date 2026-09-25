#!/bin/zsh
# DESC: Capture the Agent Bar Hopping window, optionally cropped, without activating it
set -euo pipefail

if [[ ${1:-} == (-h|--help) || $# -lt 1 ]]; then
  cat <<'EOF'
usage: capture-app.zsh OUT.png [X Y WIDTH HEIGHT]

Captures the running app's window by its window id, so another window on top
of it does not end up in the picture and the app never becomes active. With a
rectangle, crops to it, in the window's own pixels from its top left.
EOF
  exit $(( $# < 1 ))
fi

out=$1
shift
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat > "$tmp/find.swift" <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
if let w = list.first(where: { ($0[kCGWindowName as String] as? String) == "Agent Bar Hopping" }) {
    print(w[kCGWindowNumber as String]!)
}
EOF
id=$(swift "$tmp/find.swift")
[[ -n $id ]] || { print -u2 "capture-app: no Agent Bar Hopping window is open"; exit 1; }

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
