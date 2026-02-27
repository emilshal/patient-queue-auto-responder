# Tuning Guide

## 1) Identify stable selectors

Open browser DevTools (`Inspect`) on:

- Queue container element
- Patient link inside the `Patient Name` column
- Optional countdown timer element

Example settings:

```js
queueRootSelector: "#queueTableWrapper",
explicitLinkSelector: "table#patientQueue tbody tr td.patient-name a"
```

## 2) Prefer explicit selectors when possible

If the queue page has stable classes or IDs, set `explicitLinkSelector`.
This avoids table-header inference and reduces false positives.

## 3) Countdown gating (optional)

If the page shows a dedicated countdown element only when a claim window starts, enable:

```js
clickOnlyWhenCountdownVisible: true,
countdownSelector: ".claim-countdown"
```

Use only if countdown visibility is reliable. Otherwise leave disabled.

## 4) Performance targets

- `scanIntervalMs`: `40-80ms` is usually enough with DOM observer support.
- Aim for detect-to-click under `300ms` in tests.

## 5) Long-run stability checks

During an 8-hour soak test:

- Confirm no console errors accumulate
- Confirm no duplicate clicks on same patient
- Confirm CPU usage remains acceptable

## 6) Troubleshooting

### No click happens

- Hostname might not match `enabledHostPatterns`
- Selector mismatch for queue/patient links
- Link not inside the viewport
- Queue not rendered as `<table>` and `explicitLinkSelector` not set

### Wrong item clicked

- Tighten `explicitLinkSelector`
- Set `queueRootSelector` to a unique container
- Verify only patient links are matched

### Duplicate clicks

- Increase `postClickCooldownMs` (e.g. `350` -> `700`)
- Ensure dedupe key includes stable patient row text

## 7) Deployment recommendation

- Keep this userscript as MVP in one clinic
- After selectors are proven stable, move to an extension build for easier updates
