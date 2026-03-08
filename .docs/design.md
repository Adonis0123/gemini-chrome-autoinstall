# Gemini Chrome AutoInstall — 设计方案

## 1. 项目概述

### 解决的问题

Chrome 浏览器在自动更新后，会移除通过非官方渠道安装的扩展（如 Gemini-in-Chrome）。用户每次 Chrome 更新后都需要手动重新安装扩展，体验极差。

### 核心策略

```
Chrome 更新 → 自动检测更新事件 → 等待 Chrome 关闭 → 重新安装扩展
```

### 设计目标

- **自动化**：无需用户手动干预，后台自动完成扩展恢复
- **幂等性**：脚本可安全重复执行，不会产生副作用
- **安全性**：完善的锁机制和超时保护，避免资源竞争和死锁
- **跨平台**：支持 macOS 和 Windows，行为一致

---

## 2. 整体架构

### 系统架构图

```
┌─────────────────────────────────────────────────────────┐
│                      用户操作                            │
│                                                         │
│   curl ... | bash          PowerShell ... | iex          │
│        ↓                          ↓                      │
│   install.sh                 install.ps1                 │
│   (macOS 安装器)             (Windows 安装器)             │
│        │                          │                      │
│        ├── 清理旧锁               ├── 清理旧锁            │
│        ├── 下载 patch.sh          ├── 下载 patch.ps1      │
│        └── 调用 enable            └── 调用 enable         │
│              ↓                          ↓                │
│        patch.sh enable          patch.ps1 enable         │
│              │                          │                │
│              ├── Boot Agent             ├── Scheduled    │
│              │   (登录触发)              │   Task         │
│              └── Watcher Agent          │   (登录触发)    │
│                  (文件监控触发)           │                │
│                    ↓                    ↓                │
│              patch.sh run         patch.ps1 run          │
│                    │                    │                │
│                    ├── 冷却锁检查        ├── 冷却锁检查    │
│                    ├── 互斥锁获取        ├── 互斥锁获取    │
│                    ├── 等待 Chrome       ├── 等待 Chrome   │
│                    └── 执行核心安装      └── 执行核心安装   │
│                          ↓                    ↓          │
│              appsail/Gemini-in-Chrome install 脚本        │
└─────────────────────────────────────────────────────────┘
```

### 双平台架构对比

| 维度 | macOS | Windows |
|------|-------|---------|
| 安装器 | `install.sh` (bash) | `install.ps1` (PowerShell) |
| 补丁脚本 | `patch.sh` (bash) | `patch.ps1` (PowerShell) |
| 触发机制 | LaunchAgent × 2 | Scheduled Task × 1 |
| 启动触发 | `RunAtLoad=true` | `AtLogOn` |
| 更新检测 | `WatchPaths`（文件监控） | 无（仅登录触发） |
| Chrome 检测 | `pgrep -x "Google Chrome"` | `Get-Process chrome` |
| 日志路径 | `~/Library/Logs/` | `%LOCALAPPDATA%/` |

### 文件结构

```
gemini-chrome-autoinstall/
├── install.sh       # macOS 一键安装器：下载 patch.sh 并注册自动任务
├── install.ps1      # Windows 一键安装器：下载 patch.ps1 并注册自动任务
├── patch.sh         # macOS 核心控制脚本：6 个子命令
├── patch.ps1        # Windows 核心控制脚本：6 个子命令
├── README.md        # 用户文档
└── LICENSE          # MIT 许可证
```

安装后本地文件结构：

```
# macOS
~/.gemini-chrome-autoinstall/
└── patch.sh                                              # 控制脚本
~/Library/LaunchAgents/
├── com.gemini-chrome-autoinstall.boot.plist               # 启动 Agent
└── com.gemini-chrome-autoinstall.watcher.plist             # 监控 Agent
~/Library/Logs/
└── gemini-chrome-autoinstall.log                          # 日志文件

# Windows
%USERPROFILE%\.gemini-chrome-autoinstall\
└── patch.ps1                                              # 控制脚本
%LOCALAPPDATA%\
└── gemini-chrome-autoinstall.log                          # 日志文件
# Scheduled Task: "GeminiChromeAutoPatch"                  # 计划任务（-WindowStyle Hidden）
# $PROFILE 中注册 gemini-chrome-fix / gemini-chrome-status 快捷函数
```

### 外部依赖

| 依赖 | 用途 | 来源 |
|------|------|------|
| Gemini-in-Chrome install.sh | macOS 核心扩展安装脚本 | `appsail/Gemini-in-Chrome` (main 分支) |
| Gemini-in-Chrome install.ps1 | Windows 核心扩展安装脚本 | `appsail/Gemini-in-Chrome` (main 分支) |

---

## 3. 安装模块 (install.sh / install.ps1)

### 职责

一键完成所有安装工作：下载补丁脚本 → 注册自动任务 → 注册快捷函数（Windows）→ 显示使用指南。

### 幂等性设计

安装器可安全重复执行，执行流程：

```
1. 清理旧锁（防止上次异常退出残留的锁）
   ├── macOS:  rmdir /tmp/gemini-chrome-autoinstall.active.lock
   └── Windows: Remove-Item $ActiveLock -ErrorAction SilentlyContinue

2. 创建安装目录（-Force / -p 确保幂等）
   ├── macOS:  mkdir -p ~/.gemini-chrome-autoinstall
   └── Windows: New-Item -ItemType Directory -Force

3. 下载 patch 脚本（覆盖旧文件）
   ├── macOS:  curl -fsSL ... -o patch.sh && chmod +x
   └── Windows: Invoke-WebRequest ... -OutFile patch.ps1

4. 调用 patch enable（内部也是幂等的）
   ├── macOS:  先 unload 再 load LaunchAgents
   └── Windows: Register-ScheduledTask -Force（覆盖注册）

5. 注册 Profile 快捷函数（仅 Windows）
   └── Windows: 检查 $PROFILE 中是否已有 gemini-chrome-fix / gemini-chrome-status
       ├── 不存在 → Add-Content 追加函数定义（带 `n 前缀确保换行）
       └── 已存在 → 跳过，幂等安全
```

### 安装流程图

```
用户执行一键安装命令
        ↓
  清理残留锁文件
        ↓
  创建安装目录
        ↓
  下载 patch 脚本
        ↓
  调用 patch enable
        ↓
  输出安装成功信息
  (含可用命令列表)
```

---

## 4. 补丁模块 (patch.sh / patch.ps1)

### 子命令设计

| 命令 | 用途 | 触发方式 | 关键特性 |
|------|------|----------|----------|
| `enable` | 注册并启动后台自动任务 | 安装时 / 用户手动 | 幂等：先卸载再加载 |
| `disable` | 停止后台自动任务 | 用户手动 | 移除 Agent/Task 但保留脚本 |
| `status` | 显示系统状态 | 用户手动 | 只读，不修改任何状态 |
| `run` | 带锁和等待的完整补丁流程 | 自动触发 | 冷却锁 + 互斥锁 + Chrome 等待 |
| `manual` | 快速手动补丁 | 用户手动 | 跳过冷却、要求 Chrome 已关闭 |
| `uninstall` | 完全卸载 | 用户手动 | 移除所有文件和自动任务 |

### 并发控制机制

系统使用**双锁机制**确保安全：

#### Active Lock（互斥锁）

- **类型**：目录锁（利用 `mkdir` 的原子性）
- **路径**：`/tmp/gemini-chrome-autoinstall.active.lock/`（macOS）或 `%TEMP%\gemini-chrome-autoinstall.active.lock\`（Windows）
- **目的**：防止同一时刻多个 patch 实例并发执行

```
获取锁：mkdir <lock_dir>
  ├── 成功（返回 0）：获得锁，继续执行
  └── 失败（目录已存在）：其他实例正在运行，放弃执行

释放锁：rmdir <lock_dir>
  └── 通过 trap EXIT / try-finally 确保释放
```

#### Cooldown Lock（冷却锁）

- **类型**：普通文件（利用文件修改时间戳）
- **路径**：`/tmp/gemini-chrome-autoinstall.lock`（macOS）或 `%TEMP%\gemini-chrome-autoinstall.lock`（Windows）
- **冷却时长**：300 秒（5 分钟）
- **目的**：防止短时间内重复执行（如 Boot + Watcher 同时触发）

```
检查冷却：
  1. 读取锁文件修改时间
  2. 计算：age = 当前时间 - 修改时间
  3. 若 age < 300s：跳过执行（仍在冷却期内）
  4. 若 age >= 300s 或文件不存在：允许执行

更新冷却：touch <lock_file>（在执行核心安装前更新时间戳）
```

#### 双锁协作流程

```
run 命令触发
    ↓
检查冷却锁 ──→ 5分钟内执行过？──→ 是 → 跳过，记录日志
    ↓ 否
获取互斥锁 ──→ 其他实例运行中？──→ 是 → 跳过，记录日志
    ↓ 否
设置 trap EXIT（确保锁释放）
    ↓
等待 Chrome 关闭
    ↓
更新冷却锁时间戳
    ↓
执行核心安装
    ↓
释放互斥锁（trap 自动触发）
```

### 自动触发机制

#### macOS: 双 LaunchAgent 架构

**Boot Agent**（`com.gemini-chrome-autoinstall.boot.plist`）：
- 触发条件：`RunAtLoad = true`（用户登录时）
- 覆盖场景：Chrome 在关机/注销期间更新
- 执行：`patch.sh run`

**Watcher Agent**（`com.gemini-chrome-autoinstall.watcher.plist`）：
- 触发条件：`WatchPaths = [/Applications/Google Chrome.app/Contents/Info.plist]`
- 覆盖场景：Chrome 在用户会话期间更新
- 执行：`patch.sh run`

两个 Agent 互为补充，冷却锁防止重复执行。

#### Windows: 单 Scheduled Task 架构

**GeminiChromeAutoPatch**：
- 触发条件：`AtLogOn`（用户登录时）
- 设置：`AllowStartIfOnBatteries`、`DontStopIfGoingOnBatteries`、`StartWhenAvailable`
- 执行：`powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File patch.ps1 run`

> **限制**：Windows 无法实时监控文件变化，会话期间的 Chrome 更新需用户手动执行 `manual` 命令。

### Chrome 等待机制

```
waited = 0
WAIT_INTERVAL = 5s
MAX_WAIT = 600s（10 分钟）

while Chrome 正在运行:
    if waited >= MAX_WAIT:
        记录超时日志，放弃执行
        return 1
    记录等待日志："Chrome is running. Waiting... (${waited}s / ${MAX_WAIT}s)"
    sleep 5
    waited += 5
```

Chrome 进程检测方式：
- macOS：`pgrep -x "Google Chrome"`（精确匹配进程名）
- Windows：`Get-Process chrome -ErrorAction SilentlyContinue`

### 状态检测 (status 命令)

| 状态指标 | macOS | Windows |
|----------|-------|---------|
| 后台任务注册 | 检查 `launchctl list` | 检查 `Get-ScheduledTask` |
| Plist/Task 文件 | 检查文件是否存在 | 检查任务是否注册 |
| Chrome 运行状态 | — | `Get-Process chrome` |
| 互斥锁状态 | 检查目录是否存在 | 检查目录是否存在 |
| 冷却锁状态 | 显示距上次运行秒数 | 显示距上次运行秒数 |
| 日志文件路径 | — | 显示 `$LogFile` 路径 |

---

## 5. 安全机制

### 锁机制详解

#### Active Lock + Cooldown Lock 配合

```
场景：Chrome 更新后，Boot Agent 和 Watcher Agent 几乎同时触发

时间线：
  T+0s   Boot Agent 触发 → 检查冷却 → 无冷却 → 获取互斥锁 ✓ → 开始等待 Chrome
  T+1s   Watcher Agent 触发 → 检查冷却 → 无冷却 → 获取互斥锁 ✗ → 跳过执行
  T+30s  Chrome 关闭 → Boot Agent 更新冷却 → 执行核心安装 → 释放互斥锁

场景：核心安装完成后 Watcher 再次触发

时间线：
  T+31s  Watcher 再次触发 → 检查冷却 → 距上次仅 1s（< 300s）→ 跳过执行 ✓
```

### Chrome 等待超时保护

- 最大等待 600 秒（10 分钟），防止无限阻塞
- 超时后记录错误日志并安全退出
- 互斥锁通过 trap/finally 在超时后也能正确释放

### 清理机制

#### macOS: trap EXIT

```bash
cleanup() { rmdir "$ACTIVE_LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT
```

- 无论正常退出、错误退出还是信号中断，都会执行清理
- `rmdir` 只能删除空目录，不会误删文件

#### Windows: try/finally

```powershell
try {
    # 执行逻辑
} finally {
    Remove-Item $ActiveLock -Force -ErrorAction SilentlyContinue
}
```

- `finally` 块确保在异常情况下也释放锁

### 安装器的锁清理

两个安装器都会在启动时主动清理残留的 Active Lock：

```bash
# install.sh
rmdir /tmp/gemini-chrome-autoinstall.active.lock 2>/dev/null || true
```

```powershell
# install.ps1
Remove-Item $ActiveLock -ErrorAction SilentlyContinue
```

这确保了异常退出后重新安装不会被死锁阻塞。

---

## 6. 平台差异对照表

| 特性 | macOS | Windows |
|------|-------|---------|
| **脚本解释器** | bash | PowerShell 5+ |
| **自动触发方式** | LaunchAgent (Boot + Watcher) | Scheduled Task (Boot only) |
| **实时更新检测** | 支持（WatchPaths 监控 Info.plist） | 不支持（需手动 `manual`） |
| **安装目录** | `~/.gemini-chrome-autoinstall/` | `%USERPROFILE%\.gemini-chrome-autoinstall\` |
| **日志路径** | `~/Library/Logs/gemini-chrome-autoinstall.log` | `%LOCALAPPDATA%\gemini-chrome-autoinstall.log` |
| **冷却锁路径** | `/tmp/gemini-chrome-autoinstall.lock` | `%TEMP%\gemini-chrome-autoinstall.lock` |
| **互斥锁路径** | `/tmp/gemini-chrome-autoinstall.active.lock/` | `%TEMP%\gemini-chrome-autoinstall.active.lock\` |
| **Chrome 进程检测** | `pgrep -x "Google Chrome"` | `Get-Process chrome` |
| **HTTP 下载** | `curl -fsSL` | `Invoke-WebRequest` / `Invoke-RestMethod` |
| **幂等安装** | `launchctl unload` → `launchctl load` | `Register-ScheduledTask -Force` |
| **错误静默** | `2>/dev/null \|\| true` | `-ErrorAction SilentlyContinue` |
| **清理保障** | `trap EXIT` | `try/finally` |
| **冷却时长** | 300s (5 min) | 300s (5 min) |
| **最大等待** | 600s (10 min) | 600s (10 min) |
| **轮询间隔** | 5s | 5s |
