Option Explicit

Dim shell, fso, root, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "cmd /c """ & root & "\launch-relay-operator-panel.cmd"""
shell.Run cmd, 0, False
