Option Explicit

Dim shell, fso, root, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = root & "\open-preset-headless-pair-drill.vbs"
command = "wscript.exe """ & scriptPath & """ ""pair03"""
shell.Run command, 1, False
