// ==UserScript==
// @name         Patient Queue Auto Responder
// @namespace    https://github.com/emilshal/patient-queue-auto-responder
// @version      0.2.0
// @description  Watches the patient queue and clicks new patient links immediately.
// @author       Emil
// @match        *://provider.dialcare.com/*
// @match        *://*.dialcare.com/*
// @run-at       document-idle
// @grant        none
// ==/UserScript==

(() => {
  "use strict";

  const CONFIG = {
    enabledHostPatterns: ["provider.dialcare.com", "*.dialcare.com"],
    queueRootSelector: null,
    patientColumnHeaderText: ["Patient Name", "Client Name"],
    explicitLinkSelector: null,
    preferPopupCandidates: true,
    popupRootSelector: null,
    popupLinkSelector: "a, [role='link'], [onclick]",
    allowTableFallbackWhenNoPopup: true,
    clickOnlyWhenCountdownVisible: false,
    countdownSelector: null,
    requireInViewport: false,
    scanIntervalMs: 40,
    postClickCooldownMs: 350,
    seenEntryTtlMs: 4 * 60 * 60 * 1000,
    debug: true
  };

  const state = {
    paused: false,
    seen: new Map(),
    lockUntilMs: 0,
    intervalId: null,
    observer: null,
    scanQueued: false,
    statusNode: null,
    lastStatusAtMs: 0,
    lastClickAtMs: 0,
    lastClickLabel: null
  };

  function nowMs() {
    return Date.now();
  }

  function normalizeText(value) {
    return String(value || "")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
  }

  function debugLog(...args) {
    if (CONFIG.debug) {
      console.log("[PQAR]", ...args);
    }
  }

  function hostMatchesPattern(host, pattern) {
    const hostValue = normalizeText(host);
    const rule = normalizeText(pattern);

    if (!rule) {
      return false;
    }

    if (rule.startsWith("*.")) {
      const suffix = rule.slice(2);
      return hostValue === suffix || hostValue.endsWith(`.${suffix}`);
    }

    return hostValue === rule;
  }

  function isHostAllowed() {
    return CONFIG.enabledHostPatterns.some((pattern) =>
      hostMatchesPattern(window.location.hostname, pattern)
    );
  }

  function setStatus(message, tone = "info") {
    const node = ensureStatusNode();
    if (!node) {
      return;
    }

    const toneStyles = {
      info: { background: "#0f172a", border: "#1d4ed8" },
      success: { background: "#052e16", border: "#16a34a" },
      warning: { background: "#451a03", border: "#f59e0b" },
      danger: { background: "#450a0a", border: "#dc2626" }
    };

    const style = toneStyles[tone] || toneStyles.info;
    node.style.background = style.background;
    node.style.borderColor = style.border;
    node.textContent = `PQAR: ${message}`;
    state.lastStatusAtMs = nowMs();
  }

  function formatTs(ms) {
    if (!ms) {
      return "n/a";
    }

    try {
      return new Date(ms).toISOString();
    } catch (_) {
      return "n/a";
    }
  }

  function ensureStatusNode() {
    if (state.statusNode && document.contains(state.statusNode)) {
      return state.statusNode;
    }

    const node = document.createElement("div");
    node.id = "pqar-status-badge";
    Object.assign(node.style, {
      position: "fixed",
      right: "14px",
      bottom: "14px",
      zIndex: "2147483647",
      color: "#f8fafc",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: "12px",
      lineHeight: "1.2",
      borderRadius: "8px",
      border: "1px solid #1d4ed8",
      background: "#0f172a",
      padding: "8px 10px",
      boxShadow: "0 6px 18px rgba(0,0,0,0.35)",
      pointerEvents: "auto",
      cursor: "pointer",
      userSelect: "none"
    });
    node.title = "Click for support report";
    node.addEventListener("click", () => {
      void showSupportReport();
    });

    document.documentElement.appendChild(node);
    state.statusNode = node;
    return node;
  }

  function getQueueRoot() {
    if (CONFIG.queueRootSelector) {
      return document.querySelector(CONFIG.queueRootSelector) || document;
    }

    return document;
  }

  function getPatientColumnTargets() {
    if (Array.isArray(CONFIG.patientColumnHeaderText)) {
      return CONFIG.patientColumnHeaderText.map((value) => normalizeText(value)).filter(Boolean);
    }

    return [normalizeText(CONFIG.patientColumnHeaderText)].filter(Boolean);
  }

  function getPatientColumnIndex(table) {
    const headerRow =
      table.querySelector("thead tr") || table.querySelector("tr");

    if (!headerRow) {
      return -1;
    }

    const cells = Array.from(headerRow.querySelectorAll("th, td"));
    const targets = getPatientColumnTargets();

    return cells.findIndex((cell) => {
      const text = normalizeText(cell.textContent);
      return targets.some((target) => text === target || text.includes(target));
    });
  }

  function looksLikeQueueTable(table) {
    const headerText = normalizeText(table.querySelector("thead")?.textContent || table.querySelector("tr")?.textContent || "");
    const queueHints = ["patient name", "client name", "wait time", "visit type", "primary symptoms", "chat"];
    return queueHints.some((hint) => headerText.includes(hint));
  }

  function isElementPotentiallyClickable(element) {
    if (!(element instanceof HTMLElement)) {
      return false;
    }

    if (element.matches("a")) {
      return true;
    }

    if (element.matches("[role='link'], [onclick], button, [tabindex]")) {
      return true;
    }

    return typeof element.click === "function";
  }

  function collectClickablesInNode(root) {
    const selectors = "a, [role='link'], [onclick], button, [tabindex]";
    const nodes = Array.from(root.querySelectorAll(selectors));
    return nodes.filter((node) => isElementPotentiallyClickable(node));
  }

  function collectCandidateLinksFromTables(root) {
    const tables = Array.from(root.querySelectorAll("table"));
    const result = [];

    for (const table of tables) {
      let columnIndex = getPatientColumnIndex(table);
      if (columnIndex < 0 && looksLikeQueueTable(table)) {
        columnIndex = 0;
      }
      if (columnIndex < 0) {
        continue;
      }

      const rows = Array.from(table.querySelectorAll("tbody tr"));
      for (const row of rows) {
        const cells = Array.from(row.children).filter((node) =>
          /^(TD|TH)$/i.test(node.tagName)
        );

        const targetCell = cells[columnIndex];
        if (!targetCell) {
          continue;
        }

        const clickables = collectClickablesInNode(targetCell);
        for (const clickable of clickables) {
          result.push(clickable);
        }
      }
    }

    return result;
  }

  function collectLikelyPopupRoots() {
    const hintSelectors = [
      '[role="dialog"]',
      '[aria-modal="true"]',
      ".modal",
      ".popup",
      ".dialog",
      ".swal2-popup",
      ".swal2-container"
    ];

    const seen = new Set();
    const roots = [];

    if (CONFIG.popupRootSelector) {
      for (const node of document.querySelectorAll(CONFIG.popupRootSelector)) {
        if (node instanceof HTMLElement && !seen.has(node)) {
          seen.add(node);
          roots.push(node);
        }
      }
    }

    for (const selector of hintSelectors) {
      for (const node of document.querySelectorAll(selector)) {
        if (node instanceof HTMLElement && !seen.has(node)) {
          seen.add(node);
          roots.push(node);
        }
      }
    }

    return roots.filter((node) => {
      if (!isVisible(node)) {
        return false;
      }

      const rect = node.getBoundingClientRect();
      return rect.width >= 120 && rect.height >= 50;
    });
  }

  function collectCandidateLinksFromPopups() {
    const roots = collectLikelyPopupRoots();
    const result = [];

    for (const popup of roots) {
      const tableLinks = collectCandidateLinksFromTables(popup);
      if (tableLinks.length > 0) {
        result.push(...tableLinks);
        continue;
      }

      const links = Array.from(popup.querySelectorAll(CONFIG.popupLinkSelector));
      for (const node of links) {
        if (isElementPotentiallyClickable(node)) {
          result.push(node);
        }
      }
    }

    return Array.from(new Set(result));
  }

  function collectCandidateLinks() {
    if (CONFIG.explicitLinkSelector) {
      const selected = Array.from(document.querySelectorAll(CONFIG.explicitLinkSelector));
      return selected.filter((node) => isElementPotentiallyClickable(node));
    }

    if (CONFIG.preferPopupCandidates) {
      const popupLinks = collectCandidateLinksFromPopups();
      if (popupLinks.length > 0) {
        return popupLinks;
      }

      if (!CONFIG.allowTableFallbackWhenNoPopup) {
        return [];
      }
    }

    const queueRoot = getQueueRoot();
    const links = collectCandidateLinksFromTables(queueRoot);
    return Array.from(new Set(links));
  }

  function isVisible(element) {
    if (!element || !(element instanceof HTMLElement)) {
      return false;
    }

    const style = window.getComputedStyle(element);
    if (
      style.display === "none" ||
      style.visibility === "hidden" ||
      style.pointerEvents === "none" ||
      Number(style.opacity || "1") === 0
    ) {
      return false;
    }

    const rect = element.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) {
      return false;
    }

    if (!CONFIG.requireInViewport) {
      return true;
    }

    return !(rect.bottom < 0 || rect.right < 0 || rect.top > window.innerHeight || rect.left > window.innerWidth);
  }

  function buildLinkKey(link) {
    const href = normalizeText(link.getAttribute("href") || "");
    const label = normalizeText(link.textContent || "");
    const row = link.closest("tr");
    const rowText = normalizeText(row ? row.textContent : "").slice(0, 250);
    return `${href}::${label}::${rowText}`;
  }

  function isCountdownGateSatisfied() {
    if (!CONFIG.clickOnlyWhenCountdownVisible) {
      return true;
    }

    if (!CONFIG.countdownSelector) {
      return false;
    }

    const countdown = document.querySelector(CONFIG.countdownSelector);
    return Boolean(countdown && isVisible(countdown));
  }

  function pruneSeenMap() {
    const cutoff = nowMs() - CONFIG.seenEntryTtlMs;
    for (const [key, timestamp] of state.seen.entries()) {
      if (timestamp < cutoff) {
        state.seen.delete(key);
      }
    }
  }

  function clickPatientLink(link, key) {
    const label = normalizeText(link.textContent || "") || "patient link";

    try {
      link.scrollIntoView({ behavior: "auto", block: "center", inline: "nearest" });
    } catch (error) {
      debugLog("scrollIntoView failed", error);
    }

    try {
      link.focus();
      link.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, view: window }));
      link.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, cancelable: true, view: window }));
      link.click();

      state.seen.set(key, nowMs());
      state.lockUntilMs = nowMs() + CONFIG.postClickCooldownMs;
      state.lastClickAtMs = nowMs();
      state.lastClickLabel = label;

      setStatus(`clicked ${label}`, "success");
      debugLog("clicked", { key, label });
      return true;
    } catch (error) {
      setStatus("click failed - check selectors", "danger");
      debugLog("click failed", error);
      state.seen.delete(key);
      return false;
    }
  }

  function scanQueue(reason) {
    if (state.paused) {
      return;
    }

    if (nowMs() < state.lockUntilMs) {
      return;
    }

    pruneSeenMap();

    const candidates = collectCandidateLinks();

    for (const link of candidates) {
      if (!isVisible(link)) {
        continue;
      }

      const key = buildLinkKey(link);
      if (state.seen.has(key)) {
        continue;
      }

      if (!isCountdownGateSatisfied()) {
        debugLog("countdown gate not satisfied yet");
        continue;
      }

      state.seen.set(key, nowMs());
      const clicked = clickPatientLink(link, key);
      if (!clicked) {
        state.seen.delete(key);
      }
      return;
    }

    if (reason === "init" && candidates.length > 0) {
      setStatus(`monitoring (${candidates.length} existing links ignored)`, "info");
    }
  }

  function queueScan(reason) {
    if (state.scanQueued) {
      return;
    }

    state.scanQueued = true;
    queueMicrotask(() => {
      state.scanQueued = false;
      scanQueue(reason);
    });
  }

  function seedSeenLinks() {
    const queueRoot = getQueueRoot();
    const links = collectCandidateLinksFromTables(queueRoot);

    for (const link of links) {
      const key = buildLinkKey(link);
      state.seen.set(key, nowMs());
    }

    setStatus(`monitoring (${links.length} existing links ignored)`, "info");
    debugLog("seeded existing links", links.length);
  }

  function dumpDebugSnapshot() {
    const root = getQueueRoot();
    const popupRoots = collectLikelyPopupRoots();
    const tables = Array.from(root.querySelectorAll("table"));
    const tableSummaries = tables.map((table, index) => {
      const headerCells = Array.from(table.querySelectorAll("thead tr th, thead tr td"));
      return {
        tableIndex: index,
        headers: headerCells.map((cell) => normalizeText(cell.textContent))
      };
    });

    const links = collectCandidateLinks().map((link) => ({
      text: normalizeText(link.textContent),
      href: link.getAttribute("href"),
      key: buildLinkKey(link)
    }));

    console.table(
      popupRoots.map((popup, index) => ({
        popupIndex: index,
        tag: popup.tagName.toLowerCase(),
        className: popup.className,
        textSample: normalizeText(popup.textContent).slice(0, 120)
      }))
    );
    console.table(tableSummaries);
    console.table(links);
    debugLog("debug snapshot", {
      popupCount: popupRoots.length,
      tableCount: tables.length,
      candidateCount: links.length
    });
    setStatus(`debug dumped (${links.length} candidates)`, "warning");
  }

  function buildSupportReport() {
    const popupRoots = collectLikelyPopupRoots();
    const candidates = collectCandidateLinks();
    const report = [
      "PQAR Support Report",
      `time: ${new Date().toISOString()}`,
      `url: ${window.location.href}`,
      `paused: ${state.paused}`,
      `seenSize: ${state.seen.size}`,
      `popupCount: ${popupRoots.length}`,
      `candidateCount: ${candidates.length}`,
      `lockUntil: ${formatTs(state.lockUntilMs)}`,
      `lastClickAt: ${formatTs(state.lastClickAtMs)}`,
      `lastClickLabel: ${state.lastClickLabel || "n/a"}`,
      `scanIntervalMs: ${CONFIG.scanIntervalMs}`,
      `hostAllowed: ${isHostAllowed()}`
    ];
    return report.join("\n");
  }

  async function showSupportReport() {
    const report = buildSupportReport();
    debugLog(report);
    setStatus("support report ready", "warning");

    let copied = false;
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(report);
        copied = true;
      }
    } catch (_) {
      copied = false;
    }

    const message = copied
      ? `${report}\n\n(Report copied to clipboard. Paste this in chat.)`
      : `${report}\n\n(Could not auto-copy. Please copy this text and send it.)`;
    window.alert(message);
  }

  function togglePause() {
    state.paused = !state.paused;

    if (state.paused) {
      setStatus("paused (Alt+Shift+Q to resume)", "warning");
      debugLog("paused");
      return;
    }

    setStatus("monitoring resumed", "info");
    debugLog("resumed");
    queueScan("resume");
  }

  function bindHotkeys() {
    document.addEventListener("keydown", (event) => {
      if (event.altKey && event.shiftKey && event.code === "KeyQ") {
        event.preventDefault();
        togglePause();
      }

      if (event.altKey && event.shiftKey && event.code === "KeyD") {
        event.preventDefault();
        dumpDebugSnapshot();
      }

      if (event.altKey && event.shiftKey && event.code === "KeyR") {
        event.preventDefault();
        void showSupportReport();
      }
    });
  }

  function exposeDebugApi() {
    window.PQAR = {
      pause: () => {
        if (!state.paused) {
          togglePause();
        }
      },
      resume: () => {
        if (state.paused) {
          togglePause();
        }
      },
      togglePause,
      scanNow: () => scanQueue("manual"),
      dumpDebugSnapshot,
      supportReport: buildSupportReport,
      showSupportReport,
      getState: () => ({
        paused: state.paused,
        seenSize: state.seen.size,
        lockUntilMs: state.lockUntilMs,
        lastClickAtMs: state.lastClickAtMs,
        lastClickLabel: state.lastClickLabel
      }),
      getConfig: () => ({ ...CONFIG })
    };
  }

  function start() {
    exposeDebugApi();

    if (!isHostAllowed()) {
      debugLog("current host is not in enabledHostPatterns; script is inactive", window.location.hostname);
      return;
    }

    ensureStatusNode();
    bindHotkeys();
    seedSeenLinks();

    state.observer = new MutationObserver(() => queueScan("mutation"));
    state.observer.observe(getQueueRoot(), {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "style", "href"]
    });

    state.intervalId = window.setInterval(() => scanQueue("interval"), CONFIG.scanIntervalMs);
    queueScan("init");

    setStatus("monitoring queue", "info");
    debugLog("started", {
      host: window.location.hostname,
      intervalMs: CONFIG.scanIntervalMs
    });
  }

  start();
})();
