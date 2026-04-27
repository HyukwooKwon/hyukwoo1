Option Explicit

Dim shell, fso, root, launchPath, pairId, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count = 0 Then
    MsgBox "usage: open-preset-headless-pair-drill.vbs pairXX", vbExclamation, "Preset Headless Drill"
    WScript.Quit 64
End If

pairId = WScript.Arguments.Item(0)
root = fso.GetParentFolderName(WScript.ScriptFullName)
launchPath = root & "\launch-preset-headless-pair-drill.cmd"

If Not fso.FileExists(launchPath) Then
    MsgBox "launch-preset-headless-pair-drill.cmd not found: " & launchPath, vbCritical, "Preset Headless Drill"
    WScript.Quit 1
End If

command = "cmd.exe /c """ & launchPath & """ """ & pairId & """"
shell.Run command, 1, False
