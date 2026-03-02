# AutoHotkey Fallback (Windows)

This is a desktop fallback when DOM userscript access/debugging is too hard.
It watches the queue screen region and clicks the patient/client name link as soon as a blue link appears.

## Files

- `patient-queue-auto-responder.ahk`: main script
- `config.ini`: created automatically after setup
- `patient-queue-ahk.log`: runtime log for support

## Client setup (simple)

1. Install **AutoHotkey v2** on Windows.
2. Open DialCare queue page and keep it visible.
3. Double-click `patient-queue-auto-responder.ahk`.
4. On first run, follow setup prompts:
   - Step 1: mark top-left of Client/Patient Name scan area with `F8`
   - Step 2: mark bottom-right of scan area with `F8`
   - Step 3: mark click point on first-row name link with `F8`
   - Step 4: if a clear blue/teal patient link is visible, sample it with `F8`; otherwise press `F9` (recommended)
5. Script auto-starts monitoring.

## Hotkeys

- `F6`: start/pause monitoring
- `F7`: run setup wizard again
- `F8`: show status report
- `F9`: help
- `F10`: run synthetic test (no real patient needed)
- `Ctrl+Shift+T`: alternate synthetic test hotkey
- `Esc`: emergency stop monitoring

## Important operating rules

1. Queue must stay visible on screen (not minimized or covered).
2. Do not move/resize browser window after setup unless you re-run setup (`F7`).
3. Keep browser zoom stable (100% recommended).
4. Run only one copy of this script (one tray `H` icon).
5. Script now only scans/clicks when active window is Chrome with `DialCare` in title.

## Support and debugging

1. Ask client to press `F8` and send the status text.
2. Ask client to send `patient-queue-ahk.log` from the script folder.
3. If misses happen, re-run setup with a tighter scan area around first-column name links.
4. If a PixelSearch invalid-handle error appears, re-run setup with `F7` and keep the queue window fully visible.
5. If a log-write file-in-use error appears, close duplicate script instances and restart.
6. If logs show `detectColor=0xF2F2F2` or other gray/white values, rerun setup and use `F9` at color step.

## Fast test without waiting for patients

1. Keep the queue page visible.
2. Press `F10` (or `Ctrl+Shift+T`).
3. Script shows a temporary blue \"TEST LINK\" box inside scan area.
4. If setup is correct, script should detect and click it, then show \"Synthetic test PASSED\".

## Tuning defaults (in `config.ini`)

- `PollMs=25`
- `RequiredConsecutiveHits=2`
- `ClickCooldownMs=1200`
- `ColorVariation=58`

Lower `PollMs` is faster but uses more CPU.
Higher `ColorVariation` catches more shades of blue but can increase false positives.
