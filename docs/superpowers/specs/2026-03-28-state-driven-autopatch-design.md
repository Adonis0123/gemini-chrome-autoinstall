# State-Driven AutoPatch Design

Date: 2026-03-28
Status: Approved in chat, pending implementation plan
Scope: `gemini-chrome-autoinstall`

## 1. 背景

当前项目的目标是：当 Chrome 更新或相关本地状态被回退后，自动重新执行 `Gemini-in-Chrome` 上游补丁脚本，让 Gemini 相关能力尽快恢复。

经核查，当前项目与 README 中存在一个重要认知偏差：

- 现有文档将行为描述为“Chrome 更新后重新安装扩展”
- 实际上，上游 `Gemini-in-Chrome` 脚本修改的是 Chrome 的 `Local State`
- 因此，这个项目的真实职责应定义为“检测状态漂移并在合适时机重新修复本地状态”

这意味着：

- “Chrome 版本变化”只能作为强信号或触发线索
- “Local State 当前是否符合预期”才是最终真相源
- “Chrome 是否关闭”只是执行门槛，不应作为主触发源

## 2. 研究结论

本设计基于以下结论：

1. 监听 Chrome 版本变化并自动运行脚本是可行的，但只能做到高可用自愈，不能宣称 100% 无遗漏。
2. Windows 的注册表变更通知机制是官方支持能力，事件驱动开销极低，适合作为主触发器。
3. macOS `launchd` 的 `WatchPaths` 可以使用，但 Apple 明确说明其事件可能漏报，因此只能作为加速器，不能作为唯一可靠触发器。
4. “监听 Chrome 关闭”不适合作为系统的主触发事件，因为关闭不等于已完成升级，也无法直接表达“现在是否真的需要修复”。
5. 自动路径不应强制关闭 Chrome。Chrome 运行时应进入 `pending`，待浏览器关闭后再执行修复。

## 3. 目标

### 3.1 必达目标

- 用“状态驱动”替换“仅版本驱动”的自动修复判定模型
- 将自动执行限定在 Chrome 已关闭的条件下
- 保留低开销、事件驱动优先的设计
- 为失败、阻塞、未知状态提供清晰的状态输出
- 安装、状态输出和日志中都能明确看到当前工具版本，便于调试与用户支持
- 内建一套可重复、可验证、非黑盒的测试设计

### 3.2 非目标

- 不实现强制拦截 Chrome 更新过程
- 不实现自动强杀 Chrome 以便完成修复
- 不依赖 GUI helper、AppKit 常驻进程或复杂的原生守护程序
- 不把某一个平台特有事件当作跨平台统一真相源

## 4. 设计原则

1. 事件用于“发现问题”，状态用于“确认问题”。
2. 自动化不替代人工兜底，`manual`/快捷命令必须始终可用。
3. 自动路径永远不强写正在被 Chrome 使用的文件。
4. 所有自动修复都必须有事后校验，不能只以“脚本执行成功”作为成功标准。
5. 可测试性是正式需求，不是附属项。

## 5. 系统架构

系统拆分为 4 个职责单元：

### 5.1 Patch Need Detector

职责：判断“现在是否真的需要修复”。

输入信号：

- `version signal`：Chrome 版本或安装器版本发生变化
- `state signal`：`Local State` 目标字段是否仍满足补丁预期

输出状态：

- `healthy`
- `drifted`
- `unknown`

### 5.2 Execution Gate

职责：判断“现在能不能写”。

规则：

- Chrome 运行中：不写入，只创建或维持 `pending`
- Chrome 已关闭：允许执行补丁

### 5.3 Retry / Reminder Loop

职责：在 `pending` 存在时，持续推动系统从“待处理”收敛到“已修复”或“明确失败”。

特性：

- 仅在 `pending` 存在时活跃
- 前期可稍积极重试，后期转为低频
- 超时后给出明确提示，不静默失败

### 5.4 Manual Escape Hatch

职责：提供稳定、可预期的人工兜底通道。

要求：

- `manual` 子命令保留
- 快捷命令保留
- 自动流程失败时始终能明确指向手动修复入口

## 6. 状态模型

### 6.1 `needs_patch` 返回值

`needs_patch` 不再返回单一布尔值，而返回三态：

- `healthy`：目标字段已符合预期，不需要动作
- `drifted`：目标字段被回退，需要修复
- `unknown`：当前无法可靠判断，例如文件缺失、JSON 解析失败、关键字段缺失

### 6.2 `Local State` 真相字段

初版健康判定至少覆盖以下字段：

- `variations_country == "us"`
- `variations_permanent_consistency_country` 的国家位为 `"us"`
- `profile.info_cache.*.is_glic_eligible`

建议判定规则：

- `variations_country` 不为 `"us"`：`drifted`
- `variations_permanent_consistency_country` 无法解析或国家位不为 `"us"`：`drifted`
- 若存在 `is_glic_eligible` 键且任一值为 `false`：`drifted`
- 若关键字段整体缺失，且无法证明当前状态已经健康：`unknown`
- 所有关键检查均通过：`healthy`

说明：

- `unknown` 不能被当作成功
- `unknown` 也不应无限自动重试而不给出提示

### 6.3 `pending` 记录

`pending` 应从简单标记文件升级为带元数据的待处理记录。建议字段：

- `reason`
- `first_seen_at`
- `last_attempt_at`
- `retry_count`
- `detected_version`
- `platform`

用途：

- 支撑 `status` 输出
- 支撑提醒逻辑
- 支撑测试断言

## 7. 平台设计

### 7.1 macOS

macOS 侧不依赖单一 `WatchPaths`。

建议保留 3 层触发：

1. `RunAtLoad`
   - 用户登录后立即做一次轻量复核
   - 覆盖离线、注销、睡眠期间完成更新的场景

2. `WatchPaths`
   - 继续监听 `Google Chrome.app/Contents/Info.plist`
   - 角色定位为“加速触发器”
   - 触发后执行复核，而非直接假定必须补丁

3. 低频兜底复核
   - 周期性轻量检查 `needs_patch`
   - 用来弥补 `WatchPaths` 漏事件
   - 频率应低，避免变成高频轮询

### 7.2 Windows

Windows 侧继续走事件驱动，但版本信号应改为更权威的 Google Update 安装器版本源。

建议主监听目标：

- `Software\Google\Update\Clients\{8A69D345-D564-463C-AFF1-A69D9E530F96}\pv`

说明：

- 该 GUID 对应 Google Chrome Stable
- `pv` 是 Chromium/Google Update 常量中的正式产品版本值
- 其语义比 `HKCU\Software\Google\Chrome\BLBeacon\version` 更接近安装器确认的已装版本

建议保留 3 层：

1. 登录启动后台 watcher
2. 监听正式版本键的变更通知
3. 启动时立即复核 `pending` 与当前状态

## 8. 运行流程

统一流程如下：

1. 任一触发器触发复核
2. 读取版本信号与 `Local State`
3. 运行 `needs_patch`
4. 若结果为 `healthy`
   - 清理过期 `pending`
   - 记录当前健康版本
   - 退出
5. 若结果为 `unknown`
   - 记录错误原因
   - 若需要，进入提醒路径
   - 不伪装为成功
6. 若结果为 `drifted`
   - 若 Chrome 正在运行：创建或更新 `pending`
   - 若 Chrome 已关闭：执行上游脚本
7. 脚本执行后必须立即二次校验
8. 若校验通过：状态回到 `healthy`
9. 若校验失败：记录 `verify_failed`

## 9. 错误处理

至少区分 4 类失败：

- `detect_error`
- `blocked`
- `patch_failed`
- `verify_failed`

要求：

- 每类错误要有独立日志语义
- `status` 必须能区分“当前只是被 Chrome 阻塞”和“自动修复已经失败”
- 自动路径失败后，输出明确的人工处理命令

## 10. 用户可见行为

自动路径应表现为：

- 平时尽量安静
- 检测到问题时自动进入合适状态
- Chrome 运行时不打断、不强杀
- Chrome 关闭后自动收敛
- 长时间无法收敛时给出明确提示

推荐提示文案方向：

- 正在等待：Chrome 关闭后将自动修复
- 自动失败：请运行 `gemini-chrome-fix`

### 10.1 安装时版本可见性

安装与升级路径必须明确展示当前工具版本，避免用户和维护者无法判断“机器上到底装的是哪一版”。

要求：

- `install.sh` 与 `install.ps1` 在安装成功输出中打印当前工具版本
- `enable`/首次安装后的成功提示中可再次看到版本号
- 安装后的本地状态中应保留一个可读取的已安装版本记录
- `status` 命令应能显示当前已安装的工具版本
- 日志文件中的启动或安装记录应带上工具版本，便于排查线上问题

版本信息必须来自单一真相源，避免不同脚本各自硬编码出错。

## 11. 状态输出设计

`status` 至少输出以下内容：

- 当前工具版本
- 当前 Chrome 版本
- 最近一次已验证健康的版本
- 当前系统状态：`healthy / drifted / unknown / pending`
- `pending` 原因与已等待时长
- 最近一次补丁尝试结果

目标是让用户一眼分辨：

- 现在没问题
- 现在需要修
- 现在在等 Chrome 关闭
- 现在系统判断不了
- 现在自动修复失败，需要手动介入

## 12. 测试设计

测试是本设计的正式交付项。

### 12.1 Pure Logic Tests

目标：验证不依赖真实 Chrome 或系统事件的核心状态机。

覆盖：

- 安装时版本显示逻辑
- 版本变化是否触发复核
- `needs_patch` 三态判定
- `pending` 的创建、更新、清理
- 提醒升级逻辑
- `status` 的状态映射

### 12.2 File Fixture Tests

目标：用固定样本验证“补丁是否真的改变了预期状态”。

至少准备以下 fixture：

- `healthy` 样本
- `variations_country` 回退样本
- `variations_permanent_consistency_country` 回退样本
- `is_glic_eligible` 为 `false` 的样本
- 关键字段缺失样本
- JSON 损坏样本

对每个 fixture，应验证：

- 判定结果是否正确
- 仅在需要时执行写入
- 写入后是否变为 `healthy`
- 失败时是否返回正确错误类型

### 12.3 Flow Tests

目标：验证整套状态流转，而非单点逻辑。

核心场景：

0. 全新安装或覆盖安装
   - 预期：安装输出中包含当前工具版本，且本地版本记录可被 `status` 读取

1. 检测到版本变化，Chrome 正在运行
   - 预期：创建 `pending`

2. `pending` 存在，Chrome 关闭
   - 预期：自动执行修复并收敛到 `healthy`

3. 修复执行失败
   - 预期：进入 `patch_failed`

4. 修复执行成功，但校验仍失败
   - 预期：进入 `verify_failed`

5. 事件漏触发，但登录复核或低频复核触发
   - 预期：最终仍能发现 `drifted`

### 12.4 测试矩阵

| 场景 | 输入 | 预期 |
|------|------|------|
| Install version visible | 全新安装或升级安装 | 输出中显示当前工具版本，且 `status` 可读取 |
| Healthy no-op | `Local State` 已健康 | 不执行修复 |
| Drifted repair | `Local State` 漂移 | 执行修复并恢复健康 |
| Unknown state | 文件损坏/缺失 | 不假装成功，明确错误 |
| Chrome running | 需要修复但 Chrome 运行中 | 创建 `pending`，不强写 |
| Pending settle | `pending` 存在且 Chrome 已关闭 | 自动消化 `pending` |
| Auto failure | 上游脚本失败 | 明确失败并给出手动入口 |

## 13. 验收标准

实现完成后，至少满足以下验收条件：

1. Chrome 升级后，如 `Local State` 被回退，系统能自动发现。
2. Chrome 运行中时，系统不会强写，只进入 `pending`。
3. Chrome 关闭后，系统能自动完成修复，并回到 `healthy`。
4. 即便事件触发漏掉，登录复核或低频兜底复核最终仍能发现问题。
5. 自动修复失败时，用户能从 `status` 或提示中明确知道下一步命令。
6. 用户在安装或升级时，能明确看到当前安装的工具版本；安装完成后，`status` 也能读出同一版本。
7. 所有上述场景都有可重复运行的测试用例，不依赖人工肉眼观察黑盒结果。

## 14. 后续实现边界

后续实现阶段至少需要覆盖以下改动方向：

- 重构 `needs_patch` 为状态驱动判定
- 为 `pending` 增加元数据
- 增加单一工具版本源，并在安装、状态、日志中贯通展示
- macOS 新增低频兜底复核
- Windows 将版本监听源从 `BLBeacon` 调整为 Google Update `Clients\...\pv`
- 将“脚本执行后必须复核”写入主流程
- 新增可重复运行的 fixture 与 flow tests
- 更新 README 和设计文档中的措辞，避免继续使用“重装扩展”的不准确定义

## 15. 决策摘要

本设计最终选择：

- 不把“监听 Chrome 关闭”作为主触发
- 保留事件驱动检测，但降级其语义为“触发复核”
- 将 `Local State` 作为最终健康真相源
- 将“Chrome 已关闭”作为执行门槛
- 将测试能力作为一等需求内建

一句话概括：

**事件驱动发现问题，状态校验确认问题，关闭条件控制写入，`pending` 机制负责最终收敛，测试体系负责证明它真的生效。**
