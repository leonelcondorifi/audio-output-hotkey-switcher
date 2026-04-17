Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

$taskName = Get-DefaultTaskName
$configPath = Get-AudioSwitcherConfigPath
if (Test-Path -Path $configPath) {
    try {
        $rawConfig = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rawConfig.PSObject.Properties['TaskName'] -and -not [string]::IsNullOrWhiteSpace([string]$rawConfig.TaskName)) {
            $taskName = [string]$rawConfig.TaskName
        }
    }
    catch {
    }
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-SwitcherLog -Message "Task '$taskName' uninstalled."
    Write-Output "Task '$taskName' removed."
}
else {
    Write-Output "Task '$taskName' was not found."
}
