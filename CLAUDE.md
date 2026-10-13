# cc-statusline

A Claude Code status line (`cc-statusline.js`, `hooks/`, `commands/`) and CC Sessions, the macOS
app that lists every live session (`src/main.swift`). `README.md` describes both.

## Working in it

- Test, build and install the app with `project-lifecycle test`, `build`, `install`. A plain
  `swift build` fetches the shared package from GitHub instead of the local checkout and fails on
  newer APIs (`clearFocusAtLaunch`); ignore that error, or set `PROJECT_LIFECYCLE_PACKAGE`.
- Rebuild and install after every app change, but never relaunch the running app: the user does.
- Never click, press keys or bring windows forward to test the app while the user is at the machine.
- Caption colours in the sessions table are one colour per caption; colour a part of it by adding
  to `highlights` (caption-relative ranges), as the ssh warning and the Cache tags do.
