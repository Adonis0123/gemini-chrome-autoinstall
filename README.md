# Gemini Chrome AutoInstall

`gemini-chrome-autoinstall` is a cross-platform self-healing wrapper around [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome).

Its real job is not “reinstalling an extension after every update.” It watches for Chrome version changes and `Local State` drift, then repairs the relevant `Local State` values when it is safe to write. If Chrome is still open, it records `pending` and waits for a later retry instead of forcing a patch.

## Install

**macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.ps1 | iex
```

After installation, the success output shows the installed tool version.

## Quick Shortcuts

| Command | Action |
|---------|--------|
| `gemini-chrome-fix` | Run the manual repair flow |
| `gemini-chrome-status` | Show runtime status, version info, and pending state |

### macOS shell shortcuts

Add these to `~/.zshrc`:

```bash
gemini-chrome-fix() { "$HOME/.gemini-chrome-autoinstall/patch.sh" manual; }
gemini-chrome-status() { "$HOME/.gemini-chrome-autoinstall/patch.sh" status; }
```

Reload your shell:

```bash
source ~/.zshrc
```

### Windows PowerShell shortcuts

The installer appends these functions to your PowerShell profile automatically:

```powershell
gemini-chrome-fix
gemini-chrome-status
```

If your profile was reset, add them manually:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content $PROFILE "`nfunction gemini-chrome-fix { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" manual }"
Add-Content $PROFILE "function gemini-chrome-status { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" status }"
. $PROFILE
```

## Runtime Model

The tool treats `Local State` as the source of truth.

- `healthy`: required fields already match the expected Gemini-in-Chrome state
- `drifted`: Chrome state has moved away from the expected patched values
- `unknown`: the tool cannot prove health because the file is missing, malformed, or missing required fields
- `pending`: drift has been detected, but Chrome is still open or a retry is still in progress

The automatic path never forces a write while Chrome is open. Instead it records metadata in `pending`, keeps retry context, and retries later.

## How It Works

### macOS

Four LaunchAgents cooperate:

- `com.gemini-chrome-autoinstall.boot` runs `patch.sh run` at login
- `com.gemini-chrome-autoinstall.watcher` reacts to Chrome app metadata changes
- `com.gemini-chrome-autoinstall.retry` retries while a `pending` file exists
- `com.gemini-chrome-autoinstall.fallback` runs a low-frequency reconcile pass every 30 minutes

Automatic flow:

1. A trigger runs `patch.sh run`
2. The script inspects Chrome version plus `Local State`
3. If state is `healthy`, it clears stale `pending` and records the healthy version
4. If state is `drifted` and Chrome is open, it records `pending`
5. If state is `drifted` and Chrome is closed, it runs the upstream installer and verifies the result
6. If patching fails or verification still does not return `healthy`, it records a failure state and points the user to `gemini-chrome-fix`

### Windows

Windows uses a login startup entry plus a background registry watcher.

- Startup entry: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\GeminiChromeAutoPatch`
- Watch source: `HKCU:\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}\pv`
- Background watcher command: `patch.ps1 watch`
- Startup entrypoint: `patch.ps1 scheduled`

The watcher treats version changes as a signal to reconcile, not as proof that patching is needed. `Local State` remains the final health check.

## Status Output

`gemini-chrome-status` shows version, runtime state, and pending metadata.

Example:

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

This makes it easy to distinguish:

- everything is already healthy
- drift has been detected
- Chrome is still open, so repair is deferred
- detection failed and manual recovery is needed
- automatic repair failed or verification failed

## Commands

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

## Manual Recovery

If automatic repair reports `patch_failed`, `verify_failed`, or `detect_error`, run:

```bash
gemini-chrome-fix
```

That keeps the recovery path predictable and gives you a stable manual escape hatch even if automatic reconciliation cannot converge.

## Logs

| Platform | Path |
|----------|------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## License

[MIT](LICENSE)
