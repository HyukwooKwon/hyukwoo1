#Requires AutoHotkey v2.0
#SingleInstance Force

args := ParseArgs(A_Args)
debugLogPath := args.Has("debugLog") ? args["debugLog"] : ""

if !args.Has("file")
    ExitApp 11

filePath   := args["file"]
enterCount := args.Has("enter") ? (args["enter"] + 0) : 1
timeoutMs  := args.Has("timeoutMs") ? (args["timeoutMs"] + 0) : 5000
timeoutSec := timeoutMs / 1000.0
resolverShell := args.Has("resolverShell") ? args["resolverShell"] : "pwsh.exe"
clearInput := args.Has("clearInput") && ((args["clearInput"] + 0) != 0)
activateSettleMs := args.Has("activateSettleMs") ? Max(0, args["activateSettleMs"] + 0) : 120
textSettleMs := args.Has("textSettleMs") ? Max(0, args["textSettleMs"] + 0) : 400
inputMode := args.Has("inputMode") ? Trim(StrLower(args["inputMode"]), " `t`r`n") : "sendtext"
submitGuardMs := args.Has("submitGuardMs") ? Max(0, args["submitGuardMs"] + 0) : 0
enterDelayMs := args.Has("enterDelayMs") ? Max(0, args["enterDelayMs"] + 0) : 150
postSubmitDelayMs := args.Has("postSubmitDelayMs") ? Max(0, args["postSubmitDelayMs"] + 0) : 150
submitRetryIntervalMs := args.Has("submitRetryIntervalMs") ? Max(0, args["submitRetryIntervalMs"] + 0) : 1000
requireActiveBeforeEnter := args.Has("requireActiveBeforeEnter") ? ((args["requireActiveBeforeEnter"] + 0) != 0) : true
requireUserIdleBeforeSend := args.Has("requireUserIdleBeforeSend") ? ((args["requireUserIdleBeforeSend"] + 0) != 0) : false
minUserIdleBeforeSendMs := args.Has("minUserIdleBeforeSendMs") ? Max(0, args["minUserIdleBeforeSendMs"] + 0) : 0
visibleBeaconEnabled := args.Has("visibleBeaconEnabled") ? ((args["visibleBeaconEnabled"] + 0) != 0) : false
visibleLabel := args.Has("visibleLabel") ? args["visibleLabel"] : ""
visiblePreHoldMs := args.Has("visiblePreHoldMs") ? Max(0, args["visiblePreHoldMs"] + 0) : 0
visiblePostHoldMs := args.Has("visiblePostHoldMs") ? Max(0, args["visiblePostHoldMs"] + 0) : 0
restorePreviousActive := args.Has("restorePreviousActive") ? ((args["restorePreviousActive"] + 0) != 0) : true
failOnFocusSteal := args.Has("failOnFocusSteal") ? ((args["failOnFocusSteal"] + 0) != 0) : false
submitModes := ParseSubmitModes(args)

target := ResolveTarget(args, resolverShell)

if !FileExist(filePath)
    ExitApp 12

try {
    text := FileRead(filePath, "UTF-8")
}
catch {
    DebugLog("file_read_failed path=" filePath)
    ExitApp 12
}

if (StrLen(text) = 0)
    ExitApp 13

SetTitleMatchMode 3
DetectHiddenWindows False

if (requireUserIdleBeforeSend && minUserIdleBeforeSendMs > 0) {
    idleMs := A_TimeIdlePhysical
    if (idleMs < minUserIdleBeforeSendMs) {
        snapshot := GetActiveWindowSnapshot()
        DebugLog("user_active_hold idleMs=" idleMs " requiredMs=" minUserIdleBeforeSendMs " activeTitle=" snapshot["title"] " activeClass=" snapshot["class"] " activeProcess=" snapshot["process"])
        ExitApp 43
    }
}

if !TargetExists(target, timeoutSec)
    ExitApp 20

try {
    DebugLog("send_begin hwnd=" target["hwnd"] " windowPid=" target["windowPid"] " shellPid=" target["shellPid"] " title=" target["title"])
    SendPayload(target, text, enterCount, clearInput, activateSettleMs, textSettleMs, inputMode, submitGuardMs, enterDelayMs, postSubmitDelayMs, requireActiveBeforeEnter, submitModes, submitRetryIntervalMs, visibleBeaconEnabled, visibleLabel, visiblePreHoldMs, visiblePostHoldMs, restorePreviousActive, failOnFocusSteal)
    DebugLog("send_complete")
}
catch as err {
    DebugLog("send_exception message=" err.Message " what=" err.What " line=" err.Line " extra=" err.Extra)
    ExitApp 40
}

ExitApp 0

ResolveTarget(args, resolverShell) {
    target := Map("hwnd", "", "windowPid", "", "shellPid", "", "title", "")

    if args.Has("hwnd")
        target["hwnd"] := args["hwnd"]
    if args.Has("windowPid")
        target["windowPid"] := args["windowPid"]
    if args.Has("shellPid")
        target["shellPid"] := args["shellPid"]
    if args.Has("pid") && target["windowPid"] = ""
        target["windowPid"] := args["pid"]
    if args.Has("title")
        target["title"] := args["title"]

    if args.Has("runtime") && args.Has("targetId") {
        runtimeTarget := LookupRuntimeTarget(args["runtime"], args["targetId"], resolverShell)
        if (runtimeTarget["hwnd"] != "")
            target["hwnd"] := runtimeTarget["hwnd"]
        if (runtimeTarget["windowPid"] != "")
            target["windowPid"] := runtimeTarget["windowPid"]
        if (runtimeTarget["shellPid"] != "")
            target["shellPid"] := runtimeTarget["shellPid"]
        if (runtimeTarget["title"] != "")
            target["title"] := runtimeTarget["title"]
    }

    if (target["hwnd"] = "" && target["windowPid"] = "" && target["shellPid"] = "" && target["title"] = "")
        ExitApp 10

    return target
}

LookupRuntimeTarget(runtimePath, targetId, resolverShell) {
    resolverPath := GetResolverScriptPath()
    if (resolverPath = "")
        ExitApp 15

    shellExe := ResolveResolverShell(resolverShell)
    command := '"' shellExe '" -NoProfile -ExecutionPolicy Bypass -File "' resolverPath '" -RuntimePath "' runtimePath '" -TargetId "' targetId '"'
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(command)
    stdout := Trim(exec.StdOut.ReadAll(), "`r`n ")
    exec.StdErr.ReadAll()

    if (exec.ExitCode != 0)
        ExitApp 15

    parts := StrSplit(stdout, "|")
    result := Map("hwnd", "", "windowPid", "", "shellPid", "", "title", "")

    if (parts.Length >= 1)
        result["hwnd"] := parts[1]
    if (parts.Length >= 2)
        result["windowPid"] := parts[2]
    if (parts.Length >= 3)
        result["shellPid"] := parts[3]
    if (parts.Length >= 4)
        result["title"] := parts[4]

    return result
}

ResolveResolverShell(resolverShell) {
    if (resolverShell != "")
        return resolverShell

    if FileExist(A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe")
        return A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"

    return "powershell.exe"
}

GetResolverScriptPath() {
    candidates := [
        A_ScriptDir "\Resolve-SendTarget.ps1",
        A_ScriptDir "\sender\Resolve-SendTarget.ps1"
    ]

    for candidate in candidates {
        if FileExist(candidate)
            return candidate
    }

    return ""
}

TargetExists(target, timeoutSec) {
    startTick := A_TickCount
    timeoutMs := Round(timeoutSec * 1000)

    while ((A_TickCount - startTick) <= timeoutMs) {
        if ResolveWinRef(target) != ""
            return true
        Sleep 150
    }

    return false
}

ResolveWinRef(target) {
    if (target["hwnd"] != "" && WinExist("ahk_id " target["hwnd"]))
        return "ahk_id " target["hwnd"]

    if (target["windowPid"] != "") {
        pidHwnd := WinExist("ahk_pid " target["windowPid"])
        if pidHwnd
            return "ahk_id " pidHwnd
    }

    if (target["shellPid"] != "") {
        pidHwnd := WinExist("ahk_pid " target["shellPid"])
        if pidHwnd
            return "ahk_id " pidHwnd
    }

    if (target["title"] != "" && WinExist(target["title"]))
        return target["title"]

    return ""
}

EnsureWindowActive(winRef, isTerminalHosted, contextLabel, failOnFocusSteal := false, attemptCount := 3, settleMs := 250) {
    if WinActive(winRef)
        return true

    if (failOnFocusSteal) {
        Loop attemptCount {
            DebugLogWindowState(contextLabel "_focus_steal_reactivate try=" A_Index "/" attemptCount, winRef)
            try WinActivate winRef
            if (settleMs > 0)
                Sleep settleMs
            if WinActive(winRef) {
                DebugLogWindowState(contextLabel "_focus_steal_recovered try=" A_Index "/" attemptCount, winRef)
                return true
            }
        }

        DebugLogWindowState(contextLabel "_focus_stolen_hard_fail", winRef)
        return false
    }

    Loop attemptCount {
        DebugLogWindowState(contextLabel "_refocus_attempt try=" A_Index "/" attemptCount, winRef)
        try WinActivate winRef
        if (settleMs > 0)
            Sleep settleMs
        if WinActive(winRef) {
            DebugLogWindowState(contextLabel "_refocus_restored try=" A_Index "/" attemptCount, winRef)
            return true
        }
    }

    if (isTerminalHosted) {
        DebugLogWindowState("terminal_focus_lost context=" contextLabel, winRef)
    } else {
        DebugLogWindowState("control_focus_lost context=" contextLabel, winRef)
    }

    return false
}

SendPayload(target, text, enterCount, clearInput := false, activateSettleMs := 120, textSettleMs := 400, inputMode := "sendtext", submitGuardMs := 0, enterDelayMs := 150, postSubmitDelayMs := 150, requireActiveBeforeEnter := true, submitModes := "", submitRetryIntervalMs := 1000, visibleBeaconEnabled := false, visibleLabel := "", visiblePreHoldMs := 0, visiblePostHoldMs := 0, restorePreviousActive := true, failOnFocusSteal := false) {
    winRef := ResolveWinRef(target)
    if (winRef = "")
        ExitApp 20

    visibleBaseTitle := ResolveVisibleBaseTitle(target, winRef)

    if IsTerminalHostedWindow(winRef) {
        previousActive := WinExist("A")
        DebugLog("terminal_activate ref=" winRef " previousActive=" previousActive)
        if !ActivateWindowWithRetry(winRef, "terminal_initial_activate")
            ExitApp 41

        if (visibleBeaconEnabled) {
            SetVisibleBeaconTitle(winRef, visibleBaseTitle, visibleLabel, "SENDING")
        }
        DebugLogWindowState("terminal_active_ready", winRef)

        if (activateSettleMs > 0)
            Sleep activateSettleMs

        if (visibleBeaconEnabled && visiblePreHoldMs > 0) {
            DebugLogWindowState("visible_pre_hold_begin ms=" visiblePreHoldMs, winRef)
            Sleep visiblePreHoldMs
            DebugLogWindowState("visible_pre_hold_complete ms=" visiblePreHoldMs, winRef)
        }

        if !EnsureWindowActive(winRef, true, "text_pre_clear", failOnFocusSteal)
            ExitApp 42

        if clearInput {
            ClearTerminalInput(winRef)
        }

        if !EnsureWindowActive(winRef, true, "text_pre_paste", failOnFocusSteal)
            ExitApp 42

        terminalInputMode := NormalizeTerminalInputMode(inputMode)
        DebugLog("terminal_input_mode mode=" terminalInputMode)
        SendTerminalPayload(terminalInputMode, text)

        if (textSettleMs > 0) {
            DebugLog("terminal_settle ms=" textSettleMs)
            Sleep textSettleMs
        }

        SubmitPayload(winRef, true, enterCount, submitGuardMs, enterDelayMs, postSubmitDelayMs, requireActiveBeforeEnter, submitModes, submitRetryIntervalMs, visibleBeaconEnabled, visibleBaseTitle, visibleLabel, visiblePostHoldMs, failOnFocusSteal)

        if (restorePreviousActive && previousActive && previousActive != WinExist(winRef)) {
            try {
                DebugLog("terminal_restore previousActive=" previousActive)
                WinActivate "ahk_id " previousActive
            }
            catch as restoreErr {
                DebugLog("terminal_restore_failed previousActive=" previousActive " message=" restoreErr.Message " line=" restoreErr.Line)
            }
        } else if (!restorePreviousActive) {
            DebugLog("terminal_restore_skipped restorePreviousActive=0")
        }
    } else {
        if clearInput {
            ClearControlInput(winRef)
        }

        DebugLog("control_sendtext ref=" winRef)
        ControlSendText text, , winRef

        if (textSettleMs > 0) {
            DebugLog("control_settle ms=" textSettleMs)
            Sleep textSettleMs
        }

        SubmitPayload(winRef, false, enterCount, submitGuardMs, enterDelayMs, postSubmitDelayMs, requireActiveBeforeEnter, submitModes, submitRetryIntervalMs, visibleBeaconEnabled, visibleBaseTitle, visibleLabel, visiblePostHoldMs, failOnFocusSteal)
    }
}

ActivateWindowWithRetry(winRef, contextLabel, attemptCount := 4, waitSeconds := 0.75) {
    Loop attemptCount {
        DebugLogWindowState(contextLabel "_attempt try=" A_Index "/" attemptCount, winRef)
        try WinActivate winRef
        if WinWaitActive(winRef, , waitSeconds) {
            DebugLogWindowState(contextLabel "_active try=" A_Index "/" attemptCount, winRef)
            return true
        }
    }

    DebugLogWindowState(contextLabel "_failed", winRef)
    return false
}

SubmitPayload(winRef, isTerminalHosted, enterCount, submitGuardMs, enterDelayMs, postSubmitDelayMs, requireActiveBeforeEnter, submitModes, submitRetryIntervalMs, visibleBeaconEnabled := false, visibleBaseTitle := "", visibleLabel := "", visiblePostHoldMs := 0, failOnFocusSteal := false) {
    modes := NormalizeSubmitModes(submitModes)
    selectedModes := []

    if (enterCount <= 0)
        return

    if (modes.Length >= 1) {
        selectedModes.Push(modes[1])
    }
    if (modes.Length > 1) {
        DebugLogWindowState("submit_mode_clamped selected=" selectedModes[1] " configured=" JoinModesForLog(modes), winRef)
    }
    modes := selectedModes

    if (submitGuardMs > 0) {
        DebugLogWindowState("submit_guard_begin ms=" submitGuardMs, winRef)
        Sleep submitGuardMs
        DebugLogWindowState("submit_guard_complete ms=" submitGuardMs, winRef)
    }

    for index, mode in modes {
        DebugLogWindowState("submit_precheck mode=" mode " index=" index "/" modes.Length, winRef)
        if (requireActiveBeforeEnter) {
            if !WinActive(winRef) {
                if !EnsureWindowActive(winRef, isTerminalHosted, "submit mode=" mode " index=" index "/" modes.Length, failOnFocusSteal) {
                    ExitApp 42
                }
            }
        }

        Loop enterCount {
            if (enterDelayMs > 0)
                Sleep enterDelayMs
            if (requireActiveBeforeEnter) {
                if !WinActive(winRef) {
                    if !EnsureWindowActive(winRef, isTerminalHosted, "submit mode=" mode " index=" index "/" modes.Length, failOnFocusSteal) {
                        ExitApp 42
                    }
                }
            }
            DebugLogWindowState("submit_attempt mode=" mode " index=" index "/" modes.Length, winRef)
            DispatchSubmitMode(winRef, isTerminalHosted, mode)
            DebugLogWindowState("submit_after_dispatch mode=" mode " index=" index "/" modes.Length, winRef)
        }

        if (index < modes.Length && submitRetryIntervalMs > 0) {
            Sleep submitRetryIntervalMs
            DebugLogWindowState("submit_retry_wait_complete nextModeIndex=" (index + 1) "/" modes.Length, winRef)
        }
    }

    if (visibleBeaconEnabled) {
        SetVisibleBeaconTitle(winRef, visibleBaseTitle, visibleLabel, "RUNNING")
        if (visiblePostHoldMs > 0) {
            DebugLogWindowState("visible_post_hold_begin ms=" visiblePostHoldMs, winRef)
            Sleep visiblePostHoldMs
            DebugLogWindowState("visible_post_hold_complete ms=" visiblePostHoldMs, winRef)
        }
    }

    if (postSubmitDelayMs > 0)
        Sleep postSubmitDelayMs

    DebugLogWindowState("submit_complete", winRef)
}

JoinModesForLog(modes) {
    if (modes.Length = 0)
        return ""

    text := ""
    for index, mode in modes {
        if (index > 1)
            text .= ">"
        text .= mode
    }
    return text
}

NormalizeTerminalInputMode(value) {
    normalized := Trim(StrLower(value), " `t`r`n")
    switch normalized {
        case "paste":
            return "paste"
        case "sendtext":
            return "sendtext"
        default:
            return "sendtext"
    }
}

SendTerminalPayload(mode, text) {
    switch mode {
        case "paste":
            SendTerminalPayloadViaClipboard(text)
        case "sendtext":
            DebugLog("terminal_sendtext")
            SendText text
        default:
            DebugLog("terminal_input_mode_fallback mode=" mode)
            DebugLog("terminal_sendtext")
            SendText text
    }
}

SendTerminalPayloadViaClipboard(text) {
    savedClipboard := ""
    hasSavedClipboard := false

    try {
        savedClipboard := ClipboardAll()
        hasSavedClipboard := true
    }
    catch {
        hasSavedClipboard := false
    }

    try {
        A_Clipboard := ""
        Sleep 40
        A_Clipboard := text
        if !ClipWait(1) {
            DebugLog("terminal_paste_clipwait_failed")
            throw Error("clipboard_not_ready_for_terminal_paste")
        }

        payloadBytes := Max(0, StrPut(text, "UTF-8") - 1)
        DebugLog("terminal_paste bytes=" payloadBytes)
        SendEvent "^v"
        Sleep 120
    }
    finally {
        try {
            if (hasSavedClipboard) {
                A_Clipboard := savedClipboard
            } else {
                A_Clipboard := ""
            }
        }
        catch as restoreErr {
            DebugLog("terminal_paste_restore_failed message=" restoreErr.Message " line=" restoreErr.Line)
        }
    }
}

DispatchSubmitMode(winRef, isTerminalHosted, mode) {
    switch mode {
        case "enter":
            if (isTerminalHosted) {
                SendEvent "{Enter}"
            } else {
                ControlSend "{Enter}", , winRef
            }
        case "ctrl_enter":
            if (isTerminalHosted) {
                SendEvent "{Ctrl down}{Enter}{Ctrl up}"
            } else {
                ControlSend "{Ctrl down}{Enter}{Ctrl up}", , winRef
            }
        default:
            DebugLog("unsupported_submit_mode mode=" mode)
            ExitApp 44
    }
}

NormalizeSubmitModes(value) {
    if !IsObject(value) {
        return ["enter"]
    }

    result := []
    for _, item in value {
        normalized := Trim(StrLower(item), " `t`r`n")
        if (normalized != "")
            result.Push(normalized)
    }

    if (result.Length = 0)
        result.Push("enter")

    return result
}

ParseSubmitModes(args) {
    raw := ""
    if args.Has("submitModes") {
        raw := args["submitModes"]
    } else if args.Has("submitMode") {
        raw := args["submitMode"]
    }

    if (Trim(raw, " `t`r`n") = "")
        return ["enter"]

    items := StrSplit(raw, ",")
    result := []
    for _, item in items {
        normalized := Trim(StrLower(item), " `t`r`n")
        if (normalized != "")
            result.Push(normalized)
    }

    if (result.Length = 0)
        result.Push("enter")

    return result
}

ResolveVisibleBaseTitle(target, winRef) {
    configuredTitle := target.Has("title") ? target["title"] : ""
    if (Trim(configuredTitle, " `t`r`n") != "")
        return NormalizeVisibleBaseTitle(configuredTitle)

    try {
        currentTitle := WinGetTitle(winRef)
        if (Trim(currentTitle, " `t`r`n") != "")
            return NormalizeVisibleBaseTitle(currentTitle)
    }
    catch {
    }

    return "Relay Target"
}

NormalizeVisibleBaseTitle(title) {
    return Trim(RegExReplace(title, "\s+\[VISIBLE [^\]]+\]$"), " `t`r`n")
}

BuildVisibleBeaconTitle(baseTitle, visibleLabel, phase) {
    normalizedBaseTitle := NormalizeVisibleBaseTitle(baseTitle)
    if (normalizedBaseTitle = "")
        normalizedBaseTitle := "Relay Target"

    marker := phase
    if (Trim(visibleLabel, " `t`r`n") != "")
        marker := visibleLabel " " phase

    return normalizedBaseTitle " [VISIBLE " marker "]"
}

SetVisibleBeaconTitle(winRef, baseTitle, visibleLabel, phase) {
    beaconTitle := BuildVisibleBeaconTitle(baseTitle, visibleLabel, phase)
    try {
        WinSetTitle beaconTitle, winRef
        DebugLogWindowState("visible_beacon phase=" phase " title=" beaconTitle, winRef)
    }
    catch as err {
        DebugLog("visible_beacon_failed phase=" phase " title=" beaconTitle " message=" err.Message " line=" err.Line)
    }
}

GetActiveWindowSnapshot() {
    snapshot := Map("title", "", "class", "", "process", "")
    try {
        activeRef := WinExist("A")
        if !activeRef
            return snapshot

        snapshot["title"] := WinGetTitle("ahk_id " activeRef)
        snapshot["class"] := WinGetClass("ahk_id " activeRef)
        snapshot["process"] := WinGetProcessName("ahk_id " activeRef)
    }
    catch {
    }

    return snapshot
}

GetWindowSnapshot(winRef) {
    snapshot := Map("title", "", "class", "", "process", "", "hwnd", "")
    try {
        resolvedRef := WinExist(winRef)
        if !resolvedRef
            return snapshot

        snapshot["hwnd"] := resolvedRef
        snapshot["title"] := WinGetTitle("ahk_id " resolvedRef)
        snapshot["class"] := WinGetClass("ahk_id " resolvedRef)
        snapshot["process"] := WinGetProcessName("ahk_id " resolvedRef)
    }
    catch {
    }

    return snapshot
}

FormatWindowSnapshot(snapshot) {
    title := snapshot.Has("title") ? snapshot["title"] : ""
    className := snapshot.Has("class") ? snapshot["class"] : ""
    processName := snapshot.Has("process") ? snapshot["process"] : ""
    hwnd := snapshot.Has("hwnd") ? snapshot["hwnd"] : ""

    return "title=" title " class=" className " process=" processName " hwnd=" hwnd
}

DebugLogWindowState(prefix, winRef) {
    activeSnapshot := GetActiveWindowSnapshot()
    targetSnapshot := GetWindowSnapshot(winRef)
    isActive := 0

    try {
        isActive := WinActive(winRef) ? 1 : 0
    }
    catch {
    }

    DebugLog(prefix " active={" FormatWindowSnapshot(activeSnapshot) "} target={" FormatWindowSnapshot(targetSnapshot) "} winActive=" isActive)
}

ClearTerminalInput(winRef) {
    DebugLog("terminal_clear_begin ref=" winRef)
    Send "{Esc}"
    Sleep 60
    Send "^a"
    Sleep 60
    Send "{Backspace}"
    Sleep 60
    Send "{End}"
    Sleep 60

    Loop 200 {
        Send "{Backspace}"
    }

    DebugLog("terminal_clear_end")
}

ClearControlInput(winRef) {
    DebugLog("control_clear_begin ref=" winRef)
    ControlSend "{Esc}", , winRef
    Sleep 60
    ControlSend "^a", , winRef
    Sleep 60
    ControlSend "{Backspace}", , winRef
    Sleep 60
    ControlSend "{End}", , winRef
    Sleep 60

    Loop 200 {
        ControlSend "{Backspace}", , winRef
    }

    DebugLog("control_clear_end")
}

IsTerminalHostedWindow(winRef) {
    try {
        className := WinGetClass(winRef)
        return (className = "CASCADIA_HOSTING_WINDOW_CLASS")
    }
    catch {
        return false
    }
}

ParseArgs(args) {
    m := Map()
    i := 1

    while (i <= args.Length) {
        key := args[i]

        if (SubStr(key, 1, 2) != "--")
            ExitApp 90

        key := SubStr(key, 3)
        i += 1

        if (i > args.Length)
            ExitApp 91

        m[key] := args[i]
        i += 1
    }

    return m
}

DebugLog(message) {
    global debugLogPath
    if (debugLogPath = "")
        return

    try {
        FileAppend("[" A_Now "] " message "`r`n", debugLogPath, "UTF-8")
    }
}
