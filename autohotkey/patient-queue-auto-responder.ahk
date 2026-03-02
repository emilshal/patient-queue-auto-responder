#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 1
Persistent

CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")
SetMouseDelay(-1)
SetWinDelay(0)

global ConfigPath := A_ScriptDir "\\config.ini"
global LogPath := A_ScriptDir "\\patient-queue-ahk.log"
global FallbackLogPath := A_ScriptDir "\\patient-queue-ahk-" . DllCall("GetCurrentProcessId", "UInt") . ".log"

global State := {
    running: false,
    consecutiveHits: 0,
    awaitClear: false,
    clearMisses: 0,
    lastHitX: 0,
    lastHitY: 0,
    lastFoundColor: 0,
    lastDetectionTick: 0,
    lastClickTick: 0,
    lastSearchErrorTick: 0,
    totalClicks: 0,
    totalDetections: 0,
    statusOpen: false,
    statusLastShownTick: 0
}

global AppMutexHandle := AcquireAppMutex()
if !AppMutexHandle {
    MsgBox("Another Patient Queue Auto Responder instance is already running.`n`nClose other tray icons/scripts first, then start again.", "Patient Queue Auto Responder")
    ExitApp()
}

OnExit((*) => ReleaseAppMutex())

global Cfg := LoadConfig()
InitTray()

if !IsConfigValid() {
    MsgBox("First-time setup is required. Keep your DialCare queue visible, then follow the calibration prompts.", "Patient Queue Auto Responder")
    try {
        SetupWizard()
    } catch Error as err {
        MsgBox("Setup canceled. Run setup again with F7.", "Patient Queue Auto Responder")
    }
}

if IsConfigValid() {
    StartMonitoring("startup")
}

F6::{
    ToggleRunning()
}

F7::{
    try {
        wasRunning := State.running
        if wasRunning {
            StopMonitoring("recalibrate")
        }

        SetupWizard()

        if wasRunning {
            StartMonitoring("recalibrate")
        }
    } catch Error as err {
        MsgBox("Setup canceled.", "Patient Queue Auto Responder")
    }
}

F8::{
    ShowStatus()
}

F9::{
    ShowHelp()
}

F10::{
    RunSyntheticTest()
}

^+t::{
    RunSyntheticTest()
}

Esc:: {
    ; Safety stop hotkey.
    if State.running {
        StopMonitoring("escape")
    }
}

ToggleRunning() {
    global State

    if State.running {
        StopMonitoring("manual")
    } else {
        if !IsConfigValid() {
            MsgBox("Configuration is missing. Press F7 to run setup.", "Patient Queue Auto Responder")
            return
        }
        StartMonitoring("manual")
    }
}

StartMonitoring(reason := "manual") {
    global State, Cfg

    if !IsConfigValid() {
        MsgBox("Cannot start: setup is incomplete. Press F7.", "Patient Queue Auto Responder")
        return
    }

    State.running := true
    State.consecutiveHits := 0
    State.awaitClear := false
    State.clearMisses := 0

    SetTimer(MonitorTick, Cfg.pollMs)
    SetTrayStateTip("RUNNING")
    LogEvent("monitor-start | reason=" . reason)
}

StopMonitoring(reason := "manual") {
    global State

    State.running := false
    State.consecutiveHits := 0
    State.awaitClear := false
    State.clearMisses := 0

    SetTimer(MonitorTick, 0)
    SetTrayStateTip("PAUSED")
    LogEvent("monitor-stop | reason=" . reason)
}

MonitorTick() {
    global State, Cfg

    if !State.running {
        return
    }

    if !QueueWindowGuardPasses() {
        State.consecutiveHits := 0
        return
    }

    found := FindCandidate(&fx, &fy, &color)

    if State.awaitClear {
        if found {
            State.clearMisses := 0
            return
        }

        State.clearMisses += 1
        if State.clearMisses >= Cfg.clearMissFrames {
            State.awaitClear := false
            State.clearMisses := 0
            LogEvent("re-armed")
        }
        return
    }

    if !found {
        State.consecutiveHits := 0
        return
    }

    if Cfg.requireDetectedNearClickY {
        if Abs(fy - Cfg.clickY) > Cfg.detectYTolerancePx {
            State.consecutiveHits := 0
            return
        }
    }

    prevX := State.lastHitX
    prevY := State.lastHitY

    State.totalDetections += 1
    State.lastDetectionTick := A_TickCount
    State.lastHitX := fx
    State.lastHitY := fy
    State.lastFoundColor := color

    if Abs(fx - prevX) <= 6 && Abs(fy - prevY) <= 6 {
        State.consecutiveHits += 1
    } else {
        State.consecutiveHits := 1
    }

    if State.consecutiveHits < Cfg.requiredConsecutiveHits {
        return
    }

    if (A_TickCount - State.lastClickTick) < Cfg.clickCooldownMs {
        return
    }

    tx := Cfg.useDetectedPixelClick ? fx : Cfg.clickX
    ty := Cfg.useDetectedPixelClick ? fy : Cfg.clickY

    SendEvent("{Click " . tx . " " . ty . "}")

    State.lastClickTick := A_TickCount
    State.totalClicks += 1
    State.consecutiveHits := 0
    State.awaitClear := true
    State.clearMisses := 0

    if Cfg.beepOnClick {
        SoundBeep(1100, 35)
    }

    LogEvent("clicked | x=" . tx . " | y=" . ty . " | detectColor=" . Format("0x{:06X}", color))
    FlashTip("Clicked patient link", 1000)
}

QueueWindowGuardPasses() {
    global Cfg

    if !Cfg.requireQueueWindowActive {
        return true
    }

    if !WinActive("ahk_exe chrome.exe") {
        return false
    }

    title := WinGetTitle("A")
    if (Cfg.queueTitleHint = "") {
        return true
    }

    return InStr(StrLower(title), StrLower(Cfg.queueTitleHint)) > 0
}

FindCandidate(&outX, &outY, &outColor) {
    global Cfg, State

    outX := 0
    outY := 0
    outColor := 0

    if !GetSafeSearchRect(&x1, &y1, &x2, &y2) {
        if (A_TickCount - State.lastSearchErrorTick) > 4000 {
            State.lastSearchErrorTick := A_TickCount
            LogEvent("search-rect-invalid | run setup with F7")
        }
        return false
    }

    colors := ParseColorCsv(Cfg.linkColorCsv)
    for _, color in colors {
        try {
            if PixelSearch(&px, &py, x1, y1, x2, y2, color, Cfg.colorVariation) {
                outX := px
                outY := py
                outColor := color
                return true
            }
        } catch Error as err {
            if (A_TickCount - State.lastSearchErrorTick) > 4000 {
                State.lastSearchErrorTick := A_TickCount
                LogEvent("pixelsearch-error | " . err.Message)
            }
            ; Ignore search exceptions and continue trying other colors.
        }
    }

    return false
}

SetupWizard() {
    global Cfg

    ShowHelp()

    p1 := CapturePoint("Step 1/4: Move mouse to TOP-LEFT of the scan area (Client/Patient Name column), then press F8. Esc cancels.")
    p2 := CapturePoint("Step 2/4: Move mouse to BOTTOM-RIGHT of the same scan area, then press F8.")
    clickPt := CapturePoint("Step 3/4: Move mouse over where patient name link should be clicked (first row), then press F8.")

    c := CaptureColorOptional("Step 4/4: Hover a BLUE patient/client name link and press F8.`nIf no blue link is visible now, press F9 to use defaults.")

    Cfg.scanX1 := Min(p1.x, p2.x)
    Cfg.scanY1 := Min(p1.y, p2.y)
    Cfg.scanX2 := Max(p1.x, p2.x)
    Cfg.scanY2 := Max(p1.y, p2.y)
    Cfg.clickX := clickPt.x
    Cfg.clickY := clickPt.y

    if c != 0 {
        if IsLikelyBlueColor(c) {
            Cfg.linkColorCsv := Format("0x{:06X}", c)
            LogEvent("setup-color-sampled | value=" . Format("0x{:06X}", c))
        } else {
            Cfg.linkColorCsv := GetDefaultLinkColorCsv()
            LogEvent("setup-color-rejected | sampled=" . Format("0x{:06X}", c) . " | using-default-blue-set")
            MsgBox("Sampled color was not a likely blue link color.`nUsing default blue color set instead.", "Patient Queue Auto Responder")
        }
    } else {
        Cfg.linkColorCsv := GetDefaultLinkColorCsv()
        LogEvent("setup-color-defaults-used")
    }

    NormalizeScanArea()
    SaveConfig()
    LogEvent("setup-complete")
    FlashTip("Setup saved", 1500)
}

CapturePoint(prompt) {
    ToolTip(prompt)
    Loop {
        if GetKeyState("Esc", "P") {
            ToolTip()
            KeyWait("Esc")
            throw Error("setup canceled")
        }

        if GetKeyState("F8", "P") {
            MouseGetPos(&x, &y)
            ToolTip()
            KeyWait("F8")
            SoundBeep(900, 50)
            return {x: x, y: y}
        }

        Sleep(20)
    }
}

CaptureColorOptional(prompt) {
    ToolTip(prompt)
    Loop {
        if GetKeyState("Esc", "P") {
            ToolTip()
            KeyWait("Esc")
            throw Error("setup canceled")
        }

        if GetKeyState("F8", "P") {
            MouseGetPos(&x, &y)
            color := PixelGetColor(x, y, "RGB")
            ToolTip()
            KeyWait("F8")
            SoundBeep(1000, 60)
            return color
        }

        if GetKeyState("F9", "P") {
            ToolTip()
            KeyWait("F9")
            SoundBeep(700, 40)
            return 0
        }

        Sleep(20)
    }
}

LoadConfig() {
    global ConfigPath

    cfg := {
        scanX1: ToInt(IniRead(ConfigPath, "Scan", "X1", "0"), 0),
        scanY1: ToInt(IniRead(ConfigPath, "Scan", "Y1", "0"), 0),
        scanX2: ToInt(IniRead(ConfigPath, "Scan", "X2", "0"), 0),
        scanY2: ToInt(IniRead(ConfigPath, "Scan", "Y2", "0"), 0),
        clickX: ToInt(IniRead(ConfigPath, "Click", "X", "0"), 0),
        clickY: ToInt(IniRead(ConfigPath, "Click", "Y", "0"), 0),
        linkColorCsv: IniRead(ConfigPath, "Detect", "LinkColors", GetDefaultLinkColorCsv()),
        colorVariation: ToInt(IniRead(ConfigPath, "Detect", "ColorVariation", "58"), 58),
        requiredConsecutiveHits: ToInt(IniRead(ConfigPath, "Detect", "RequiredConsecutiveHits", "2"), 2),
        clickCooldownMs: ToInt(IniRead(ConfigPath, "Detect", "ClickCooldownMs", "1200"), 1200),
        clearMissFrames: ToInt(IniRead(ConfigPath, "Detect", "ClearMissFrames", "4"), 4),
        pollMs: ToInt(IniRead(ConfigPath, "Detect", "PollMs", "25"), 25),
        useDetectedPixelClick: ToBool(IniRead(ConfigPath, "Detect", "UseDetectedPixelClick", "1"), true),
        beepOnClick: ToBool(IniRead(ConfigPath, "Detect", "BeepOnClick", "1"), true),
        requireQueueWindowActive: ToBool(IniRead(ConfigPath, "Guard", "RequireQueueWindowActive", "1"), true),
        queueTitleHint: IniRead(ConfigPath, "Guard", "QueueTitleHint", "DialCare"),
        requireDetectedNearClickY: ToBool(IniRead(ConfigPath, "Guard", "RequireDetectedNearClickY", "1"), true),
        detectYTolerancePx: ToInt(IniRead(ConfigPath, "Guard", "DetectYTolerancePx", "24"), 24)
    }

    x1 := cfg.scanX1
    y1 := cfg.scanY1
    x2 := cfg.scanX2
    y2 := cfg.scanY2
    cfg.scanX1 := Min(x1, x2)
    cfg.scanY1 := Min(y1, y2)
    cfg.scanX2 := Max(x1, x2)
    cfg.scanY2 := Max(y1, y2)

    return cfg
}

NormalizeScanArea() {
    global Cfg

    left := Cfg.scanX1
    top := Cfg.scanY1
    right := Cfg.scanX2
    bottom := Cfg.scanY2
    ClampRectToVirtualScreen(&left, &top, &right, &bottom)

    Cfg.scanX1 := left
    Cfg.scanY1 := top
    Cfg.scanX2 := right
    Cfg.scanY2 := bottom
}

GetSafeSearchRect(&x1, &y1, &x2, &y2) {
    global Cfg

    x1 := Cfg.scanX1
    y1 := Cfg.scanY1
    x2 := Cfg.scanX2
    y2 := Cfg.scanY2
    ClampRectToVirtualScreen(&x1, &y1, &x2, &y2)

    if (x2 <= x1 || y2 <= y1) {
        return false
    }

    return true
}

ClampRectToVirtualScreen(&x1, &y1, &x2, &y2) {
    vx := DllCall("GetSystemMetrics", "Int", 76, "Int")
    vy := DllCall("GetSystemMetrics", "Int", 77, "Int")
    vw := DllCall("GetSystemMetrics", "Int", 78, "Int")
    vh := DllCall("GetSystemMetrics", "Int", 79, "Int")

    minX := vx
    minY := vy
    maxX := vx + vw - 1
    maxY := vy + vh - 1

    if x1 < minX {
        x1 := minX
    }
    if y1 < minY {
        y1 := minY
    }
    if x2 > maxX {
        x2 := maxX
    }
    if y2 > maxY {
        y2 := maxY
    }

    if x2 < x1 {
        x2 := x1
    }
    if y2 < y1 {
        y2 := y1
    }
}

SaveConfig() {
    global Cfg, ConfigPath

    IniWrite(Cfg.scanX1, ConfigPath, "Scan", "X1")
    IniWrite(Cfg.scanY1, ConfigPath, "Scan", "Y1")
    IniWrite(Cfg.scanX2, ConfigPath, "Scan", "X2")
    IniWrite(Cfg.scanY2, ConfigPath, "Scan", "Y2")

    IniWrite(Cfg.clickX, ConfigPath, "Click", "X")
    IniWrite(Cfg.clickY, ConfigPath, "Click", "Y")

    IniWrite(Cfg.linkColorCsv, ConfigPath, "Detect", "LinkColors")
    IniWrite(Cfg.colorVariation, ConfigPath, "Detect", "ColorVariation")
    IniWrite(Cfg.requiredConsecutiveHits, ConfigPath, "Detect", "RequiredConsecutiveHits")
    IniWrite(Cfg.clickCooldownMs, ConfigPath, "Detect", "ClickCooldownMs")
    IniWrite(Cfg.clearMissFrames, ConfigPath, "Detect", "ClearMissFrames")
    IniWrite(Cfg.pollMs, ConfigPath, "Detect", "PollMs")
    IniWrite(Cfg.useDetectedPixelClick ? 1 : 0, ConfigPath, "Detect", "UseDetectedPixelClick")
    IniWrite(Cfg.beepOnClick ? 1 : 0, ConfigPath, "Detect", "BeepOnClick")

    IniWrite(Cfg.requireQueueWindowActive ? 1 : 0, ConfigPath, "Guard", "RequireQueueWindowActive")
    IniWrite(Cfg.queueTitleHint, ConfigPath, "Guard", "QueueTitleHint")
    IniWrite(Cfg.requireDetectedNearClickY ? 1 : 0, ConfigPath, "Guard", "RequireDetectedNearClickY")
    IniWrite(Cfg.detectYTolerancePx, ConfigPath, "Guard", "DetectYTolerancePx")
}

IsConfigValid() {
    global Cfg

    if (Cfg.scanX2 <= Cfg.scanX1 || Cfg.scanY2 <= Cfg.scanY1) {
        return false
    }

    if (Cfg.clickX <= 0 || Cfg.clickY <= 0) {
        return false
    }

    return true
}

ParseColorCsv(csv) {
    colors := []
    for _, token in StrSplit(csv, ",") {
        token := Trim(token)
        if token = "" {
            continue
        }

        try {
            c := token + 0
            if IsLikelyBlueColor(c) {
                colors.Push(c)
            }
        } catch Error as err {
            ; Skip invalid color tokens.
        }
    }

    if colors.Length = 0 {
        colors.Push(0x0078D7)
        colors.Push(0x1E90FF)
        colors.Push(0x0B72B5)
        colors.Push(0x0096C7)
    }

    return colors
}

GetDefaultLinkColorCsv() {
    return "0x0078D7,0x1E90FF,0x0B72B5,0x0096C7"
}

IsLikelyBlueColor(color) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF

    maxV := Max(r, g, b)
    minV := Min(r, g, b)
    chroma := maxV - minV

    ; Reject grays/whites and keep only blue-dominant colors.
    if chroma < 20 {
        return false
    }
    if b < 80 {
        return false
    }
    if b < r {
        return false
    }
    if b < g {
        return false
    }
    if (b - Max(r, g)) < 12 {
        return false
    }

    return true
}

ToInt(value, fallback := 0) {
    try {
        return Round(value + 0)
    } catch Error as err {
        return fallback
    }
}

ToBool(value, fallback := false) {
    v := Trim(value)
    if (v = "1" || StrLower(v) = "true" || StrLower(v) = "yes") {
        return true
    }
    if (v = "0" || StrLower(v) = "false" || StrLower(v) = "no") {
        return false
    }
    return fallback
}

ShowStatus() {
    global State, Cfg

    ; Prevent stacked status dialogs from key repeat or repeated tray clicks.
    if State.statusOpen {
        return
    }

    if (A_TickCount - State.statusLastShownTick) < 700 {
        return
    }

    State.statusOpen := true
    State.statusLastShownTick := A_TickCount
    report := BuildStatusReport()
    try {
        MsgBox(report, "Patient Queue Auto Responder")
    } finally {
        State.statusOpen := false
    }
}

BuildStatusReport() {
    global State, Cfg, LogPath, FallbackLogPath

    runningText := State.running ? "RUNNING" : "PAUSED"
    lastClickAgo := State.lastClickTick > 0 ? (A_TickCount - State.lastClickTick) . " ms ago" : "n/a"
    lastDetectAgo := State.lastDetectionTick > 0 ? (A_TickCount - State.lastDetectionTick) . " ms ago" : "n/a"

    return "Status: " . runningText
        . "`nScan region: (" . Cfg.scanX1 . "," . Cfg.scanY1 . ") -> (" . Cfg.scanX2 . "," . Cfg.scanY2 . ")"
        . "`nClick point: (" . Cfg.clickX . "," . Cfg.clickY . ")"
        . "`nPoll: " . Cfg.pollMs . " ms"
        . "`nColors: " . Cfg.linkColorCsv
        . "`nColor variation: " . Cfg.colorVariation
        . "`nQueue-window guard: " . (Cfg.requireQueueWindowActive ? "ON" : "OFF")
        . "`nQueue title hint: " . Cfg.queueTitleHint
        . "`nY-band guard: " . (Cfg.requireDetectedNearClickY ? ("ON +/-" . Cfg.detectYTolerancePx . "px") : "OFF")
        . "`nConsecutive hits required: " . Cfg.requiredConsecutiveHits
        . "`nClicks: " . State.totalClicks
        . "`nDetections: " . State.totalDetections
        . "`nLast detect: " . lastDetectAgo
        . "`nLast click: " . lastClickAgo
        . "`nLog file: " . LogPath
        . "`nFallback log: " . FallbackLogPath
}

ShowHelp() {
    help := "Quick controls:"
        . "`n- F6: Start/Pause monitoring"
        . "`n- F7: Run setup wizard"
        . "`n- F8: Show status report"
        . "`n- F9: Show this help"
        . "`n- F10: Run synthetic test"
        . "`n- Ctrl+Shift+T: Run synthetic test (alt hotkey)"
        . "`n- Esc: Emergency stop"
        . "`n"
        . "Setup notes:"
        . "`n- Keep DialCare queue visible while running"
        . "`n- Scan area should cover only Client/Patient Name column rows"
        . "`n- Press F8 during setup to capture points"
        . "`n- Press F9 in Step 4 if no blue link is visible"

    MsgBox(help, "Patient Queue Auto Responder")
}

FlashTip(text, durationMs := 1200) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -durationMs)
}

SetTrayStateTip(stateText) {
    A_IconTip := "Patient Queue Auto Responder - " . stateText
}

OpenLog() {
    global LogPath, FallbackLogPath

    if EnsureFileExists(LogPath) {
        Run(LogPath)
        return
    }

    if EnsureFileExists(FallbackLogPath) {
        Run(FallbackLogPath)
        return
    }

    MsgBox("Could not open log file.", "Patient Queue Auto Responder")
}

LogEvent(message) {
    global LogPath, FallbackLogPath

    stamp := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    line := stamp . " | " . message . "`n"

    if TryAppendLine(LogPath, line) {
        return
    }

    TryAppendLine(FallbackLogPath, line)
}

TryAppendLine(path, line, attempts := 4) {
    loop attempts {
        try {
            FileAppend(line, path, "UTF-8")
            return true
        } catch Error as err {
            Sleep(30)
        }
    }

    return false
}

EnsureFileExists(path) {
    if FileExist(path) {
        return true
    }

    try {
        FileAppend("", path, "UTF-8")
        return true
    } catch Error as err {
        return false
    }
}

AcquireAppMutex() {
    ; Blocks multiple copies launched from different folders/names.
    hMutex := DllCall("CreateMutex", "ptr", 0, "int", 1, "str", "PQAR_DialCare_AHK_SingleInstance", "ptr")
    if (hMutex = 0) {
        return 0
    }

    if (A_LastError = 183) {
        DllCall("CloseHandle", "ptr", hMutex)
        return 0
    }

    return hMutex
}

ReleaseAppMutex() {
    global AppMutexHandle

    if !AppMutexHandle {
        return
    }

    try {
        DllCall("ReleaseMutex", "ptr", AppMutexHandle)
    } catch Error as err {
        ; Ignore release failures during shutdown.
    }

    try {
        DllCall("CloseHandle", "ptr", AppMutexHandle)
    } catch Error as err {
        ; Ignore close failures during shutdown.
    }

    AppMutexHandle := 0
}

InitTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Start / Pause (F6)", (*) => ToggleRunning())
    A_TrayMenu.Add("Setup Wizard (F7)", (*) => RunSetupFromTray())
    A_TrayMenu.Add("Show Status (F8)", (*) => ShowStatus())
    A_TrayMenu.Add("Run Synthetic Test (F10 / Ctrl+Shift+T)", (*) => RunSyntheticTest())
    A_TrayMenu.Add("Open Log File", (*) => OpenLog())
    A_TrayMenu.Add("Help (F9)", (*) => ShowHelp())
    A_TrayMenu.Add("Exit", (*) => ExitScript())
    SetTrayStateTip("READY")
}

RunSyntheticTest() {
    global State, Cfg

    if !IsConfigValid() {
        MsgBox("Setup is incomplete. Press F7 first.", "Patient Queue Auto Responder")
        return
    }

    wasRunning := State.running
    if !wasRunning {
        StartMonitoring("synthetic-test")
        Sleep(80)
    }

    baselineClicks := State.totalClicks
    testX := Cfg.scanX1 + 20
    testY := Cfg.scanY1 + 20

    if (testX > Cfg.scanX2 - 20) {
        testX := Cfg.scanX1 + 2
    }
    if (testY > Cfg.scanY2 - 20) {
        testY := Cfg.scanY1 + 2
    }

    testGui := Gui("+AlwaysOnTop -Caption +ToolWindow", "PQAR Synthetic Test")
    testGui.BackColor := "0078D7"
    testGui.SetFont("s10 cFFFFFF", "Segoe UI")
    testGui.AddText("x8 y7 w145 h20 +0x200", "TEST LINK")
    testGui.Show("x" . testX . " y" . testY . " w160 h34 NoActivate")

    Sleep(1400)
    testGui.Destroy()
    Sleep(900)

    passed := (State.totalClicks > baselineClicks)
    LogEvent("synthetic-test | result=" . (passed ? "pass" : "fail"))

    if !wasRunning {
        StopMonitoring("synthetic-test-end")
    }

    if passed {
        MsgBox("Synthetic test PASSED.`nDetection/click pipeline is working.", "Patient Queue Auto Responder")
    } else {
        MsgBox("Synthetic test FAILED.`nTry setup again with F7 and tighten scan area.", "Patient Queue Auto Responder")
    }
}

RunSetupFromTray() {
    global State

    try {
        wasRunning := State.running
        if wasRunning {
            StopMonitoring("recalibrate")
        }

        SetupWizard()

        if wasRunning {
            StartMonitoring("recalibrate")
        }
    } catch Error as err {
        MsgBox("Setup canceled.", "Patient Queue Auto Responder")
    }
}

ExitScript() {
    global State

    if State.running {
        StopMonitoring("exit")
    }
    ReleaseAppMutex()
    ExitApp()
}
