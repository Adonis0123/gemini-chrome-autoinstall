# Gemini Chrome AutoInstall

When Chrome updates and removes the [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome) extension, this tool helps you bring it back with one command. On macOS it can also watch the Chrome app and auto-reinstall in the background; on Windows it auto-checks at logon and also gives you a fast manual recovery command for same-session updates.

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
- **Windows**: it will auto-run at logon and register shortcut functions (`gemini-chrome-fix`, `gemini-chrome-status`) in your PowerShell profile. Restart PowerShell to use them. If Chrome updates during an already-open session, close Chrome and run `gemini-chrome-fix`.

## Quick Shortcuts

After installation, two shortcut commands are available on both platforms:

| Command | Action |
|---------|--------|
| `gemini-chrome-fix` | Re-install the extension (close Chrome first) |
| `gemini-chrome-status` | Check current status |

### macOS: add zsh commands

Add this to `~/.zshrc`:

```bash
gemini-chrome-fix() { $HOME/.gemini-chrome-autoinstall/patch.sh manual; }
gemini-chrome-status() { $HOME/.gemini-chrome-autoinstall/patch.sh status; }
```

Then reload: `source ~/.zshrc`

### Windows: PowerShell shortcut commands

These are **registered automatically** during installation. After restarting PowerShell, you can use them directly:

```powershell
gemini-chrome-fix       # Re-install the extension
gemini-chrome-status    # Check current status
```

If they are missing (e.g. you reinstalled PowerShell or reset your profile), add them manually:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content $PROFILE "`nfunction gemini-chrome-fix { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" manual }"
Add-Content $PROFILE "function gemini-chrome-status { & `"`$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1`" status }"
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

> Note: uninstall removes the scheduled task and script files but does not remove the shortcut functions from your PowerShell profile. To clean those up, edit `$PROFILE` manually.

## How It Works

### macOS

Two background agents are registered:

- **Boot agent** — runs once after every login
- **Watcher agent** — detects Chrome updates by watching `/Applications/Google Chrome.app/Contents/Info.plist`

When triggered, the script waits for Chrome to close, then re-installs the extension.

### Windows

A Scheduled Task runs at logon (registered under the current user, no Administrator privileges required). It waits for Chrome to close, then re-installs the extension.

This is intentional: Windows does **not** watch every Chrome update event in real time. If Chrome updates during a session that is already open, just close Chrome and run `gemini-chrome-fix`.

### Safety

- Waits for Chrome to close before patching (up to 10 min)
- Lock file prevents repeated runs within 5 minutes
- Manual fix command is available on both platforms when you want to re-install immediately

## All Commands

Full command reference for advanced usage:

```bash
# macOS
~/.gemini-chrome-autoinstall/patch.sh status     # Check if it's running
~/.gemini-chrome-autoinstall/patch.sh run         # Patch now (waits for Chrome to close)
~/.gemini-chrome-autoinstall/patch.sh manual      # Re-install now after Chrome is closed
~/.gemini-chrome-autoinstall/patch.sh disable     # Stop auto-patching (keep files)
~/.gemini-chrome-autoinstall/patch.sh enable      # Re-enable auto-patching
~/.gemini-chrome-autoinstall/patch.sh uninstall   # Remove everything
```

```powershell
# Windows
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" run
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" disable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" enable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
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
