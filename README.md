# Audio Output Hotkey Switcher

Switcher de salida de audio para Windows con configuracion interactiva.

Permite:

- detectar outputs de la maquina actual,
- elegir 2 o mas dispositivos para el ciclo de cambio,
- configurar un hotkey global,
- y dejar el listener listo al iniciar sesion.

## Flujo rapido

1. Ejecuta setup interactivo.
2. Selecciona dispositivos por indice (2 o mas).
3. Define el atajo (default: `Win+O`).
4. El setup guarda config e instala/reinicia la tarea programada.

## Requisitos

- Windows 10/11
- PowerShell 5.1+
- Permiso para crear tareas programadas de tu usuario

No necesita herramientas de terceros.

## Archivos

- `Setup-AudioHotkey.ps1`: asistente interactivo de configuracion
- `AudioHotkeyListener.ps1`: proceso oculto que escucha el hotkey global
- `Toggle-AudioOutput.ps1`: fuerza un cambio manual (sin hotkey)
- `Install-AudioHotkey.ps1`: instala/reinicia tarea programada
- `Uninstall-AudioHotkey.ps1`: desinstala tarea programada
- `AudioSwitcher.Core.psm1`: modulo con logica de audio/config/hotkey
- `AudioSwitcher.Config.json`: configuracion persistida (se crea automaticamente)

## Configurar en cualquier PC

Desde la carpeta del proyecto:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Setup-AudioHotkey.ps1"
```

El script:

- lista los outputs detectados,
- pide los indices a usar para switch,
- pide hotkey (opcional; Enter para `Win+O`),
- guarda `AudioSwitcher.Config.json`,
- instala/reinicia la tarea `AudioOutputHotkeySwitcher`.

## Como funciona el switch con N dispositivos

Con la lista configurada `[A, B, C, D]`:

- si estas en `B`, cambia a `C`;
- si estas en `D`, vuelve a `A`;
- si el siguiente no esta disponible, salta al siguiente disponible;
- si ninguno esta disponible, no cambia y muestra notificacion.

## Formato de hotkey

Ejemplos validos:

- `Win+O`
- `Ctrl+Alt+K`
- `Win+Shift+F9`
- `Ctrl+Shift+D1`

Reglas:

- Debe tener al menos un modificador (`Win`, `Ctrl`, `Alt`, `Shift`).
- Debe tener una tecla principal (`O`, `K`, `F9`, `D1`, etc.).

## Uso diario

- Usa tu hotkey configurado para alternar salida.
- O ejecuta manualmente:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Toggle-AudioOutput.ps1"
```

## Reconfigurar

Simplemente vuelve a correr:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Setup-AudioHotkey.ps1"
```

## Estado y logs

Ver tarea:

```powershell
Get-ScheduledTask -TaskName "AudioOutputHotkeySwitcher" | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName "AudioOutputHotkeySwitcher" | Select-Object LastRunTime, LastTaskResult
```

Log:

`%LOCALAPPDATA%\AudioHotkeySwitcher\switcher.log`

Lectura rapida:

```powershell
Get-Content "$env:LOCALAPPDATA\AudioHotkeySwitcher\switcher.log"
```

## Desinstalar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall-AudioHotkey.ps1"
```
