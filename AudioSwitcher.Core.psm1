Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultTaskName = 'AudioOutputHotkeySwitcher'

function Get-DefaultTaskName {
    return $script:DefaultTaskName
}

function Get-AudioSwitcherConfigPath {
    return Join-Path $PSScriptRoot 'AudioSwitcher.Config.json'
}

function Get-AudioSwitcherLogPath {
    $logDirectory = Join-Path $env:LOCALAPPDATA 'AudioHotkeySwitcher'
    if (-not (Test-Path -Path $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    return Join-Path $logDirectory 'switcher.log'
}

function Write-SwitcherLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $logPath = Get-AudioSwitcherLogPath
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "$timestamp [$Level] $Message" -Encoding UTF8
}

function Initialize-AudioInterop {
    if ('AudioSwitcher.User32' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AudioSwitcher
{
    public enum EDataFlow
    {
        eRender,
        eCapture,
        eAll,
        EDataFlow_enum_count
    }

    public enum ERole
    {
        eConsole,
        eMultimedia,
        eCommunications,
        ERole_enum_count
    }

    [Flags]
    public enum DEVICE_STATE : uint
    {
        ACTIVE = 0x00000001,
        DISABLED = 0x00000002,
        NOTPRESENT = 0x00000004,
        UNPLUGGED = 0x00000008,
        ALL = 0x0000000F
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, DEVICE_STATE stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr callback);
        int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-C0A13C2D4A85")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        int GetCount(out uint count);
        int Item(uint index, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        int GetId(out IntPtr id);
        int GetState(out DEVICE_STATE state);
    }

    [ComImport]
    [Guid("f8679f50-850a-41cf-9c72-430f290290c8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPolicyConfig
    {
        int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
        int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int defaultFormat, IntPtr format);
        int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
        int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int defaultPeriod, IntPtr defaultValue, IntPtr minimumValue);
        int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
        int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
        int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
        int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, ERole role);
        int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
    }

    public static class AudioEndpointController
    {
        private static IMMDeviceEnumerator CreateEnumerator()
        {
            var enumeratorType = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"), true);
            return (IMMDeviceEnumerator)Activator.CreateInstance(enumeratorType);
        }

        private static IPolicyConfig CreatePolicyConfig()
        {
            var policyType = Type.GetTypeFromCLSID(new Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9"), true);
            return (IPolicyConfig)Activator.CreateInstance(policyType);
        }

        public static string GetDefaultRenderEndpointId()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice endpoint = null;
            IntPtr idPointer = IntPtr.Zero;

            try
            {
                enumerator = CreateEnumerator();
                Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eConsole, out endpoint));
                Marshal.ThrowExceptionForHR(endpoint.GetId(out idPointer));
                return Marshal.PtrToStringUni(idPointer);
            }
            finally
            {
                if (idPointer != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(idPointer);
                }

                if (endpoint != null)
                {
                    Marshal.ReleaseComObject(endpoint);
                }

                if (enumerator != null)
                {
                    Marshal.ReleaseComObject(enumerator);
                }
            }
        }

        public static bool IsEndpointActive(string endpointId)
        {
            if (string.IsNullOrWhiteSpace(endpointId))
            {
                return false;
            }

            IMMDeviceEnumerator enumerator = null;
            IMMDevice endpoint = null;

            try
            {
                enumerator = CreateEnumerator();
                int hr = enumerator.GetDevice(endpointId, out endpoint);
                if (hr != 0 || endpoint == null)
                {
                    return false;
                }

                DEVICE_STATE state;
                hr = endpoint.GetState(out state);
                if (hr != 0)
                {
                    return false;
                }

                return (state & DEVICE_STATE.ACTIVE) == DEVICE_STATE.ACTIVE;
            }
            finally
            {
                if (endpoint != null)
                {
                    Marshal.ReleaseComObject(endpoint);
                }

                if (enumerator != null)
                {
                    Marshal.ReleaseComObject(enumerator);
                }
            }
        }

        public static void SetDefaultRenderEndpointForAllRoles(string endpointId)
        {
            if (string.IsNullOrWhiteSpace(endpointId))
            {
                throw new ArgumentException("EndpointId is required.", "endpointId");
            }

            IPolicyConfig policyConfig = null;

            try
            {
                policyConfig = CreatePolicyConfig();
                Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eConsole));
                Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eMultimedia));
                Marshal.ThrowExceptionForHR(policyConfig.SetDefaultEndpoint(endpointId, ERole.eCommunications));
            }
            finally
            {
                if (policyConfig != null)
                {
                    Marshal.ReleaseComObject(policyConfig);
                }
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
        public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    public static class User32
    {
        [DllImport("user32.dll")]
        public static extern int GetMessage(out MSG msg, IntPtr hWnd, uint filterMin, uint filterMax);

        [DllImport("user32.dll")]
        public static extern bool TranslateMessage([In] ref MSG msg);

        [DllImport("user32.dll")]
        public static extern IntPtr DispatchMessage([In] ref MSG msg);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);
    }

    public static class Kernel32
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr GetModuleHandle(string moduleName);
    }
}
'@
}

function ConvertTo-EndpointId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $prefix = 'SWD\MMDEVAPI\'
    if ($InstanceId.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $InstanceId.Substring($prefix.Length)
    }

    return $InstanceId
}

function Get-ObjectMemberValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [object]$Default = $null
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $Default
}

function Get-DefaultHotkeyConfig {
    return [ordered]@{
        Windows = $true
        Control = $false
        Alt     = $false
        Shift   = $false
        Key     = 'O'
    }
}

function ConvertTo-HotkeyConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Hotkey
    )

    $normalized = Get-DefaultHotkeyConfig

    $windowsValue = Get-ObjectMemberValue -Object $Hotkey -Name 'Windows'
    if ($null -ne $windowsValue) {
        $normalized.Windows = [bool]$windowsValue
    }

    $controlValue = Get-ObjectMemberValue -Object $Hotkey -Name 'Control'
    if ($null -ne $controlValue) {
        $normalized.Control = [bool]$controlValue
    }

    $altValue = Get-ObjectMemberValue -Object $Hotkey -Name 'Alt'
    if ($null -ne $altValue) {
        $normalized.Alt = [bool]$altValue
    }

    $shiftValue = Get-ObjectMemberValue -Object $Hotkey -Name 'Shift'
    if ($null -ne $shiftValue) {
        $normalized.Shift = [bool]$shiftValue
    }

    $keyValue = Get-ObjectMemberValue -Object $Hotkey -Name 'Key'
    if (-not [string]::IsNullOrWhiteSpace([string]$keyValue)) {
        $normalized.Key = [string]$keyValue
    }

    $normalized.Key = $normalized.Key.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized.Key)) {
        throw 'La tecla principal del hotkey no puede estar vacia.'
    }

    $hasModifier = $normalized.Windows -or $normalized.Control -or $normalized.Alt -or $normalized.Shift
    if (-not $hasModifier) {
        throw 'El hotkey debe incluir al menos un modificador (Win, Ctrl, Alt o Shift).'
    }

    [void](ConvertTo-VirtualKeyCode -Key $normalized.Key)
    return $normalized
}

function ConvertTo-HotkeyConfigFromString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HotkeyString
    )

    $inputValue = $HotkeyString.Trim()
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        throw 'El hotkey no puede estar vacio.'
    }

    $tokens = $inputValue.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($tokens.Count -lt 2) {
        throw 'Formato de hotkey invalido. Ejemplos: Win+O, Ctrl+Alt+K, Win+Shift+F9.'
    }

    $hotkey = [ordered]@{
        Windows = $false
        Control = $false
        Alt     = $false
        Shift   = $false
        Key     = $null
    }

    foreach ($token in $tokens) {
        switch -Regex ($token.ToUpperInvariant()) {
            '^(WIN|WINDOWS)$' { $hotkey.Windows = $true; continue }
            '^(CTRL|CONTROL)$' { $hotkey.Control = $true; continue }
            '^ALT$' { $hotkey.Alt = $true; continue }
            '^SHIFT$' { $hotkey.Shift = $true; continue }
            default {
                if ($hotkey.Key) {
                    throw "Formato de hotkey invalido. Solo una tecla principal es permitida: '$token'."
                }
                $hotkey.Key = $token.ToUpperInvariant()
            }
        }
    }

    if (-not $hotkey.Key) {
        throw 'No se detecto la tecla principal del hotkey.'
    }

    return ConvertTo-HotkeyConfig -Hotkey $hotkey
}

function ConvertTo-VirtualKeyCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $enumValue = [System.Enum]::Parse([System.Windows.Forms.Keys], $Key, $true)
        $vk = [int]$enumValue
        if ($vk -le 0) {
            throw 'Virtual key invalid.'
        }

        return $vk
    }
    catch {
        throw "Tecla principal no soportada: '$Key'. Usa valores como O, K, D1, F9, OemMinus, OemPlus."
    }
}

function Get-HotkeyDescription {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Hotkey
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Hotkey.Control) { $parts.Add('Ctrl') }
    if ($Hotkey.Alt) { $parts.Add('Alt') }
    if ($Hotkey.Shift) { $parts.Add('Shift') }
    if ($Hotkey.Windows) { $parts.Add('Win') }
    $parts.Add(([string]$Hotkey.Key).ToUpperInvariant())

    return ($parts -join ' + ')
}

function Get-AudioRenderEndpoints {
    $rawDevices = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue)
    $renderDevices = $rawDevices |
        Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.0.00000000}.*' } |
        Sort-Object FriendlyName

    $index = 1
    $results = foreach ($device in $renderDevices) {
        [pscustomobject]@{
            Index      = $index
            Name       = $device.FriendlyName
            Status     = $device.Status
            InstanceId = $device.InstanceId
            EndpointId = ConvertTo-EndpointId -InstanceId $device.InstanceId
            IsActive   = (Test-AudioEndpointAvailable -InstanceId $device.InstanceId)
        }
        $index++
    }

    return @($results)
}

function New-DefaultAudioSwitcherConfig {
    $endpoints = Get-AudioRenderEndpoints
    $selectedDevices = @()

    if ($endpoints.Count -ge 2) {
        $selectedDevices = @(
            [ordered]@{
                Name       = $endpoints[0].Name
                InstanceId = $endpoints[0].InstanceId
            }
            [ordered]@{
                Name       = $endpoints[1].Name
                InstanceId = $endpoints[1].InstanceId
            }
        )
    }

    return [ordered]@{
        TaskName = $script:DefaultTaskName
        Hotkey   = Get-DefaultHotkeyConfig
        Devices  = $selectedDevices
    }
}

function Save-AudioSwitcherConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $normalized = ConvertTo-AudioSwitcherConfig -Config $Config
    $path = Get-AudioSwitcherConfigPath
    $json = $normalized | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
    return $normalized
}

function ConvertTo-AudioSwitcherConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $taskName = $script:DefaultTaskName
    $taskNameValue = Get-ObjectMemberValue -Object $Config -Name 'TaskName'
    if (-not [string]::IsNullOrWhiteSpace([string]$taskNameValue)) {
        $taskName = [string]$taskNameValue
    }

    $hotkey = Get-DefaultHotkeyConfig
    $hotkeyValue = Get-ObjectMemberValue -Object $Config -Name 'Hotkey'
    if ($hotkeyValue) {
        $hotkey = ConvertTo-HotkeyConfig -Hotkey $hotkeyValue
    }

    $devices = New-Object System.Collections.Generic.List[object]
    $devicesValue = Get-ObjectMemberValue -Object $Config -Name 'Devices'
    if ($devicesValue) {
        foreach ($device in @($devicesValue)) {
            if (-not $device) {
                continue
            }

            $instanceId = [string](Get-ObjectMemberValue -Object $device -Name 'InstanceId')
            if ([string]::IsNullOrWhiteSpace($instanceId)) {
                continue
            }

            $name = [string](Get-ObjectMemberValue -Object $device -Name 'Name')
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = $instanceId
            }

            $devices.Add([ordered]@{
                Name       = $name
                InstanceId = $instanceId
            })
        }
    }

    if ($devices.Count -lt 2) {
        throw 'La configuracion requiere al menos 2 dispositivos de salida.'
    }

    $dedup = @()
    $seen = @{}
    foreach ($device in $devices) {
        $key = $device.InstanceId.ToUpperInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $dedup += $device
    }

    if ($dedup.Count -lt 2) {
        throw 'La configuracion requiere al menos 2 dispositivos distintos.'
    }

    return [ordered]@{
        TaskName = $taskName
        Hotkey   = $hotkey
        Devices  = $dedup
    }
}

function Get-AudioSwitcherConfig {
    $path = Get-AudioSwitcherConfigPath

    if (-not (Test-Path -Path $path)) {
        $defaultConfig = New-DefaultAudioSwitcherConfig
        if ($defaultConfig.Devices.Count -ge 2) {
            $saved = Save-AudioSwitcherConfig -Config $defaultConfig
            Write-SwitcherLog -Message "Se creo config por defecto en '$path'."
            return $saved
        }

        throw "No existe config en '$path' y no se pudieron detectar al menos 2 salidas. Ejecuta Setup-AudioHotkey.ps1."
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return ConvertTo-AudioSwitcherConfig -Config $raw
    }
    catch {
        throw "Configuracion invalida en '$path'. Ejecuta Setup-AudioHotkey.ps1. Detalle: $($_.Exception.Message)"
    }
}

function Test-AudioEndpointAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $endpointId = ConvertTo-EndpointId -InstanceId $InstanceId
    try {
        Initialize-AudioInterop
        return [AudioSwitcher.AudioEndpointController]::IsEndpointActive($endpointId)
    }
    catch {
        try {
            $fallbackDevice = Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop
            return $fallbackDevice.Status -eq 'OK'
        }
        catch {
            return $false
        }
    }
}

function Get-DefaultRenderEndpointId {
    Initialize-AudioInterop
    return [AudioSwitcher.AudioEndpointController]::GetDefaultRenderEndpointId()
}

function Set-DefaultAudioEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EndpointId
    )

    Initialize-AudioInterop
    [AudioSwitcher.AudioEndpointController]::SetDefaultRenderEndpointForAllRoles($EndpointId)
}

function Show-AudioSwitcherNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$TimeoutMilliseconds = 2500
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText = $Message
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip($TimeoutMilliseconds)

        $waitTime = [Math]::Max($TimeoutMilliseconds, 1500)
        Start-Sleep -Milliseconds $waitTime
        $notifyIcon.Dispose()
    }
    catch {
        Write-SwitcherLog -Level 'WARN' -Message "No se pudo mostrar la notificacion. Detalle: $($_.Exception.Message)"
    }
}

function Get-HotkeyDefinition {
    $config = Get-AudioSwitcherConfig
    $hotkey = ConvertTo-HotkeyConfig -Hotkey $config.Hotkey
    $virtualKey = ConvertTo-VirtualKeyCode -Key $hotkey.Key

    return [pscustomobject]@{
        VirtualKey     = $virtualKey
        RequireWindows = [bool]$hotkey.Windows
        RequireControl = [bool]$hotkey.Control
        RequireAlt     = [bool]$hotkey.Alt
        RequireShift   = [bool]$hotkey.Shift
        KeyName        = [string]$hotkey.Key
        Description    = Get-HotkeyDescription -Hotkey $hotkey
    }
}

function Invoke-AudioOutputToggle {
    param(
        [switch]$NotifyOnSuccess = $true,
        [switch]$NotifyOnFailure = $true
    )

    $config = Get-AudioSwitcherConfig
    $devices = @($config.Devices)
    $currentEndpointId = Get-DefaultRenderEndpointId

    $currentIndex = -1
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $candidateEndpoint = ConvertTo-EndpointId -InstanceId $devices[$i].InstanceId
        if ($candidateEndpoint -ieq $currentEndpointId) {
            $currentIndex = $i
            break
        }
    }

    $skipCount = 0
    $checked = 0
    while ($checked -lt $devices.Count) {
        $nextIndex = ($currentIndex + 1 + $checked) % $devices.Count
        $target = $devices[$nextIndex]
        $targetEndpointId = ConvertTo-EndpointId -InstanceId $target.InstanceId

        if (Test-AudioEndpointAvailable -InstanceId $target.InstanceId) {
            Set-DefaultAudioEndpoint -EndpointId $targetEndpointId

            $successMessage = "Salida cambiada a '$($target.Name)'."
            if ($skipCount -gt 0) {
                $successMessage = "$successMessage Se omitieron $skipCount dispositivo(s) no disponibles."
            }

            Write-SwitcherLog -Message $successMessage
            if ($NotifyOnSuccess) {
                Show-AudioSwitcherNotification -Title 'Audio Output Switcher' -Message $successMessage
            }

            return [pscustomobject]@{
                Changed            = $true
                TargetName         = $target.Name
                TargetEndpointId   = $targetEndpointId
                CurrentEndpointId  = $currentEndpointId
                SkippedUnavailable = $skipCount
                Reason             = 'Changed'
            }
        }

        $skipCount++
        $checked++
    }

    $warningMessage = 'No se cambio la salida. Ningun dispositivo configurado esta disponible.'
    Write-SwitcherLog -Level 'WARN' -Message $warningMessage
    if ($NotifyOnFailure) {
        Show-AudioSwitcherNotification -Title 'Audio Output Switcher' -Message $warningMessage
    }

    return [pscustomobject]@{
        Changed            = $false
        TargetName         = $null
        TargetEndpointId   = $null
        CurrentEndpointId  = $currentEndpointId
        SkippedUnavailable = $skipCount
        Reason             = 'NoAvailableTarget'
    }
}

Export-ModuleMember -Function Get-AudioSwitcherConfigPath
Export-ModuleMember -Function Get-DefaultTaskName
Export-ModuleMember -Function Get-AudioSwitcherLogPath
Export-ModuleMember -Function Write-SwitcherLog
Export-ModuleMember -Function Initialize-AudioInterop
Export-ModuleMember -Function ConvertTo-EndpointId
Export-ModuleMember -Function Get-AudioRenderEndpoints
Export-ModuleMember -Function New-DefaultAudioSwitcherConfig
Export-ModuleMember -Function Get-AudioSwitcherConfig
Export-ModuleMember -Function Save-AudioSwitcherConfig
Export-ModuleMember -Function Get-DefaultHotkeyConfig
Export-ModuleMember -Function ConvertTo-HotkeyConfig
Export-ModuleMember -Function ConvertTo-HotkeyConfigFromString
Export-ModuleMember -Function ConvertTo-VirtualKeyCode
Export-ModuleMember -Function Get-HotkeyDescription
Export-ModuleMember -Function Test-AudioEndpointAvailable
Export-ModuleMember -Function Get-DefaultRenderEndpointId
Export-ModuleMember -Function Set-DefaultAudioEndpoint
Export-ModuleMember -Function Show-AudioSwitcherNotification
Export-ModuleMember -Function Get-HotkeyDefinition
Export-ModuleMember -Function Invoke-AudioOutputToggle
