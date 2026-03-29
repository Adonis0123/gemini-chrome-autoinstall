# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-platform auto-patch tool that automatically reinstalls the Gemini-in-Chrome extension after Chrome updates. Pure shell scripting project — Bash for macOS, PowerShell for Windows. No package.json, no build system, no test framework.

## Architecture

Three-layer design per platform:

```
Installer (install.sh / install.ps1)
  → downloads + enables
Core Script (patch.sh / patch.ps1)
  → subcommand dispatch (enable, disable, run, retry, manual, status, uninstall)
Auto-trigger Mechanism
  → macOS: three LaunchAgents (boot + file watcher + KeepAlive retry)
  → Windows: Registry Run key + registry watch daemon (async Win32 RegNotifyChangeKeyValue)
```

### macOS trigger flow
- **Boot Agent** (`com.gemini-chrome-autoinstall.boot.plist`): fires `patch.sh run` at login
- **Watcher Agent** (`com.gemini-chrome-autoinstall.watcher.plist`): monitors Chrome's `Info.plist` changes, fires `patch.sh run`
- **Retry Agent** (`com.gemini-chrome-autoinstall.retry.plist`): KeepAlive with PathState on `pending` file, fires `patch.sh retry` every 60s while pending exists

### Windows trigger flow
- **Registry Run key** (`GeminiChromeAutoPatch`): fires `patch.ps1 scheduled` at login
- `scheduled` subcommand: checks pending installs, then spawns `watch` daemon
- `watch` daemon: async `RegNotifyChangeKeyValue` with 60s timeout on Chrome's Google Update registry key (`pv` value), checks pending on each timeout. Auto-detects correct hive at startup: probes HKCU → HKLM → HKLM\WOW6432Node.

### State-driven detection (tri-state)
- Reads Chrome's `Local State` JSON to determine patch health
- Three states: `healthy` (all fields correct), `drifted` (needs patching), `unknown` (can't determine)
- Checks: `variations_country`, `variations_permanent_consistency_country`, `is_glic_eligible`

### Pending-retry mechanism
- When Chrome is running during trigger → create `pending` flag file → exit immediately (no waiting)
- macOS: KeepAlive retry agent detects pending file, retries every 60s until Chrome closes
- Windows: watch daemon timeout loop checks pending every 60s

### Self-update mechanism
- Triggered at the start of `run` (macOS) and `run`/`scheduled` (Windows)
- Fetches `VERSION` from `raw.githubusercontent.com`, compares with local
- If different, downloads new script files to temp dir, then moves to install dir
- 24h cooldown via `last-update-check` timestamp file
- Network failures are logged and silently skipped — never blocks core patch logic

### Concurrency control
- **Active lock** (atomic `mkdir`): prevents concurrent patch instances, with PID-based stale lock recovery

### Chrome version detection (Windows)
- Probes registry in order: HKCU → HKLM → HKLM\WOW6432Node under `Software\Google\Update\Clients\{8A69D345-...}\pv`
- Falls back to `Local State` file's `last_version` field
- System-wide Chrome installs store version in HKLM, not HKCU

### Install directory derivation
- `patch.sh`: `INSTALL_DIR` = `$GEMINI_INSTALL_DIR` or `$SCRIPT_DIR` (script's own directory)
- `patch.ps1`: `$InstallDir` = `$env:GEMINI_INSTALL_DIR` or `$PSScriptRoot`
- `install.sh`/`install.ps1`: defaults to `~/.gemini-chrome-autoinstall` when creating the install

### Key paths at runtime
| Item | macOS | Windows |
|------|-------|---------|
| Install dir | `~/.gemini-chrome-autoinstall/` | `%USERPROFILE%\.gemini-chrome-autoinstall\` |
| Log | `~/Library/Logs/gemini-chrome-autoinstall.log` | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |
| Active lock | `/tmp/gemini-chrome-autoinstall.active.lock/` | `%TEMP%\gemini-chrome-autoinstall.active.lock\` |
| Pending flag | `$INSTALL_DIR/pending` | `$InstallDir\pending` |
| Last result | `$INSTALL_DIR/last-result` | `$InstallDir\last-result` |
| Patched version | `$INSTALL_DIR/patched-version.txt` | `$InstallDir\patched-version.txt` |
| Update check | `$INSTALL_DIR/last-update-check` | `$InstallDir\last-update-check` |

## CI/CD

GitHub Actions release workflow (`.github/workflows/release.yml`):
- Triggers on master push (ignores CHANGELOG.md changes)
- Uses `git-cliff` to auto-detect next semantic version from Conventional Commits
- Creates git tag, GitHub Release with generated notes, and commits updated CHANGELOG.md
- Config in `cliff.toml`: emoji prefix stripping, skip docs/chore/style/test/ci commits

## Commit Convention

Conventional Commits with emoji prefix: `🎉 feat:`, `🐛 fix:`, `♻️ refactor:`, `🔧 chore:`, `📝 docs:`, `⚡ perf:`

## Windows-specific: `patch.ps1` extra subcommands

- `watch` — async registry listener daemon with 60s timeout for pending retry
- `scheduled` — startup entry point: checks pending installs, then ensures watch daemon is running
