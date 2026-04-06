# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Bug Fixes

- *(windows)* Make watcher detection robust to empty CommandLine([5bced30](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/5bced3026a2bc524a15423b0394362ece834eb18))
- *(windows)* Validate PID ownership before killing watcher([26bc82d](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/26bc82d411e5fb84c8e3bcb432f46d0b43008e4a))
- *(windows)* Gate Update-Self watcher kill, fail closed on StartTime errors([9fb0ffd](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/9fb0ffd5ced15e42e101f0401d880dae29b97d29))
- *(windows)* Identity-match watcher via PID + StartTime.Ticks([00bc52c](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/00bc52c25c1636f6d46e5700631e6d04ca412168))
- *(windows)* Consolidate watcher identification on $InstallDir([5c3d640](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/5c3d64034d0fd4b4d4bc52a10e94f64fa74d9807))
## [0.6.1] - 2026-04-01

### Bug Fixes

- Add AbandonProcessGroup to all LaunchAgents and kill watcher on disable([e0b2d0a](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/e0b2d0a8f09fb7be7dbae55cd048887b4de268c7))
- Guard watcher pid-file reads against TOCTOU race([d020b0d](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/d020b0d90834764ac305a6ef83f71bd20b0807d2))
- Auto-refresh LaunchAgent plists after self-update([d16b2bc](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/d16b2bc165eb4c1ce028737891f0b900f5f88c28))
- Prevent plist refresh reentry storm and unblock patch flow([7a7d68b](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/7a7d68b40476e8ecb988d11520b3a8541ed9acb9))
- Write plist-version after load, use marker to prevent reentry([a921be9](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/a921be96f8cdcf2f9fa08f45c8eeab79b0d3830b))
## [0.6.0] - 2026-03-30

### Features

- *(macos)* Add watcher-based retry — spawn background watcher when Chrome is running([df9ab50](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/df9ab501b2573c23ffde81dfb7b2bbb8c58d457f))
- *(windows)* Reduce RetryInterval 60→10, remove backoff logic([b555842](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/b5558424575555c4d1f9d4d621323a205c53848f))

### Bug Fixes

- Use GEMINI_CHROME_RUNNING_FILE for watcher tests([8ee7284](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/8ee72849bbc00f429e9950943ee2dc75ab480abd))
- *(macos)* Ensure INSTALL_DIR exists before self-update check, harden watcher lifecycle([8d84f48](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/8d84f4825c7131cb25b03f894c6a582820917674))
- *(windows)* Prevent duplicate watch daemons via PID file lock([01e03c5](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/01e03c56a7c525a28de41c80d1119605bfa5f7ab))
- Harden watcher PID checks and remove redundant call([5a20f5e](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/5a20f5e4d910dc9f6a344c5ec7cc51730a966bc2))
## [0.5.2] - 2026-03-29

### Bug Fixes

- Correct repository URL in cliff.toml from nicepkg to Adonis0123([d9be03c](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/d9be03cad0c046d3638c2e2aad42988f8b9b9a9a))
## [0.5.1] - 2026-03-29

### Bug Fixes

- Replace Python HTTP server with PowerShell HttpListener in self-update tests([37e5124](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/37e51249b953d65bc0a2256422a60ee67def9bd9))
## [0.5.0] - 2026-03-29

### Features

- *(mac)* Add RAW_BASE variable for self-update([6e17ba7](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/6e17ba706c20807eabc4b27ec3f4f48c63c14636))
- *(mac)* Add check_self_update function and call from cmd_run([6982b99](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/6982b992b84ad205129b01cfe66dea52a541152e))
- *(win)* Add RawBase variable for self-update([5f6a680](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/5f6a6806bcfa055b539e2066167d0b94ebb1ebd5))
- *(win)* Add Update-Self function and call from Invoke-Run and Invoke-Scheduled([9a9b4f7](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/9a9b4f7983a017088240dbc7da8d66874dee2fd2))

### Bug Fixes

- Update same fixtures to match current VERSION after rebase([7396160](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/73961604253d75d6f1a32cc231735a5a5ad4cb71))
## [0.4.2] - 2026-03-29

### Refactoring

- Replace periodic reconcile with Chrome close detection([18c6fc5](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/18c6fc53d4df2973b6fa7c06eee1ad5822613cb9))
## [0.4.1] - 2026-03-29

### Bug Fixes

- Add post-patch delay and periodic watcher reconcile([59cf2d6](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/59cf2d660e76ab3a12035db79fd756e400f5c28f))
## [0.4.0] - 2026-03-29

### Features

- Make shortcut commands available immediately after install([0e252b9](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/0e252b9c17c5e3d195f8886a5049f1d51441d913))
## [0.3.0] - 2026-03-29

### Features

- Show descriptive process name in macOS Activity Monitor([98667fb](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/98667fb16e2a1a7486c6a0d99f5d7ca13fb12e8c))
## [0.2.4] - 2026-03-29

### Bug Fixes

- Stop old watcher and start fresh one during install([41f4d5e](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/41f4d5e6963307fe17087ac73c437ed29025119e))
## [0.2.3] - 2026-03-29

### Bug Fixes

- Use staged Chrome shutdown in manual command([bd2cef6](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/bd2cef6429fb2fafc631d8952c2809e12663fa5a))
## [0.2.2] - 2026-03-29

### Bug Fixes

- Detect Chrome version from HKLM and WOW6432Node registry paths([3903cc4](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/3903cc436d8fa30ec04f1cfac36714ff2e6f7b2c))
## [0.2.1] - 2026-03-29

### Bug Fixes

- Pass tag to git-cliff so release notes show version instead of Unreleased([0ff9248](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/0ff924851e58bb6f5cc105351ce4c4d4fb2f2028))
## [0.2.0] - 2026-03-29

### Features

- Add shared version and runtime metadata plumbing([b7888d8](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/b7888d833932618ff673494c0332103dbecc4926))
- Add macos tri-state patch detection([d143c9b](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/d143c9b196b41860326f5fe4858206b4e1728e61))
- Add macos state-driven reconcile loop([9b76e71](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/9b76e716ccb2e732b9e843d131964ab8ceaacd2b))
- Add windows state-driven reconcile loop([590b357](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/590b357960972a293449868a6ecb221381939708))

### Bug Fixes

- Resolve windows test runner repo root([6a095ef](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/6a095ef47c738fd80420686ee170bfd256180d7a))
- Harden core install override seams([0ffea9b](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/0ffea9b4a0dc7d4e1145a3afd50afa661702acf5))
- Restore macos drifted install path in run/retry([83e0349](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/83e0349bd3a531d6a60cc01718d743a3c198c3cd))
- Tighten macos tri-state unknown and drift mapping([32c08f9](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/32c08f9365137ef10f15022f624dad158ae8b760))
- Resolve windows runner repo root in ci([79afd77](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/79afd77c2ee3a486d0b59ea1e9e612922ef6c37b))
- Stabilize windows install and test flows([8d76874](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/8d76874cdebed91ca1bc002d680a1a15019afd05))
- Tag release commit after version sync([8e6a3fd](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/8e6a3fdf8b74a6ee47c168e36829ac15d3c5f2cf))
- Address review feedback across patch flows([805c272](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/805c272d335aabb38eee4588b8a5e4199c6c4b40))
- Address code review issues across patch flows([059352a](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/059352a0b0a6727e8b2a4ff45b3a6b3eeecb0cfe))
- Show Chrome running state in status output([88bf8ae](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/88bf8ae0f660b061e0227417a8bfa24d54c36e13))
- Deterministic release tag and dynamic install paths([2a84a2e](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/2a84a2e9bf94aa31de42440bd0b1a6afb6308665))
- Use dynamic INSTALL_DIR in recovery hint instead of hardcoded path([fc1a12c](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/fc1a12caf70a9a7c042ebdb2a4ec04a8c0e6059b))
- Derive install dir from script location and check first-patch result([b3a2cab](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/b3a2cabadec278e357211f7d2c3165578816eba3))

### Refactoring

- Centralize macos state mapping and verify post-install health([f533426](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/f533426ee5bbf0ad9dc30cc8a7f7c524facfa422))
## [0.1.3] - 2026-03-26

### Bug Fixes

- *(trigger)* Replace cooldown with version-based skip and pending-retry mechanism([af0c9b4](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/af0c9b41e79dcc36371ef99b9e9e7ce3f5b47ae9))
## [0.1.2] - 2026-03-18

### Bug Fixes

- *(lock)* Recover stale active locks via PID-based liveness check([16732f7](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/16732f71c43137265cb86d72e8399c0028243356))
## [0.1.1] - 2026-03-18

### Bug Fixes

- *(install)* Read user input from /dev/tty in manual mode([8b0612f](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/8b0612f19ebb0b8462b054f826b4c4b01257b322))
## [0.1.0] - 2026-03-18

### Features

- *(install)* Run first-time patch automatically after installation([81363f2](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/81363f28d53c869e3621f03272e2f44833aea1e7))
## [0.0.2] - 2026-03-11

### Bug Fixes

- Replace schtasks with HKCU Registry Run key to eliminate admin requirement([67a0017](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/67a001713ff6bed7d59ef0ce460718187d93b977))
## [0.0.1] - 2026-03-11

### Refactoring

- Replace *-ScheduledTask cmdlets with schtasks.exe to eliminate admin dependency([fc812e3](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/fc812e33cfa3c516993c8a62d5a549d8e3c5c1d0))
## [0.0.0] - 2026-03-11

### Features

- Initial project setup for Gemini Chrome auto-install([5a4a949](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/5a4a949b72fd057adcc49bc62aba9a930ecb0e1b))
- Add one-line installer scripts and uninstall command([50ce84b](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/50ce84b858f90f69429db53209c3932bb4adb887))
- Add manual fix command and refactor patch scripts([3b085ca](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/3b085cae55c64b0cd213d0d854d1203f9c5ed972))
- Enhance status reporting in patch scripts([902aa6a](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/902aa6af050b957671cdf24ede87b157b96507d7))
- Add cleanup for stale locks in installation scripts([a2f6a46](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/a2f6a469a4e9650cafcb23e30a047f07d231fc23))
- Improve installation script robustness and reporting([e819827](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/e819827c19c174dd8b0e2f75f711bd0cf2f80fe8))
- Refactor alias commands in README to functions for improved usability([e3661fe](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/e3661fe0de034a470d82924b7cebb8c8a76e325f))
- Enhance PowerShell profile integration and status reporting([eaf1b0d](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/eaf1b0d9c83149fec73b71f2c113e705bb736d96))
- Add Windows registry watcher and Chrome close confirmation([7949be6](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/7949be69d6bec1310ba9bc2a492c1acc74072177))
- Add Chrome reopening functionality after successful patching([b46ba91](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/b46ba918396cb47ab876c13b3487a13f693d6136))
- Add changelog automation and scheduled task self-healing([ac4cf0d](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/ac4cf0dead2bc441d2c15e50ef6e179fbee7e551))

### Bug Fixes

- Register scheduled task under current user to avoid admin requirement([669e1ef](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/669e1eff55ad3a3d90d082e98205b19c3a95a9e1))
- *(release)* Handle first release with no existing tags([4c0b370](https://github.com/Adonis0123/gemini-chrome-autoinstall/commit/4c0b370c91466ff3023e70836896c057989d7021))
