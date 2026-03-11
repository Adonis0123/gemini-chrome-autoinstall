# Gemini Chrome AutoInstall

When Chrome updates and removes the [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome) extension, this tool helps you bring it back with one command. On macOS it watches the Chrome app and auto-reinstalls in the background; on Windows it monitors the Chrome registry key for version changes and also gives you a fast manual recovery command.

## Install

**macOS** — open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.sh | bash
```

**Windows** — open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.ps1 | iex
```

Done.

- **macOS**: it will keep watching Chrome updates in the background.
- **Windows**: it monitors Chrome version changes via registry watcher in real time. A manual fix command is also available. Restart PowerShell to use the shortcut functions.

## Quick Shortcuts

After installation, two shortcut commands are available on both platforms:

| Command | Action |
|---------|--------|
| `gemini-chrome-fix` | Re-install the extension (offers to close Chrome if running) |
| `gemini-chrome-status` | Check current status |

### macOS: add zsh commands

Add this to `~/.zshrc`:

```bash
gemini-chrome-fix() { $HOME/.gemini-chrome-autoinstall/patch.sh manual; }
```

```bash
gemini-chrome-status() { $HOME/.gemini-chrome-autoinstall/patch.sh status; }
```

Then reload: `source ~/.zshrc`

### Windows: PowerShell shortcut commands

These are **registered automatically** during installation. After restarting PowerShell, you can use them directly:

```powershell
gemini-chrome-fix       # Re-install the extension
```

```powershell
gemini-chrome-status    # Check current status
```

If they are missing (e.g. you reinstalled PowerShell or reset your profile), add them manually:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
```

```powershell
Add-Content $PROFILE "`nfunction gemini-chrome-fix { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" manual }"
```

```powershell
Add-Content $PROFILE "function gemini-chrome-status { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" status }"
```

```powershell
. $PROFILE
```

## Uninstall

**macOS:**

```bash
~/.gemini-chrome-autoinstall/patch.sh uninstall
```

**Windows:**

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
```

> Note: uninstall removes the startup entry and script files but does not remove the shortcut functions from your PowerShell profile. To clean those up, edit `$PROFILE` manually.

## How It Works

### macOS

Two background agents are registered:

- **Boot agent** — runs once after every login
- **Watcher agent** — detects Chrome updates by watching `/Applications/Google Chrome.app/Contents/Info.plist`

When triggered, the script waits for Chrome to close, then re-installs the extension.

### Windows

A startup entry (HKCU Registry Run key) launches the watcher at logon. The background **registry watcher** monitors `HKCU:\Software\Google\Chrome\BLBeacon\version` for changes using the Win32 `RegNotifyChangeKeyValue` API (blocking, zero CPU usage). When a version change is detected, it automatically triggers the patch. No admin privileges are required.

### Safety

- Waits for Chrome to close before patching (up to 10 min)
- `manual` command offers to close Chrome for you (with confirmation)
- Lock file prevents repeated runs within 5 minutes
- Manual fix command is available on both platforms when you want to re-install immediately

## All Commands

**macOS:**

```bash
~/.gemini-chrome-autoinstall/patch.sh status      # Check if it's running
```

```bash
~/.gemini-chrome-autoinstall/patch.sh run          # Patch now (waits for Chrome to close)
```

```bash
~/.gemini-chrome-autoinstall/patch.sh manual       # Re-install now (offers to close Chrome)
```

```bash
~/.gemini-chrome-autoinstall/patch.sh disable      # Stop auto-patching (keep files)
```

```bash
~/.gemini-chrome-autoinstall/patch.sh enable       # Re-enable auto-patching
```

```bash
~/.gemini-chrome-autoinstall/patch.sh uninstall    # Remove everything
```

**Windows:**

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" run
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" disable
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" enable
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
```

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" watch
```

## Manual Fix

If you already closed Chrome and want to run the core installer right now:

**macOS**

```bash
~/.gemini-chrome-autoinstall/patch.sh manual
```

This runs:

```bash
curl -fsSL https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.sh | bash
```

**Windows**

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual
```

This runs:

```powershell
irm https://raw.githubusercontent.com/appsail/Gemini-in-Chrome/main/install.ps1 | iex
```

## Logs

| Platform | Path |
|----------|------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## License

[MIT](LICENSE)
