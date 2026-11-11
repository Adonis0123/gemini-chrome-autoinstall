Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
patchPath = scriptDir & "\patch.ps1"

' Antivirus can quarantine patch.ps1 (heuristic false positive). Launching
' powershell.exe against a missing file fails invisibly in a hidden window,
' so record why in the shared log and stop here.
If Not fso.FileExists(patchPath) Then
    LogMissingPatch
    WScript.Quit 1
End If

shell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & patchPath & """ " & WScript.Arguments(0), 0, False

Function Pad2(n)
    Pad2 = Right("0" & n, 2)
End Function

Sub LogMissingPatch()
    On Error Resume Next
    logFile = shell.Environment("PROCESS").Item("GEMINI_LOG_FILE")
    If logFile = "" Then
        logFile = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\gemini-chrome-autoinstall.log"
    End If
    n = Now
    stamp = Year(n) & "-" & Pad2(Month(n)) & "-" & Pad2(Day(n)) & " " & _
        Pad2(Hour(n)) & ":" & Pad2(Minute(n)) & ":" & Pad2(Second(n))
    msg = "[" & stamp & "] launcher: patch.ps1 not found at " & patchPath & _
        " - it was likely quarantined by antivirus (e.g. Huorong / Windows Defender false positive)." & _
        " Restore it from quarantine and add " & scriptDir & " to the antivirus trust list, or reinstall:" & _
        " irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.ps1 | iex"
    Set logStream = fso.OpenTextFile(logFile, 8, True)
    logStream.WriteLine msg
    logStream.Close
End Sub
