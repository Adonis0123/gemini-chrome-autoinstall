# AGENTS.md

This file is the repository-level instruction source for Codex and other coding agents working in this repo.

## Communication Rules

- Always reply to the user in Chinese.
- For GitHub PR reviews, inline review comments, summary comments, and follow-up replies, use Chinese by default.
- Keep code, commit messages, file names, workflow names, and command examples in English.
- Be direct and technical. Do not add performative praise in review replies.

## Repository Truth

This project is a cross-platform state-driven repair wrapper around [Gemini-in-Chrome](https://github.com/appsail/Gemini-in-Chrome).

The tool does **not** treat “Chrome version changed” as the truth source. Version changes are only signals. The truth source is Chrome's `Local State`.

Primary states:

- `healthy`
- `drifted`
- `unknown`
- `pending`

Core rule:

- Never force-write while Chrome is running.
- If drift is detected while Chrome is running, record `pending` and retry later.

## Current Architecture

Three layers per platform:

```text
Installer (install.sh / install.ps1)
  -> download scripts, register startup hooks, expose tool version
Core Script (patch.sh / patch.ps1)
  -> detect state, reconcile drift, maintain pending metadata, expose status
Trigger Layer
  -> macOS: LaunchAgents
  -> Windows: Run key + registry watcher
```

### macOS

Current LaunchAgents:

- `com.gemini-chrome-autoinstall.boot`
- `com.gemini-chrome-autoinstall.watcher`
- `com.gemini-chrome-autoinstall.retry`
- `com.gemini-chrome-autoinstall.fallback`

Current behavior:

- `boot` runs `patch.sh run` at login
- `watcher` reacts to Chrome metadata changes
- `retry` runs while `pending` exists
- `fallback` runs a low-frequency reconcile pass

### Windows

Current startup/watch behavior:

- Run key: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\GeminiChromeAutoPatch`
- Startup entrypoint: `patch.ps1 scheduled`
- Background watcher: `patch.ps1 watch`
- Registry version source: `HKCU:\Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}\pv`

Do **not** reintroduce the old `BLBeacon\version` watcher model unless explicitly asked.

## Runtime Files

### macOS

- Install dir: `~/.gemini-chrome-autoinstall/`
- Pending metadata: `~/.gemini-chrome-autoinstall/pending`
- Last healthy version: `~/.gemini-chrome-autoinstall/patched-version.txt`
- Last result metadata: `~/.gemini-chrome-autoinstall/last-result`
- Log: `~/Library/Logs/gemini-chrome-autoinstall.log`
- Active lock: `/tmp/gemini-chrome-autoinstall.active.lock/`

### Windows

- Install dir: `%USERPROFILE%\.gemini-chrome-autoinstall\`
- Pending metadata: `%USERPROFILE%\.gemini-chrome-autoinstall\pending`
- Last healthy version: `%USERPROFILE%\.gemini-chrome-autoinstall\patched-version.txt`
- Last result metadata: `%USERPROFILE%\.gemini-chrome-autoinstall\last-result`
- Log: `%LOCALAPPDATA%\gemini-chrome-autoinstall.log`
- Active lock: `%TEMP%\gemini-chrome-autoinstall.active.lock\`

## State Detection Rules

Current detection logic is based on `Local State` fields such as:

- `variations_country`
- `variations_permanent_consistency_country`
- `profile.info_cache.*.is_glic_eligible`

Behavioral expectations:

- missing file / invalid JSON / missing required fields -> `unknown`
- explicit rollback signals -> `drifted`
- only proven-good states -> `healthy`

Do not weaken `unknown` into `healthy`.

## Concurrency Rules

- Active lock is the only concurrency primitive.
- Do not reintroduce cooldown-lock behavior.
- Stale lock recovery must remain PID-aware.

## Testing Rules

This repo now has fixture-based tests.

Key local verification commands:

### macOS / shell

```bash
bash tests/macos/run-tests.sh
bash -n patch.sh
```

### Windows / PowerShell

```powershell
pwsh -NoLogo -NoProfile -File tests/windows/run-tests.ps1
pwsh -NoLogo -NoProfile -Command "[void][scriptblock]::Create((Get-Content patch.ps1 -Raw))"
```

### Workflow validation

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/test.yml")'
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml")'
```

When claiming work is complete, prefer fresh verification evidence over assumptions.

## Release Workflow Notes

Release workflow lives in `.github/workflows/release.yml`.

Current expectations:

- `VERSION` is a real source-of-truth file and must stay synchronized with releases
- release commit must land before tagging
- tag should point to the commit that already contains `VERSION` and `CHANGELOG` updates

## Commit Convention

Use Conventional Commits with emoji prefixes:

- `🎉 feat:`
- `🐛 fix:`
- `♻️ refactor:`
- `🔧 chore:`
- `📝 docs:`
- `⚡ perf:`
- `✅ test:`

## Review Priorities

When reviewing code, prioritize:

1. behavior regressions
2. incorrect state transitions
3. missing verification after patching
4. broken retry / pending semantics
5. test gaps that leave state transitions unguarded

Only after that, comment on style or cleanup.

## What Not To Reintroduce

Unless explicitly requested, do not bring back outdated concepts from older iterations of this repo:

- extension-removal wording as the primary product model
- cooldown lock / “wait 10 minutes” flow
- Windows `BLBeacon` watcher as the main source
- “patch succeeds if installer exits 0” without state verification

## Documentation Consistency

When changing behavior, keep these aligned:

- `README.md`
- `docs/design.md`
- `.github/workflows/*` if verification or release semantics changed

## Practical Guidance For Agents

- Prefer small, behavior-focused commits.
- Preserve platform symmetry where it improves maintainability, but do not force identical implementations across Bash and PowerShell.
- For Windows runner changes, expect local `pwsh` to be unavailable in some environments; in that case, use CI results as verification evidence where appropriate.
