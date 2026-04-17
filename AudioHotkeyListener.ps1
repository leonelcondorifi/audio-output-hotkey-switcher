Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

$mutex = $null
$hookHandle = [IntPtr]::Zero
$keyboardProc = $null
$hotkeyDown = $false

try {
    Initialize-AudioInterop
    $hotkey = Get-HotkeyDefinition

    $mutexName = 'Local\AudioOutputHotkeySwitcherSingleton'
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-SwitcherLog -Level 'WARN' -Message 'Audio hotkey listener already running. Exiting duplicated instance.'
        exit 0
    }

    $wmKeyDown = 0x0100
    $wmSysKeyDown = 0x0104
    $wmKeyUp = 0x0101
    $wmSysKeyUp = 0x0105

    $vkMain = [int]$hotkey.VirtualKey
    $vkLWin = 0x5B
    $vkRWin = 0x5C
    $vkControl = 0x11
    $vkAlt = 0x12
    $vkShift = 0x10

    $whKeyboardLl = 13
    $modAsyncMask = 0x8000

    $keyboardProc = [AudioSwitcher.HookProc]{
        param($nCode, $wParam, $lParam)

        if ($nCode -ge 0 -and $lParam -ne [IntPtr]::Zero) {
            $info = [Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [type][AudioSwitcher.KBDLLHOOKSTRUCT])
            $messageCode = [int]$wParam

            $isKeyDown = $messageCode -eq $wmKeyDown -or $messageCode -eq $wmSysKeyDown
            $isKeyUp = $messageCode -eq $wmKeyUp -or $messageCode -eq $wmSysKeyUp

            if ($isKeyDown -and $info.vkCode -eq $vkMain) {
                $winPressed = (([AudioSwitcher.User32]::GetAsyncKeyState($vkLWin) -band $modAsyncMask) -ne 0) -or
                              (([AudioSwitcher.User32]::GetAsyncKeyState($vkRWin) -band $modAsyncMask) -ne 0)

                $controlPressed = ([AudioSwitcher.User32]::GetAsyncKeyState($vkControl) -band $modAsyncMask) -ne 0
                $altPressed = ([AudioSwitcher.User32]::GetAsyncKeyState($vkAlt) -band $modAsyncMask) -ne 0
                $shiftPressed = ([AudioSwitcher.User32]::GetAsyncKeyState($vkShift) -band $modAsyncMask) -ne 0

                $matchesHotkey = ($winPressed -eq [bool]$hotkey.RequireWindows) -and
                                 ($controlPressed -eq [bool]$hotkey.RequireControl) -and
                                 ($altPressed -eq [bool]$hotkey.RequireAlt) -and
                                 ($shiftPressed -eq [bool]$hotkey.RequireShift)

                if ($matchesHotkey -and -not $script:hotkeyDown) {
                    $script:hotkeyDown = $true
                    try {
                        [void](Invoke-AudioOutputToggle -NotifyOnSuccess -NotifyOnFailure)
                    }
                    catch {
                        Write-SwitcherLog -Level 'ERROR' -Message "Toggle during hotkey failed. Detail: $($_.Exception.Message)"
                        Show-AudioSwitcherNotification -Title 'Audio Output Switcher' -Message 'Audio switch failed. Check switcher.log.'
                    }

                    return [IntPtr]1
                }
            }
            elseif ($isKeyUp -and $info.vkCode -eq $vkMain) {
                if ($script:hotkeyDown) {
                    $script:hotkeyDown = $false
                    return [IntPtr]1
                }
            }
        }

        return [AudioSwitcher.User32]::CallNextHookEx([IntPtr]::Zero, $nCode, $wParam, $lParam)
    }

    $moduleHandle = [AudioSwitcher.Kernel32]::GetModuleHandle($null)
    $hookHandle = [AudioSwitcher.User32]::SetWindowsHookEx($whKeyboardLl, $keyboardProc, $moduleHandle, 0)
    if ($hookHandle -eq [IntPtr]::Zero) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "No se pudo instalar el keyboard hook global. Win32Error: $lastError"
    }

    Write-SwitcherLog -Message "Audio hotkey listener started with shortcut $($hotkey.Description) (keyboard hook)."

    $message = New-Object AudioSwitcher.MSG

    while ($true) {
        $result = [AudioSwitcher.User32]::GetMessage([ref]$message, [IntPtr]::Zero, 0, 0)
        if ($result -eq -1) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "GetMessage fallo. Win32Error: $lastError"
        }

        if ($result -eq 0) {
            break
        }

        [void][AudioSwitcher.User32]::TranslateMessage([ref]$message)
        [void][AudioSwitcher.User32]::DispatchMessage([ref]$message)
    }
}
catch {
    Write-SwitcherLog -Level 'ERROR' -Message "Hotkey listener failed. Detail: $($_.Exception.Message)"
    Show-AudioSwitcherNotification -Title 'Audio Output Switcher' -Message 'Hotkey listener failed to start. Check switcher.log.'
    throw
}
finally {
    if ($hookHandle -ne [IntPtr]::Zero) {
        [void][AudioSwitcher.User32]::UnhookWindowsHookEx($hookHandle)
        Write-SwitcherLog -Message 'Audio hotkey listener stopped and keyboard hook removed.'
    }

    if ($mutex) {
        try {
            $mutex.ReleaseMutex() | Out-Null
        }
        catch {
        }
        $mutex.Dispose()
    }
}
