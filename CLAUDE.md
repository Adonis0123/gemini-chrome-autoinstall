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
- `watch` daemon: async `RegNotifyChangeKeyValue` with 60s timeout on `HKCU:\Software\Google\Chrome\BLBeacon`, checks pending on each timeout

### Version-based skip (replaces cooldown)
- Compares Chrome's current version against `patched-version.txt`
- If versions match → skip (already patched for this version)
- If versions differ → needs patching

### Pending-retry mechanism
- When Chrome is running during trigger → create `pending` flag file → exit immediately (no waiting)
- macOS: KeepAlive retry agent detects pending file, retries every 60s until Chrome closes
- Windows: watch daemon timeout loop checks pending every 60s

### Concurrency control
- **Active lock** (atomic `mkdir`): prevents concurrent patch instances, with PID-based stale lock recovery

### Key paths at runtime
| Item | macOS | Windows |
|------|-------|---------|
| Install dir | `~/.gemini-chrome-autoinstall/` | `%USERPROFILE%\.gemini-chrome-autoinstall\` |
| Log | `~/Library/Logs/gemini-chrome-autoinstall.log` | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |
| Active lock | `/tmp/gemini-chrome-autoinstall.active.lock/` | `%TEMP%\gemini-chrome-autoinstall.active.lock\` |
| Pending flag | `~/.gemini-chrome-autoinstall/pending` | `%USERPROFILE%\.gemini-chrome-autoinstall\pending` |
| Patched version | `~/.gemini-chrome-autoinstall/patched-version.txt` | `%USERPROFILE%\.gemini-chrome-autoinstall\patched-version.txt` |

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
