#!/usr/bin/env -S uv run --script
# DESC: Run real Claude Code in a pty and show how it actually draws the status line
#
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyte"]
# ///
"""Run a real Claude Code session in a pseudo-terminal at a given width, point its
status line at this checkout's cc-statusline.js (or a --command override), capture
the raw bytes the terminal received, and render them back to readable text.

Rendering is delegated to pyte, a full VT100/xterm emulator, rather than a
hand-rolled subset. Claude Code's actual output uses cursor addressing, erase-in-
line, SGR, and the ?2026 synchronized-update brackets together, and a partial
emulator silently drifts the moment any of those interact in a way it did not
anticipate -- which is exactly the failure mode this tool exists to catch. pyte
handles the full set correctly, so correctness of the render is never in question,
only correctness of the capture. It is pulled in via this script's own PEP 723
dependency block (see the header above) rather than a persistent virtualenv, and
`uv run --script` (what the shebang invokes) resolves and caches it on first use --
this file must be run directly (./scripts/capture-statusline.py), or via
`uv run scripts/capture-statusline.py`, not with a bare `python3`, or the pyte
import below will fail.

Why a pty at all: Claude Code only renders a status line when it thinks it owns a
real terminal. Piping sample JSON straight into cc-statusline.js (see
scripts/preview.zsh) tells you what the script emits; it does not tell you how
Claude Code's own renderer wraps, truncates, or repaints that output at a given
column width, which is a question only a real session in a real pty can answer.
"""
import argparse
import json
import os
import pty
import select
import shlex
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def find_on_path(name: str) -> str:
    found = shutil.which(name)
    if not found:
        sys.exit(f"error: `{name}` not found on PATH")
    return found


def build_command(args) -> str:
    """The shell command Claude Code's statusLine setting will run on every
    refresh. --input wraps whichever command is active in `cat <file> |`, so a
    test can hand the status line fixed JSON instead of Claude Code's own live
    session state -- useful for exercising a specific display state at a real
    terminal width instead of a synthetic one."""
    if args.command:
        command = args.command
    else:
        node = find_on_path("node")
        script = REPO / "cc-statusline.js"
        command = f"{shlex.quote(node)} {shlex.quote(str(script))}"
    if args.input:
        input_path = Path(args.input).resolve()
        if not input_path.is_file():
            sys.exit(f"error: --input file not found: {input_path}")
        command = f"cat {shlex.quote(str(input_path))} | {command}"
    return command


def transcript_path(session_id: str) -> Path:
    # Claude Code names a session's transcript after the cwd it was launched in,
    # with '/' replaced by '-', under ~/.claude/projects/. We always launch in
    # REPO, so the slug is fixed and known before the session even starts.
    slug = str(REPO).replace("/", "-")
    return Path.home() / ".claude" / "projects" / slug / f"{session_id}.jsonl"


def capture(args, command: str, cache_dir: str, session_id: str) -> bytes:
    settings = json.dumps(
        {"statusLine": {"type": "command", "command": command, "refreshInterval": 2}}
    )
    claude = find_on_path("claude")

    os.environ["CC_STATUSLINE_CACHE_DIR"] = cache_dir
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLORTERM"] = "truecolor"
    os.environ["TERM_PROGRAM"] = "iTerm.app"

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(REPO)
        os.execvp(claude, [claude, "--settings", settings, "--session-id", session_id])

    # 40 rows is arbitrary headroom, not a claim about anyone's real terminal;
    # only the column count is under test here.
    fcntl_ioctl_winsize(fd, rows=40, cols=args.columns)

    buf = b""
    end = time.time() + args.seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        # Answer the device queries Claude Code sends on startup; without a
        # reply it stalls waiting for a terminal that will never speak back.
        if b"\x1b[6n" in chunk:
            os.write(fd, b"\x1b[1;1R")
        if b"\x1b[c" in chunk:
            os.write(fd, b"\x1b[?62;22c")

    quit_cleanly(fd, pid)
    return buf


def fcntl_ioctl_winsize(fd, rows, cols):
    import fcntl

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def quit_cleanly(fd, pid):
    """No prompt was ever sent, so there is nothing to interrupt mid-turn --
    Ctrl-C is just Claude Code's own quit key here. Escalate to SIGTERM and
    finally SIGKILL only if the REPL does not take the hint, so a hung session
    can never make this script hang."""
    for deadline, action in (
        (1.5, lambda: os.write(fd, b"\x03")),
        (1.5, lambda: os.write(fd, b"\x03")),
        (1.5, lambda: os.kill(pid, signal.SIGTERM)),
    ):
        try:
            action()
        except OSError:
            break
        end = time.time() + deadline
        while time.time() < end:
            done_pid, _ = os.waitpid(pid, os.WNOHANG)
            if done_pid == pid:
                return
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    os.read(fd, 65536)
                except OSError:
                    return
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except OSError:
        pass


def render_rows(raw: bytes, cols: int) -> str:
    import pyte

    class Screen(pyte.Screen):
        # Claude Code probes the terminal (cursor position, device attributes)
        # on startup; pyte's default handlers for those are noisy no-ops that
        # print warnings, not failures, but silence them anyway.
        def report_device_status(self, *a, **k):
            pass

        def report_device_attributes(self, *a, **k):
            pass

        def set_mode(self, *a, **k):
            # Claude Code's synchronized-update brackets (DEC private mode
            # 2026) rely on the private-mode variant of set_mode; force it so
            # pyte doesn't mistake them for the public-mode form.
            k.pop("private", None)
            try:
                super().set_mode(*a, private=True, **k)
            except Exception:
                pass

    screen = Screen(cols, 40)
    stream = pyte.ByteStream(screen)
    stream.feed(raw)
    lines = [f"{i:2}|{line.rstrip()}" for i, line in enumerate(screen.display) if line.strip()]
    return "\n".join(lines)


def render_raw(raw: bytes) -> str:
    # repr() is the whole point here: it turns \x1b, \r and friends into
    # visible escapes instead of moving the cursor around the reader's own
    # terminal while they're trying to read the capture.
    return repr(raw)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Run real Claude Code in a pty at a given width and show how it actually "
            "draws the status line -- not what cc-statusline.js emits (see "
            "scripts/preview.zsh for that), but what Claude Code's own renderer does "
            "with it: wrapping, truncation, repaint. Sends no prompt, so no API "
            "request is made; uses a throwaway CC_STATUSLINE_CACHE_DIR; deletes its "
            "own session transcript afterward.\n\n"
            "Rendering requires pyte, declared as this script's own PEP 723 "
            "dependency and resolved by `uv run --script` (what the shebang "
            "invokes) -- run it directly (./scripts/capture-statusline.py) or via "
            "`uv run scripts/capture-statusline.py`, not with a bare python3."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--columns", type=int, default=100, help="pty width to render at")
    parser.add_argument(
        "--command",
        help="statusLine command to run instead of this checkout's cc-statusline.js",
    )
    parser.add_argument(
        "--input",
        help="JSON file to feed the status line on every refresh, instead of Claude "
        "Code's own live session state",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=3.0,
        help="how long to capture before quitting (long enough for the initial "
        "paint plus one 2s statusLine refresh)",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="print the captured bytes with escapes visible, instead of the "
        "rendered screen",
    )
    args = parser.parse_args()

    command = build_command(args)
    session_id = str(uuid.uuid4())
    cache_dir = tempfile.mkdtemp(prefix="cc-statusline-capture-")
    try:
        raw = capture(args, command, cache_dir, session_id)
    finally:
        shutil.rmtree(cache_dir, ignore_errors=True)
        transcript = transcript_path(session_id)
        if transcript.exists():
            transcript.unlink()

    print(render_raw(raw) if args.raw else render_rows(raw, args.columns))


if __name__ == "__main__":
    main()
