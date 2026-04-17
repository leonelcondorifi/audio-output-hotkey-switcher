Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

$config = Get-AudioSwitcherConfig
$taskName = $config.TaskName
$hotkey = Get-HotkeyDefinition
$listenerPath = Join-Path $PSScriptRoot 'AudioHotkeyListener.ps1'

if (-not (Test-Path -Path $listenerPath)) {
    throw "No se encontro el listener en: $listenerPath"
}

$userId = "$env:USERDOMAIN\$env:USERNAME"
$actionArgs = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$listenerPath`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Start-ScheduledTask -TaskName $taskName

Write-SwitcherLog -Message "Task '$taskName' installed and started for user $userId. Shortcut: $($hotkey.Description)."
Write-Output "Installed and started task '$taskName'. Shortcut: $($hotkey.Description)"
