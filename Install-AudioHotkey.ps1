Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

function Get-ListenerProcesses {
    param(
        [int[]]$ExcludeProcessIds = @()
    )

    $listenerMarker = 'AudioHotkeyListener.ps1'
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -like "*$listenerMarker*"
        })

    if (@($ExcludeProcessIds).Count -gt 0) {
        $processes = @($processes | Where-Object { $ExcludeProcessIds -notcontains [int]$_.ProcessId })
    }

    return $processes
}

function Stop-ListenerProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Processes
    )

    foreach ($process in $Processes) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
        catch {
            Write-SwitcherLog -Level 'WARN' -Message "No se pudo detener listener PID $($process.ProcessId). Detalle: $($_.Exception.Message)"
        }
    }
}

$config = Get-AudioSwitcherConfig
$taskName = $config.TaskName
$hotkey = Get-HotkeyDefinition
$listenerPath = Join-Path $PSScriptRoot 'AudioHotkeyListener.ps1'
$launcherPath = Join-Path $PSScriptRoot 'Launch-AudioHotkeyListener.vbs'

if (-not (Test-Path -Path $listenerPath)) {
    throw "No se encontro el listener en: $listenerPath"
}

if (-not (Test-Path -Path $launcherPath)) {
    throw "No se encontro el launcher en: $launcherPath"
}

$userId = "$env:USERDOMAIN\$env:USERNAME"
$actionArgs = "//B //NoLogo `"$launcherPath`""

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $actionArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$staleListeners = @(Get-ListenerProcesses -ExcludeProcessIds @($PID))
if (@($staleListeners).Count -gt 0) {
    Stop-ListenerProcesses -Processes $staleListeners
    Start-Sleep -Milliseconds 500
}

Start-ScheduledTask -TaskName $taskName

$listenerProcess = $null
$maxWaitSeconds = 10
$deadline = (Get-Date).AddSeconds($maxWaitSeconds)
while ((Get-Date) -lt $deadline) {
    $candidate = Get-ListenerProcesses -ExcludeProcessIds @($PID) | Select-Object -First 1
    if ($candidate) {
        $listenerProcess = $candidate
        break
    }

    Start-Sleep -Milliseconds 300
}

if (-not $listenerProcess) {
    throw "No se detecto un proceso listener activo luego de iniciar la tarea '$taskName'."
}

Write-SwitcherLog -Message "Task '$taskName' installed and started for user $userId. Shortcut: $($hotkey.Description). Listener PID: $($listenerProcess.ProcessId)."
Write-Output "Installed and started task '$taskName'. Shortcut: $($hotkey.Description). Listener PID: $($listenerProcess.ProcessId)"
