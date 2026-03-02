# AutoHotkey Fallback (Windows)

This is a desktop fallback when DOM userscript access/debugging is too hard.
It watches the queue screen region and clicks the patient/client name link when configured link colors appear.

## Files

- `patient-queue-auto-responder.ahk`: main script
- `config.ini`: created automatically after setup
- `patient-queue-ahk.log`: runtime log for support

## Client setup (simple)

1. Install **AutoHotkey v2** on Windows.
2. Open DialCare queue page and keep it visible.
3. Double-click `patient-queue-auto-responder.ahk`.
4. This build uses a locked known-good preset by default (no calibration needed).
5. Script auto-starts monitoring.

## Hotkeys

- `F6`: start/pause monitoring
- `F7`: applies locked known-good preset (setup wizard disabled in this mode)
- `F8`: show status report
- `F9`: help
- `F10`: run synthetic test (no real patient needed)
- `Ctrl+Shift+T`: alternate synthetic test hotkey
- `Esc`: emergency stop monitoring

## Important operating rules

1. Queue must stay visible on screen (not minimized or covered).
2. Do not move/resize browser window while running (preset is fixed to known-good coordinates).
3. Keep browser zoom stable (100% recommended).
4. Run only one copy of this script (one tray `H` icon).
5. Script now only scans/clicks when active window is Chrome with `DialCare` in title.

## Support and debugging

1. Ask client to press `F8` and send the status text.
2. Ask client to send `patient-queue-ahk.log` from the script folder.
3. If misses happen, press `F7` to re-apply the locked preset.
4. If a PixelSearch invalid-handle error appears, keep the queue window fully visible and press `F7`.
5. If a log-write file-in-use error appears, close duplicate script instances and restart.
6. If logs show `detectColor=0xF2F2F2` or other gray/white values, share the log; this preset should target teal/blue link colors.

## Fast test without waiting for patients

1. Keep the queue page visible.
2. Press `F10` (or `Ctrl+Shift+T`).
3. Script shows a temporary blue \"TEST LINK\" box inside scan area.
4. If setup is correct, script should detect and click it, then show \"Synthetic test PASSED\".

## Tuning defaults (in `config.ini`)

- `PollMs=300`
- `RequiredConsecutiveHits=1`
- `ClickCooldownMs=900`
- `ColorVariation=5`

Lower `PollMs` is faster but uses more CPU.
Higher `ColorVariation` catches more shades of blue but can increase false positives.
