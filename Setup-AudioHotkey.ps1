Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'AudioSwitcher.Core.psm1'
Import-Module $modulePath -Force

function Read-NonEmptyInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        Write-Host 'Entrada invalida. Intenta nuevamente.' -ForegroundColor Yellow
    }
}

function Read-DeviceSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Endpoints
    )

    while ($true) {
        $rawInput = Read-NonEmptyInput -Prompt 'Indices para alternar (ej: 1,3,2). Minimo 2'
        $tokens = $rawInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($tokens.Count -lt 2) {
            Write-Host 'Debes indicar al menos 2 indices.' -ForegroundColor Yellow
            continue
        }

        $selected = New-Object 'System.Collections.Generic.List[object]'
        $seen = @{}
        $isValid = $true

        foreach ($token in $tokens) {
            $index = 0
            if (-not [int]::TryParse($token, [ref]$index)) {
                Write-Host "Indice invalido: '$token'." -ForegroundColor Yellow
                $isValid = $false
                break
            }

            $match = $Endpoints | Where-Object { $_.Index -eq $index } | Select-Object -First 1
            if (-not $match) {
                Write-Host "Indice fuera de rango: '$index'." -ForegroundColor Yellow
                $isValid = $false
                break
            }

            if ($seen.ContainsKey($match.InstanceId.ToUpperInvariant())) {
                Write-Host "Indice repetido: '$index'. Cada dispositivo solo una vez." -ForegroundColor Yellow
                $isValid = $false
                break
            }

            $seen[$match.InstanceId.ToUpperInvariant()] = $true
            $selected.Add($match)
        }

        if (-not $isValid) {
            continue
        }

        if ($selected.Count -lt 2) {
            Write-Host 'Debes seleccionar al menos 2 dispositivos distintos.' -ForegroundColor Yellow
            continue
        }

        return $selected.ToArray()
    }
}

function Read-HotkeyConfiguration {
    $defaultHotkey = Get-DefaultHotkeyConfig
    $defaultDescription = Get-HotkeyDescription -Hotkey $defaultHotkey

    while ($true) {
        $rawInput = Read-Host "Atajo de teclado (default: $defaultDescription)"
        if ([string]::IsNullOrWhiteSpace($rawInput)) {
            return $defaultHotkey
        }

        try {
            return ConvertTo-HotkeyConfigFromString -HotkeyString $rawInput
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

try {
    $endpoints = Get-AudioRenderEndpoints
    if ($endpoints.Count -lt 2) {
        throw 'Se detectaron menos de 2 dispositivos de salida. No se puede configurar el switcher.'
    }

    Write-Host ''
    Write-Host 'Dispositivos de salida detectados:' -ForegroundColor Cyan
    foreach ($endpoint in $endpoints) {
        $availability = if ($endpoint.IsActive) { 'Disponible' } else { 'No disponible' }
        Write-Host ("[{0}] {1} | EstadoPnP: {2} | {3}" -f $endpoint.Index, $endpoint.Name, $endpoint.Status, $availability)
    }

    Write-Host ''
    $selected = Read-DeviceSelection -Endpoints $endpoints
    $hotkeyConfig = Read-HotkeyConfiguration

    $devicesForConfig = @()
    foreach ($device in $selected) {
        $devicesForConfig += [ordered]@{
            Name       = $device.Name
            InstanceId = $device.InstanceId
        }
    }

    $newConfig = [ordered]@{
        TaskName = 'AudioOutputHotkeySwitcher'
        Hotkey   = $hotkeyConfig
        Devices  = $devicesForConfig
    }

    $savedConfig = Save-AudioSwitcherConfig -Config $newConfig
    $hotkeyDescription = Get-HotkeyDescription -Hotkey $savedConfig.Hotkey

    Write-Host ''
    Write-Host 'Configuracion guardada:' -ForegroundColor Green
    Write-Host "- Archivo: $(Get-AudioSwitcherConfigPath)"
    Write-Host "- Hotkey: $hotkeyDescription"
    Write-Host '- Orden de switch:'
    for ($i = 0; $i -lt $savedConfig.Devices.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $savedConfig.Devices[$i].Name)
    }

    Write-Host ''
    Write-Host 'Instalando/reiniciando listener...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Install-AudioHotkey.ps1')
    if (-not $?) {
        throw 'No se pudo instalar/reiniciar la tarea programada.'
    }

    Write-SwitcherLog -Message "Setup interactivo aplicado. Hotkey: $hotkeyDescription. Dispositivos: $($savedConfig.Devices.Count)."
    Write-Host 'Configuracion aplicada correctamente.' -ForegroundColor Green
}
catch {
    Write-SwitcherLog -Level 'ERROR' -Message "Setup interactivo fallo. Detalle: $($_.Exception.Message)"
    throw
}
