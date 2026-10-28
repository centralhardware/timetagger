# TimeTaggerBar

A small native macOS menu bar client for TimeTagger (macOS 13+).

- running timer in the menu bar; start (stops the running one), stop, resume recent
- records for today / yesterday / this week / this month: add, edit, delete, resume
- totals per tag for the chosen period
- server URL + API token in Settings (token kept in the Keychain)

Build: `./build-app.sh` → `build/TimeTaggerBar.app` (ad-hoc signed; first launch: right-click → Open).
CI builds the same zip as an artifact of the `macOS app` workflow.
