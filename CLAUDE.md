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
  → subcommand dispatch (enable, disable, run, manual, status, uninstall)
Auto-trigger Mechanism
  → macOS: two LaunchAgents (boot + file watcher on Chrome Info.plist)
  → Windows: Scheduled Task + registry watch daemon (Win32 RegNotifyChangeKeyValue)
```

### macOS trigger flow
- **Boot Agent** (`com.gemini-chrome-autoinstall.boot.plist`): fires `patch.sh run` at login
- **Watcher Agent** (`com.gemini-chrome-autoinstall.watcher.plist`): monitors Chrome's `Info.plist` changes, fires `patch.sh run`

### Windows trigger flow
- **Scheduled Task** (`GeminiChromeAutoPatch`): fires `patch.ps1 scheduled` at login + every 4 hours
- `scheduled` subcommand: runs poll-based version check, then spawns `watch` daemon
- `watch` daemon: blocks on registry key change for `HKCU:\Software\Google\Chrome\BLBeacon\version`

### Concurrency control (dual-lock)
- **Cooldown lock** (file timestamp, 300s): prevents re-execution within 5 minutes
- **Active lock** (atomic `mkdir`): prevents concurrent patch instances

### Key paths at runtime
| Item | macOS | Windows |
|------|-------|---------|
| Install dir | `~/.gemini-chrome-autoinstall/` | `%USERPROFILE%\.gemini-chrome-autoinstall\` |
| Log | `~/Library/Logs/gemini-chrome-autoinstall.log` | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |
| Cooldown lock | `/tmp/gemini-chrome-autoinstall.lock` | `%TEMP%\gemini-chrome-autoinstall.lock` |
| Active lock | `/tmp/gemini-chrome-autoinstall.active.lock/` | `%TEMP%\gemini-chrome-autoinstall.active.lock\` |

## CI/CD

GitHub Actions release workflow (`.github/workflows/release.yml`):
- Triggers on master push (ignores CHANGELOG.md changes)
- Uses `git-cliff` to auto-detect next semantic version from Conventional Commits
- Creates git tag, GitHub Release with generated notes, and commits updated CHANGELOG.md
- Config in `cliff.toml`: emoji prefix stripping, skip docs/chore/style/test/ci commits

## Commit Convention

Conventional Commits with emoji prefix: `🎉 feat:`, `🐛 fix:`, `♻️ refactor:`, `🔧 chore:`, `📝 docs:`, `⚡ perf:`

## Windows-specific: `patch.ps1` extra subcommands

- `watch` — registry listener daemon (not in macOS version)
- `scheduled` — task scheduler entry point with self-healing (restarts watch if dead)
