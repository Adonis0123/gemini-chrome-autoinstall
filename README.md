# Gemini Chrome AutoInstall

Every time Chrome updates, the [Gemini-in-Chrome](https://github.com/nicepkg/Gemini-in-Chrome) extension gets removed. This tool brings it back automatically — set it once, forget it forever.

## Install

**macOS** — open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/main/install.sh | bash
```

**Windows** — open PowerShell **as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/Adonis0123/gemini-chrome-autoinstall/main/install.ps1 | iex
```

Done. It will run automatically in the background from now on.

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

### Safety

- Waits for Chrome to close before patching (up to 10 min)
- Lock file prevents repeated runs within 5 minutes

## Commands

You can run these manually after installation:

```bash
# macOS
~/.gemini-chrome-autoinstall/patch.sh status     # Check if it's running
~/.gemini-chrome-autoinstall/patch.sh run         # Patch now (waits for Chrome to close)
~/.gemini-chrome-autoinstall/patch.sh disable     # Stop auto-patching (keep files)
~/.gemini-chrome-autoinstall/patch.sh enable      # Re-enable auto-patching
~/.gemini-chrome-autoinstall/patch.sh uninstall   # Remove everything
```

```powershell
# Windows (PowerShell as Administrator)
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" status
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" run
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" disable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" enable
& "$env:USERPROFILE\.gemini-chrome-autoinstall\patch.ps1" uninstall
```

## Logs

| Platform | Path |
|----------|------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## License

[MIT](LICENSE)
