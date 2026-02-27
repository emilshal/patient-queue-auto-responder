# Patient Queue Auto Responder

A Tampermonkey userscript that watches a queue page and clicks a **new patient link** under the **Patient Name** column immediately.

This is designed for real-time queue workflows where patients are lost if not clicked within a few seconds.

## Why this approach

- Runs inside the logged-in browser session (no credential handling)
- Uses DOM changes (`MutationObserver`) for near-instant detection
- Uses popup-first detection for short-lived 4-second claim windows
- Uses a fast fallback scan for reliability
- Includes dedupe + cooldown logic to avoid duplicate clicks

## Quick start

1. Install [Tampermonkey](https://www.tampermonkey.net/).
2. Open `userscript/patient-queue-auto-responder.user.js`.
3. In Tampermonkey, create a new script and paste the file contents.
4. For DialCare, defaults are already prefilled. If needed, edit `CONFIG`:
   - `enabledHostPatterns` (already includes `provider.dialcare.com` and `*.dialcare.com`)
   - `queueRootSelector` (optional)
   - `explicitLinkSelector` (optional override)
5. Save the script and refresh the queue page.
6. Keep that tab open and active during operation.

## Required config

Update these first:

- `enabledHostPatterns`: allowed hostname(s) where the script is active.
- `patientColumnHeaderText`: defaults to `["Patient Name", "Client Name"]`.

Optional but useful:

- `queueRootSelector`: limit scanning to the queue container.
- `explicitLinkSelector`: exact selector for patient links if known.
- `popupRootSelector`: exact selector for the claim popup if known.
- `scanIntervalMs`: fallback scan frequency (default `40ms`).
- `postClickCooldownMs`: lockout after click to prevent duplicates.

## Controls

- `Alt+Shift+Q`: pause/resume watcher
- `Alt+Shift+D`: dump debug snapshot in browser console
- `Alt+Shift+R`: show a support report and copy it to clipboard

A small status badge appears in the lower-right corner of the page.
You can click the badge to open a support report (no hotkeys needed).
DevTools API is also exposed on `window.PQAR` (for example `PQAR.getState()` and `PQAR.scanNow()`).

## How it works

1. On startup, the script marks all currently rendered candidate links as already seen (so it does not click old queue entries).
2. A `MutationObserver` watches the queue area for DOM changes.
3. On each change (or fallback interval), the script looks for links in visible popups first.
4. If no popup candidates exist, it falls back to **Patient Name** table-column detection.
5. For each unseen visible link, it builds a stable dedupe key (`href + text + row text`) and clicks immediately.
6. A short cooldown prevents duplicate clicks from repeated DOM updates.
7. Seen entries are pruned periodically so the script can run for long sessions.

## Tuning checklist

1. Schedule a test patient with known arrival time.
2. Open DevTools console and run with `CONFIG.debug = true`.
3. Verify candidate links appear in `Alt+Shift+D` debug output.
4. If not detected, set `queueRootSelector` and/or `explicitLinkSelector`.
5. Reduce `scanIntervalMs` only if needed and CPU remains acceptable.

## Safety notes

- Confirm this automation is allowed by your queue vendor and office policy.
- Avoid writing PHI into logs or screenshots.
- Keep a manual fallback process in place.

## Repo structure

- `userscript/patient-queue-auto-responder.user.js`: Tampermonkey runtime script
- `docs/TUNING.md`: selector calibration and troubleshooting
