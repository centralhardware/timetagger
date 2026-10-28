# TimeTaggerBar

A small native macOS menu bar client for TimeTagger (macOS 13+).

- running timer in the menu bar; the popover focuses on the current task: big timer, Stop, "Switch to…", three recent tasks to resume, today's total
- start times in local time and in a work time zone chosen in Settings
- Report window: the web app's report options, an editable table preview (edit cells, remove/add rows) and Copy table (TSV + HTML for spreadsheets)
- server URL + API token in Settings (token kept in the Keychain)

Build: `brew install create-dmg && ./build-app.sh` → `build/TimeTaggerBar.dmg` (ad-hoc signed; first launch: right-click → Open).
CI builds the same DMG as an artifact of the `macOS app` workflow.
