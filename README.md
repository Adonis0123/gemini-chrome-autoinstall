# Gemini Chrome AutoInstall

Automatically re-install the [Gemini-in-Chrome](https://github.com/nicepkg/Gemini-in-Chrome) extension after Chrome updates, so you never lose it.

## Features

- **Auto-patch on boot** — runs the install script once after every login
- **Auto-patch on update** (macOS) — watches Chrome's `Info.plist` for changes and triggers a reinstall
- **Safe execution** — waits for Chrome to close before patching; times out after 10 minutes
- **Deduplication** — lock file prevents repeated runs within 5 minutes
- **Cross-platform** — macOS (LaunchAgents) and Windows (Scheduled Tasks)

## Quick Start

### macOS

```bash
git clone https://github.com/<your-username>/gemini-chrome-autoinstall.git
cd gemini-chrome-autoinstall
chmod +x patch.sh

# Enable auto-patching
./patch.sh enable

# Check status
./patch.sh status

# Run manually (waits for Chrome to close)
./patch.sh run

# Disable auto-patching
./patch.sh disable
```

### Windows (PowerShell as Administrator)

```powershell
git clone https://github.com/<your-username>/gemini-chrome-autoinstall.git
cd gemini-chrome-autoinstall

# Enable auto-patching
.\patch.ps1 enable

# Check status
.\patch.ps1 status

# Run manually
.\patch.ps1 run

# Disable auto-patching
.\patch.ps1 disable
```

## How It Works

### macOS

Two LaunchAgents are dynamically generated and loaded into `~/Library/LaunchAgents/`:

| Agent | Trigger | Purpose |
|-------|---------|---------|
| `com.gemini-chrome-autoinstall.boot` | Login (`RunAtLoad`) | Patch once after every boot |
| `com.gemini-chrome-autoinstall.watcher` | Chrome `Info.plist` change | Patch after Chrome updates |

Both agents call `patch.sh run`, which waits for Chrome to close, then downloads and executes the upstream install script.

### Windows

A Scheduled Task (`GeminiChromeAutoPatch`) is registered to run at logon. It calls `patch.ps1 run` with the same wait-and-patch logic.

## Commands

| Command | Description |
|---------|-------------|
| `enable` | Install and load LaunchAgents (macOS) / register Scheduled Task (Windows) |
| `disable` | Unload and remove LaunchAgents / unregister Scheduled Task |
| `status` | Show current agent/task status and last run time |
| `run` | Execute the patch immediately (waits for Chrome to close) |

## Logs

| Platform | Log path |
|----------|----------|
| macOS | `~/Library/Logs/gemini-chrome-autoinstall.log` |
| Windows | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |

## License

[MIT](LICENSE)
