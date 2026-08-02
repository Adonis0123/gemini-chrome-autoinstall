

# Gemini Chrome AutoInstall

`gemini-chrome-autoinstall` es un envoltorio autocorrectivo multiplataforma para [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome).

Su función real no es "reinstalar una extensión después de cada actualización". Monitorea los cambios de versión de Chrome y la desviación (`drift`) en `Local State`, y luego repara los valores relevantes de `Local State` cuando es seguro escribir. Si Chrome aún está abierto, registra `pending` y espera para un reintento posterior en lugar de forzar un parche.

## Instalación

**macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.ps1 | iex
```

Tras la instalación, la salida de éxito muestra la versión de la herramienta instalada.

## Atajos rápidos

| Comando | Acción |
|---------|--------|
| `gemini-chrome-fix` | Ejecutar el flujo de reparación manual |
| `gemini-chrome-status` | Mostrar el estado en ejecución, información de versión y estado pendiente |

### Atajos de shell para macOS

Agregue estos a `~/.zshrc`:

```bash
gemini-chrome-fix() { "$HOME/.gemini-chrome-autoinstall/patch.sh" manual; }
gemini-chrome-status() { "$HOME/.gemini-chrome-autoinstall/patch.sh" status; }
```

Recargue su shell:

```bash
source ~/.zshrc
```

### Atajos para Windows PowerShell

El instalador agrega estas funciones automáticamente a su perfil de PowerShell:

```powershell
gemini-chrome-fix
gemini-chrome-status
```

Si su perfil se reinició, agreguelos manualmente:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content $PROFILE "`nfunction gemini-chrome-fix { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" manual }"
Add-Content $PROFILE "function gemini-chrome-status { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" status }"
. $PROFILE
```

## Modelo de ejecución

La herramienta considera a `Local State` como la fuente de verdad.

- `healthy`: los campos requeridos ya coinciden con el estado esperado de Gemini-in-Chrome
- `drifted`: el estado de Chrome se ha alejado de los valores parcheados esperados
- `unknown`: la herramienta no puede verificar la salud porque el archivo falta, está mal formado o le faltan campos requeridos
- `pending`: se ha detectado una desviación, pero Chrome aún está abierto o un reintento aún está en curso

La ruta automática nunca fuerza una escritura mientras Chrome está abierto. En su lugar, registra metadatos en `pending`, conserva el contexto de reintento y reintenta más tarde.

## Cómo funciona

### macOS

Cuatro LaunchAgents cooperan:

- `com.gemini-chrome-autoinstall.boot` ejecuta `patch.sh run` al iniciar sesión
- `com.gemini-chrome-autoinstall.watcher` reacciona a los cambios de metadatos de la aplicación Chrome
- `com.gemini-chrome-autoinstall.retry` realiza reintentos mientras exista un archivo `pending`
- `com.gemini-chrome-autoinstall.fallback` ejecuta un paso de reconciliación de baja frecuencia cada 30 minutos

Flujo automático:

1. Un disparador ejecuta `patch.sh run`
2. El script inspecciona la versión de Chrome y `Local State`
3. Si el estado es `healthy`, limpia los `pending` obsoletos y registra la versión sana
4. Si el estado es `drifted` y Chrome está abierto, registra `pending`
5. Si el estado es `drifted` y Chrome está cerrado, ejecuta el instalador principal y verifica el resultado
6. Si el parcheo falla o la verificación aún no devuelve `healthy`, registra un estado de fallo y dirige al usuario a `gemini-chrome-fix`

### Windows

Windows utiliza una entrada de inicio de sesión junto con un observador de registro en segundo plano.

- Entrada de inicio: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\GeminiChromeAutoPatch`
- Fuente de observación: `HKCU:\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}\pv`
- Comando del observador en segundo plano: `patch.ps1 watch`
- Punto de entrada de inicio: `patch.ps1 scheduled`

El observador trata los cambios de versión como una señal para reconciliar, no como prueba de que se necesite un parche. `Local State` sigue siendo la verificación final de salud.

## Salida de estado

`gemini-chrome-status` muestra la versión, el estado en ejecución y los metadatos pendientes.

Ejemplo:

```text
Tool version: v0.1.2
Chrome version: 136.0.7103.49
Last healthy version: 136.0.7103.49
Current state: pending
Pending reason: blocked
Pending patch reason: variations_country=cn
Pending retry count: 4
Pending age: 240s
Last attempt: 2026-03-29T08:00:00Z
```

Esto facilita distinguir:

- todo ya está en estado `healthy` (sano)
- se ha detectado una desviación (`drift`)
- Chrome aún está abierto, por lo que la reparación se pospone
- la detección falló y se requiere recuperación manual
- la reparación automática falló o falló la verificación

## Comandos

### macOS

```bash
~/.gemini-chrome-autoinstall/patch.sh enable
~/.gemini-chrome-autoinstall/patch.sh disable
~/.gemini-chrome-autoinstall/patch.sh status
~/.gemini-chrome-autoinstall/patch.sh run
~/.gemini-chrome-autoinstall/patch.sh retry
~/.gemini-chrome-autoinstall/patch.sh manual
~/.gemini-chrome-autoinstall/patch.sh uninstall
```

### Windows

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" enable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" disable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" run
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" retry
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" watch
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" scheduled
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
```

## Recuperación manual

Si la reparación automática informa `patch_failed`, `verify_failed` o `detect_error`, ejecute:

```bash
gemini-chrome-fix
```

Esto mantiene la ruta de recuperación predecible y le proporciona una salida manual estable, incluso si la reconciliación automática no puede converger.

## Registros (Logs)

| Plataforma | Ruta |
|----------|------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## Licencia

[MIT](LICENSE)
