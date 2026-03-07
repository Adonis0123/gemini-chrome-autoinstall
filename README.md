# Gemini Chrome AutoInstall

When Chrome updates and removes the [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome) extension, this tool helps you bring it back with one command. On macOS it can also watch the Chrome app and auto-reinstall in the background; on Windows it auto-checks at logon and also gives you a fast manual recovery command for same-session updates.

## Install

**macOS** — open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.sh | bash
```

**Windows** — open PowerShell **as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/master/install.ps1 | iex
```

Done.

- **macOS**: it will keep watching Chrome updates in the background.
- **Windows**: it will auto-run at logon. If Chrome updates during an already-open session, run the manual fix command below after you close Chrome.

## Uninstall

**macOS:**

```bash
~/.gemini-chrome-autoinstall/patch.sh uninstall
```

**Windows** (PowerShell as Administrator):

```powershell
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
```

## How It Works

### macOS

Two background agents are registered:

- **Boot agent** — runs once after every login
- **Watcher agent** — detects Chrome updates by watching `/Applications/Google Chrome.app/Contents/Info.plist`

When triggered, the script waits for Chrome to close, then re-installs the extension.

### Windows

A Scheduled Task runs at logon. It waits for Chrome to close, then re-installs the extension.

This is intentional: Windows does **not** watch every Chrome update event in real time. If Chrome updates during a session that is already open, just close Chrome and run the manual fix command below.

### Safety

- Waits for Chrome to close before patching (up to 10 min)
- Lock file prevents repeated runs within 5 minutes
- Manual fix command is available on both platforms when you want to re-install immediately

## Commands

You can run these manually after installation:

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
# Windows (PowerShell as Administrator)
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

## Quick Shortcuts

### macOS: add zsh commands

Add this to `~/.zshrc`:

```bash
alias gemini-chrome-fix='$HOME/.gemini-chrome-autoinstall/patch.sh manual'
alias gemini-chrome-status='$HOME/.gemini-chrome-autoinstall/patch.sh status'
```

Then reload zsh:

```bash
source ~/.zshrc
gemini-chrome-fix       # Re-install the extension
gemini-chrome-status    # Check current status
```

### Windows: add PowerShell shortcut commands

Add helper functions to your PowerShell profile:

```powershell
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content $PROFILE 'function gemini-chrome-fix { & "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" manual }'
Add-Content $PROFILE 'function gemini-chrome-status { & "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status }'
. $PROFILE
gemini-chrome-fix       # Re-install the extension
gemini-chrome-status    # Check current status
```

## Logs

| Platform | Path |
|----------|------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## License

[MIT](LICENSE)
