# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-18

### Features

- *(install)* Run first-time patch automatically after installation([81363f2](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/81363f28d53c869e3621f03272e2f44833aea1e7))
## [0.0.2] - 2026-03-11

### Bug Fixes

- Replace schtasks with HKCU Registry Run key to eliminate admin requirement([67a0017](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/67a001713ff6bed7d59ef0ce460718187d93b977))
## [0.0.1] - 2026-03-11

### Refactoring

- Replace *-ScheduledTask cmdlets with schtasks.exe to eliminate admin dependency([fc812e3](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/fc812e33cfa3c516993c8a62d5a549d8e3c5c1d0))
## [0.0.0] - 2026-03-11

### Features

- Initial project setup for Gemini Chrome auto-install([5a4a949](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/5a4a949b72fd057adcc49bc62aba9a930ecb0e1b))
- Add one-line installer scripts and uninstall command([50ce84b](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/50ce84b858f90f69429db53209c3932bb4adb887))
- Add manual fix command and refactor patch scripts([3b085ca](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/3b085cae55c64b0cd213d0d854d1203f9c5ed972))
- Enhance status reporting in patch scripts([902aa6a](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/902aa6af050b957671cdf24ede87b157b96507d7))
- Add cleanup for stale locks in installation scripts([a2f6a46](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/a2f6a469a4e9650cafcb23e30a047f07d231fc23))
- Improve installation script robustness and reporting([e819827](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/e819827c19c174dd8b0e2f75f711bd0cf2f80fe8))
- Refactor alias commands in README to functions for improved usability([e3661fe](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/e3661fe0de034a470d82924b7cebb8c8a76e325f))
- Enhance PowerShell profile integration and status reporting([eaf1b0d](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/eaf1b0d9c83149fec73b71f2c113e705bb736d96))
- Add Windows registry watcher and Chrome close confirmation([7949be6](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/7949be69d6bec1310ba9bc2a492c1acc74072177))
- Add Chrome reopening functionality after successful patching([b46ba91](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/b46ba918396cb47ab876c13b3487a13f693d6136))
- Add changelog automation and scheduled task self-healing([ac4cf0d](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/ac4cf0dead2bc441d2c15e50ef6e179fbee7e551))

### Bug Fixes

- Register scheduled task under current user to avoid admin requirement([669e1ef](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/669e1eff55ad3a3d90d082e98205b19c3a95a9e1))
- *(release)* Handle first release with no existing tags([4c0b370](https://github.com/nicepkg/gemini-chrome-autoinstall/commit/4c0b370c91466ff3023e70836896c057989d7021))
