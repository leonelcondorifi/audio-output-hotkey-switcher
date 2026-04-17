Option Explicit

Dim shell
Dim fso
Dim scriptPath
Dim scriptDir
Dim listenerPath
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = WScript.ScriptFullName
scriptDir = fso.GetParentFolderName(scriptPath)
listenerPath = fso.BuildPath(scriptDir, "AudioHotkeyListener.ps1")

command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File """ & listenerPath & """"

' WindowStyle=0 hides window, WaitOnReturn=False detaches process.
shell.Run command, 0, False
