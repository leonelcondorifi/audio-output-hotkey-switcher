param(
    [switch]$NoSuccessNotification,
    [switch]$NoFailureNotification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

try {
    $result = Invoke-AudioOutputToggle -NotifyOnSuccess:(-not $NoSuccessNotification) -NotifyOnFailure:(-not $NoFailureNotification)

    if ($result.Changed) {
        Write-Output "Output switched to: $($result.TargetName)"
        exit 0
    }

    if ($result.Reason -eq 'NoAvailableTarget') {
        Write-Output 'No change: no configured output device is currently available.'
    }
    else {
        Write-Output "No change: $($result.TargetName) not available."
    }

    exit 1
}
catch {
    Write-SwitcherLog -Level 'ERROR' -Message "Toggle failed. Detail: $($_.Exception.Message)"
    Show-AudioSwitcherNotification -Title 'Audio Output Switcher' -Message 'Audio switch failed. Check switcher.log.'
    throw
}
