# TimeTaggerBar

A small native macOS menu bar client for TimeTagger (macOS 13+).

- ⌥⌘T anywhere opens/closes the popover (global hotkey, no Accessibility permission needed)
- running timer in the menu bar; the popover focuses on the current task: big timer, Stop, "Switch to…", three recent tasks to resume, today's total
- start times in local time and in a work time zone chosen in Settings
- History window: records by day with day totals, date range, search, add/edit/delete/resume
- Report window: report options, an editable table preview (edit cells, remove/add rows) and Copy table (TSV + HTML for spreadsheets)
- closing the lid (sleep) stops the running task; opening it resumes it as a new record (toggle in Settings)
- app usage (Settings → General): a background LaunchAgent records the app in front and its window title (with Accessibility), time away (idle 5 min / locked / asleep) and pickups, and sends the blocks to the server, which keeps them in ClickHouse; it runs whether or not the menu bar app is open
- sign in with server, username and password (like the web login); the app keeps only the resulting API token, in the Keychain

Install:

```sh
brew tap centralhardware/timetagger https://github.com/centralhardware/timetagger
brew install --cask timetaggerbar
```

Release: push a `macos-vX.Y.Z` tag — CI builds the dmg, publishes the release and opens a PR bumping `Casks/timetaggerbar.rb`.

Build: `brew install create-dmg && ./build-app.sh` → `build/TimeTaggerBar.dmg` (ad-hoc signed; first launch: right-click → Open).
CI builds the same DMG as an artifact of the `macOS app` workflow.
