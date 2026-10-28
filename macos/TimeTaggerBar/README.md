# TimeTaggerBar

A small native macOS menu bar client for TimeTagger (macOS 13+).

- running timer in the menu bar; the popover focuses on the current task: big timer, Stop, "Switch to…", three recent tasks to resume, today's total
- start times in local time and in a work time zone chosen in Settings
- History window: records by day with day totals, date range, search, add/edit/delete/resume
- Report window: report options, an editable table preview (edit cells, remove/add rows), Copy table (TSV + HTML for spreadsheets) and Save CSV
- closing the lid (sleep) stops the running task; opening it resumes it as a new record (toggle in Settings)
- sign in with server, username and password (like the web login); the app keeps only the resulting API token, in the Keychain

Build: `brew install create-dmg && ./build-app.sh` → `build/TimeTaggerBar.dmg` (ad-hoc signed; first launch: right-click → Open).
CI builds the same DMG as an artifact of the `macOS app` workflow.
