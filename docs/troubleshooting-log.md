# 「空闲冻死」排查全过程与踩坑记录

> **Troubleshooting log** — HP ProBook 4 G1i 14 hard-freezes at idle. 19 × `Kernel-Power 41` with `BugcheckCode = 0`, 3 BIOS versions, 6 events outside Modern Standby. **No working fix found** (BIOS, PCIe ASPM and HVCI all tested and disproved). Written in Chinese; every command is copy-paste ready. For the short version, see the [README](../README.md).
>
> 本文件原名「死亡睡眠」，那是最初的错误结论；现已按实际机理改称「空闲冻死」。

> **机器**：HP ProBook 4 G1i 14 inch Notebook AI PC（序列号已脱敏）  
> **系统**：Windows 11 25H2，build `26200.9711`  
> **排查时间**：2026-10-27 ~ 2026-10-28  
> **当前状态**：**无有效解，21 次**。BIOS 最新版、ASPM、HVCI 三项干预已全部证伪；第 19 次（15:14）首次留下崩溃前完整现场，第 20 次（16:41）换了个入口重现，第 21 次（17:17）**连失败形态都变了：黑屏 → 按键盘 → 整机自行复位**，三次的唯一共同点是 **`ActivityLevel = 4`**。第 9 轮（摘 hypervisor）**尚未真正执行**（判定口径见 §6.1.3）

---

## 0. 一句话结论

**这不是「睡眠睡死了」，是「一闲就死」。**

系统只要进入空闲状态、CPU 请求深睡，整机就会冻住——**屏幕亮着、没开任何程序、包功耗 4 W 的时候一样会冻**。2026-07-08 至 2026-10-28 共 **21 次**无蓝屏硬断电，横跨 **3 个 BIOS 版本**，14 次发生在连接待机中、**7 次发生在完全没待机的时候**。

**当前状态：没有找到有效解。** 三项干预全部证伪：最新 BIOS（刷后 58 分钟复现）、PCIe ASPM（回读 `0x0/0x0` 后 4 小时 4 分钟冻死）、内存完整性 HVCI（回读 `Enabled = 0` 后 31 分钟冻死）。第 19 次终于留下了崩溃前的完整现场——系统降到 `ActivityLevel 4` 后 31 分钟内冻死，而同一段 `ActivityLevel 0` 的会话跑了 1231 秒正常结束。第 20 次（1 小时 26 分钟后）又从**待机**这条路走了同一个出口，第 21 次（再 36 分钟）**连形态都变了——黑屏按键盘后整机自行复位**，`ActivityLevel 4` 依旧是唯一稳定的特征。第 9 轮（摘 hypervisor）因为第一次尝试被 VBS 架空，**实际尚未开始观察**。

---

## 1. 故障基线（已核实的硬事实）

| 项目     | 值                                                   |
| ------ | --------------------------------------------------- |
| 型号     | HP ProBook 4 G1i 14 inch Notebook AI PC             |
| 序列号    | `5CD•••••••`（已脱敏）                                  |
| CPU    | Intel Core Ultra（Arc 140T 核显，无独显）                   |
| 内存     | 32 GB（2×16 GB Samsung 5600，同型号同批次）                  |
| 硬盘     | KIOXIA KBG60ZNV1T02 1 TB（健康，无错误计数）                  |
| BIOS   | `X72 Ver. 01.05.04 Rev.2`（2026-08-13，HP 当前最新）       |
| 睡眠能力   | S0 低功耗待机可用；**S3 固件不支持**；休眠可用                        |
| 电池     | 设计 56047 mWh / 满充 55225 mWh（98.5%），**循环仅 2 次**      |
| 异常断电   | `Kernel-Power 41` × **21**（2026-07-08 → 2026-10-28） |
| 蓝屏     | `BugcheckCode` **全部为 0**，无 dump                     |
| 硬件错误日志 | `WHEA-Logger` × 18（16 条 ID=1，2 条 ID=3）——**第 18～21 次均未新增**，最后一条停在 10-28 09:34（第 17 次） |

**关键特征：全程没有一次蓝屏。** 系统是「整机瞬间失去响应 → 只能长按电源键 → 下次开机记录一条 41」，不是崩溃重启。

---

## 2. 九轮结论演进：每一步是被哪条证据推翻的

这一节是本文档的核心。排查过程本身就是不断证伪的过程，**保留错误结论的来龙去脉，比只留最终答案有用**。

| 轮次            | 当时的结论                           | 支撑它的证据                                                                                                                                                                                                          | 被什么推翻                                                                     |
| ------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| **第 1 轮**     | 息屏后进程持锁不放手，系统进不了低功耗 → 卡在 S0 半睡态 | sleepstudy：18 次息屏 **全部** 含 `PDC Phases / No CS Phase`，占比 99%；`TopBlockers` 点名 MoUsoCoreWorker 5/5、svchost 3/5、GameViewer 2/5、TiWorker 1/5                                                                       | 只解释了「为什么没睡」，**解释不了「为什么死」**——持锁是挂起的原因，不是断电的原因                              |
| **第 2 轮**     | 平台固件在 S0 进出时抛致命错误，系统被掐断         | `Kernel-Power 41` 的 BugcheckCode 全 0；`WHEA-Logger` 7 条 CPER `Fatal`，错误段 100% 是 `Firmware Error Record`                                                                                                          | 方向对（确实是固件层），但把「事后取证标记」当成了「实时组件诊断」，**指认不到具体模块**                            |
| **第 3 轮**     | 卸载 GameViewer（含虚拟显示驱动）          | 它是唯一非原厂显示驱动；在 2 次长息屏里各占 99% 持锁时长                                                                                                                                                                                | 5 次长息屏里它只参与 2 次，10-22 那三次持锁的是系统更新组件；且**用户必须用它做远程**，不可卸载                   |
| **第 4 轮**     | 接电源「永不息屏」，绕开 S0                 | 逻辑上成立：不进 S0 就不会触发 S0 缺陷                                                                                                                                                                                         | **10-27 全天 0 次息屏、全程亮屏，照样崩**——触发口根本不是息屏                                    |
| **第 5 轮**     | 走 S4 休眠绕开 S0（合盖即休眠）             | 休眠不进 S0，固件缺陷无触发机会                                                                                                                                                                                               | 方向可行，但**只是回避**，且休眠时远程连不上；用户明确反对「靠改使用习惯兜底」                                 |
| **第 6 轮**     | 报修，可能要换主板                       | 固件级 Fatal + BIOS 已最新 + 电池循环 2 次                                                                                                                                                                                 | 口径过头：**报修 ≠ 换主板**，是让 HP 走「刷固件 → 诊断 → 判定」流程；`DEADBEEF` 更像结构体未初始化，不能据此断言硬件坏 |
| **第 7 轮** | **空闲电源转换时 PCIe 链路降档后无法唤醒，整机冻死** | ① 亮屏空闲也崩（第 4 轮证据反推）② 全量回溯发现当时已 17 次、横跨 4 个月与 3 个 BIOS 版本 ③ HP 官方社区同型号双机复现，内核栈落在 `intelppm!HvRequestIdle → PepIdleExecute → PpmIdleExecuteTransition → PoIdle → KiIdleLoop` ④ 本机 ASPM = 最大电源节省量 ⑤ 对方唯一有效缓解 = 关闭 ASPM | **2026-10-28 14:12 被推翻**：ASPM 已关闭并回读确认 `0x0/0x0`，电源方案未变、设置未被打回，**4 小时 4 分钟后第 18 次冻死**。故障点不在 PCIe 链路层，嫌疑退回上一层 |
| **第 8 轮** | **空闲状态转换本身失败，hypervisor 参与其中** | ① ASPM 已排除（见第 7 轮）② 崩溃栈顶部 `HvRequestIdle` 的 `Hv` = **Hypervisor** ③ 本机 VBS 状态 = 2（运行中）、`SecurityServicesRunning` 含 `2`（HVCI） | **2026-10-28 15:14 被推翻**：HVCI 于 14:22 关闭并重启，`HVCI Enabled = 0`、`SecurityServicesRunning` 由 `2,3,4` 变为 `3,4`，**31 分 25 秒后第 19 次冻死**。但注意——HVCI 只是 hypervisor 的一个安全服务，`HypervisorPresent` 仍为 `True`、VBS 仍为 2，**hypervisor 本身从未被排除**，只是"关 HVCI"这条路走不通 |
| **第 9 轮（当前）** | **CPU 深度空闲状态转换（PEP → 深 C-state）失败，与睡眠无关** | ① 第 19 次拿到崩溃前完整现场：`14:43:28 → 15:14:53` 一段 **Type 0（Active）** 会话，`ActivityLevel = 4`，1885 秒，`ExitReason = Unknown` ② 天然对照：同机同日 `14:22:28 → 14:43:00` 那段 `ActivityLevel = 0`，1231 秒，`ExitReason = Initialization` **正常结束** ③ 全量 21 次里凡 `ExitReason = Unknown` 的异常记录 `ActivityLevel` 全是 4，正常结束的全是 0；第 20 次从待机（`Type 1`）进入、`CS = true`，`ActivityLevel` 仍是 4——**亮屏空闲和待机两条路殊途同归** ④ 这次 `STANDBYIDLE = 0`（从不进待机），`CS = false`——**根本没睡，纯粹是深度空闲** ⑤ `Kernel-Processor-Power` 事件 55：空闲状态由 **Micro Power Engine Plugin（11 状态）** 管理，正是崩溃栈里 `PepIdleExecute` 那一层 ⑥ 冻结瞬间 `ExitRemainingCapacity = 0`（进入时 53626 mWh），连电池都读不到 | 待验证：`scripts/disable-hypervisor.ps1 apply` 摘掉 hypervisor（用户确认不用虚拟化）。**第一次尝试已失败**：15:39 只关 `bcdedit`，15:42 重启后 hypervisor 照起（事件 1 + 153「enabled due to VBS registry configuration」）→ 见 P34，脚本已改为 VBS 注册表 + `bcdedit` 两个开关一起关。仍崩 → BIOS `Extended Idle Power States` 设 `Disable` |

---

## 3. 各数据源的能力边界

排查时最耗时的不是「查不到」，而是「**以为这个数据源能回答，其实不能**」。先明确边界，能省掉大量返工。

| 数据源                               | 能回答                                              | **不能**回答                                              |
| --------------------------------- | ------------------------------------------------ | ----------------------------------------------------- |
| `powercfg /sleepstudy` 报告         | 有哪些场景会话、每次持续多久、谁持有 Power Request（**进程名**）、每段功耗快照 | 驱动名、崩溃原因、卡在哪个函数                                       |
| `System` 日志 `Kernel-Power 41`     | 「上次是非正常关机」+ 是否在连接待机中 + 有无蓝屏 + 有无长按电源键            | 精确崩溃时刻、崩溃原因                                           |
| `WHEA-Logger` + CPER              | 上次崩溃时固件有没有写错误记录、记录属于哪一类                          | **具体哪个组件**（本机记录里引用 GUID 全零、36% 是 `0xDEADBEEF` 未初始化填充） |
| `HP SFU Service` 日志               | **BIOS 真实版本变更史**（唯一可靠来源）                         | —                                                     |
| `HP Sure Start` 日志                | 固件自检/恢复事件                                        | 电源状态问题                                                |
| `C:\Windows\INF\setupapi.dev.log` | 固件包何时被拷入、何时刷写                                    | 刷写**之前**的版本号（只有文件名，容易误判）                              |
| `root\HP\InstrumentedBIOS` WMI    | BIOS 里的电源/散热设置项、传感器                              | 硬件故障诊断                                                |
| `Win32_DeviceGuard`               | VBS / 内存完整性 / Secure Launch 状态                   | 是否与崩溃相关（只能列为变量）                                       |
| `powercfg /requests`              | **当下**谁在持锁                                       | 历史持锁情况                                                |

---

## 4. 踩坑记录

按「数据解析 → 取证逻辑 → 判断与方案」三类，共 38 条（4.4 为 10-28 复核与实操阶段补充，含第 18 次后新增的 P29、P30，第 19 次后新增的 P31–P33，第 9 轮第一次尝试失败后新增 P34、P35，第 21 次后新增 P36、P37，第 10 轮评估阶段新增 P38）。**每条都是实际踩到并付出过时间的。**

> 配套文件：可直接提交 HP 的报修文本见同目录 `warranty-claim.md`。

### 4.1 数据解析坑

**P1｜sleepstudy 报告的数据不是标准 JSON。**  
真实数据内嵌在 HTML 单行 `var LocalSprData = {...};` 里，但对象字面量用了单引号/无引号键/尾逗号，`json.loads` 必然失败（报在 21850 字节附近）。

- 正确做法：截出这一行 → 去掉前缀和结尾分号 → 用 Node `Function('return ('+s+')')()` 求值 → 再序列化成 JSON。
- 错误做法：用正则或手写括号匹配去解析（字符串内的花括号会把深度算错）。

**P2｜`Duration` 单位是微秒，不是秒。**  
直接当秒用会得到「一次待机 5900000 秒」这种荒谬值。除以 `1e6`。

**P3｜`ScenarioInstances[].Type` 是数字枚举，必须查映射表。**  
`0=Active 1=ScreenOff 2=Sleep 3=Standby 5=Hibernate 7=Shutdown 8=AbnormalShutdown 9=Bugcheck`。搞错会让「0 次 Sleep」这种关键结论完全反向。

**P4｜CPER 的 SectionType GUID 偏移不是规范写的 +12。**  
CPER v2.10 的 72 字节段描述符在 +12 处多了一个 dword，**SectionType 实际在 +16**。按 +12 读会得到错位 GUID，会误判成「未知错误类型」。

**P5｜`TotalPowerInMilliwatts` 不是整机功耗，不能用来算电费。**  
它是电池充放电功率，**充电时符号为负**，拔电和插电时含义不一致。测 SoC 真实功耗要用 `PackagePowerInMilliwatts`（RAPL 封装功耗），而且**要另外加屏幕功耗**（14 寸 IPS 满亮度面板约 3–4 W）。

> 这条踩过一次：第 3 轮曾拿 10.6 W（息屏）对比 9.3 W（亮屏）得出「息屏更费电」，**漏了屏幕没算**。修正后：亮屏整机 ≈12.8 W、息屏 ≈10.6 W，息屏确实省电，但只省 2.2 W，而本应省 12.3 W。

**P6｜`Audio Activity` 阻挡组是模板占位，永远为空。**  
18/18 次息屏会话都有这个组，但 `Blockers` 恒为 `[]`。**必须先判断 Blockers 是否为空再下结论**，否则会得出「有音频在播放所以不睡」这种完全错误的分析。

**P7｜`SrumData` 在多数会话里是空的。**  
`EnergyMeterData` 为空、`PowerEstimationData.*Measured` 全 `false`，意味着**报告无法给出进程级能耗归因**。最典型的 10-23 17:03 那次（242 秒、SoC 17.4 W、CPU 11.5 W）就查不到「那 4 分钟具体是谁在跑」。

**P8｜注册表 `ProductName` 写着 `Windows 10 Pro`，实际是 Windows 11 25H2。**  
这个字段从 Win11 起就没更新过，**判断系统版本必须以 `CurrentBuild`（26200）+ `DisplayVersion`（25H2）为准**。直接把注册表值写进报告会出事实错误。

**P9｜`powercfg /query` 查不到「合盖动作」。**  
`SUB_BUTTONS` + `LIDACTION` GUID 查出来是空的，会误判成「未配置」。必须直接读注册表：

```
HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\<方案GUID>\
  4f971e89-eebd-4455-a8de-9e59040e7347\5ca83367-6e45-459f-a27b-476b1d01c936
```

读出来的 `ACSettingIndex` / `DCSettingIndex`：`0=不操作 1=睡眠 2=休眠 3=关机`。

**P10｜PowerShell 5.1 按 ANSI(GBK) 读无 BOM 的 .ps1。**  
脚本里含中文就会整段乱码，并抛 `Expression or statement contains unexpected token`。**必须存成 UTF-8 带 BOM**，且用 Edit 工具改完后要复查 BOM 是否还在（编辑后 BOM 会丢）。

**P11｜纯字符串表达式经管道捕获会丢换行。**  
`"字符串"` 形式的输出用 `$x = & script.ps1` 捕获时行结构会被压平。改用 `Write-Host` 逐行输出才稳定。

### 4.2 取证逻辑坑

**P12｜`Kernel-Power 41` 的 `TimeCreated` 是「下次开机时刻」，不是崩溃时刻。**  
41 是开机时补写的「上次没正常关机」记录。把它当崩溃时间，整条时间线会整体后移几十分钟到几小时。

**P13｜`6008`（非正常关机）自报的时间也不可靠。**  
实测这条消息里的日期/时间文本与事件顺序**明显错位**（例如开机 10-26 16:28 的那条，自报时间为 10-23 18:58）。原因多半是本地化格式 + 该字段由不同来源拼装。**只能当粗参考，不能当精确崩溃点。**

> 正确做法：用「崩溃前最后一条 System 事件」+「下次开机首条事件」夹逼，再和 sleepstudy 的会话断点对齐。

**P14｜`BugcheckCode = 0` 且没有 dump，不等于「没出错」。**  
它意味着**系统来不及写 dump 就被掐断了**——这恰恰是「瞬间断电/整机冻死」的特征，跟「硬件无关的软件 bug」是两回事。不要因为「没蓝屏」就缩小排查范围。

**P15｜`LongPowerButtonPressDetected` 全为 `false` 不能推断「用户没长按电源键」。**  
实际每次都是长按强制关机的，但固件没记录到这个标志。**这个字段在此机型上不可信**，不能拿它当「系统自行断电」的证据。

**P16｜`WHEA` 记录出现在开机后 10–20 秒，说明它是「尸检」不是「实时报警」。**  
错误记录是崩溃当时由固件写进闪存错误表，下次开机才被 Windows 读出来变成事件。所以「错误发生时间」≈ 上次崩溃时刻，而不是事件时间戳。

**P17｜WHEA 记录里的错误数据是垃圾，不能用来指认组件。**  
实测：13,736 字节的记录里 `0xDEADBEEF` 出现 **1,243 次（约 36% 字节）**，引用 GUID 全为零，头部时间戳解出 **4591 年**（而验证位却声明该字段有效）。  
→ 结论只能是「**固件读到了未初始化内存**」这一层，**不能**说「是 XX 模块报错」。把它写成「固件指认了某组件」会被工程师反驳。

**P18｜`powercfg /sleepstudy` 不会告诉你是哪个驱动。**  
它给的是**持有 Power Request 的进程名**（`MoUsoCoreWorker`、`GameViewer` 这种），不是驱动名。另外，如果报告里像本机一样 **0 条 Modern Standby 会话**，按「找红色 Modern Standby 记录」的思路会一无所获。

**P19｜同型号社区帖不能跨型号直接套用。**  
HP 社区 2026-10-21 有个 16 寸 ProBook 4 G1i 的帖，同 X72 BIOS 01.05.04，症状是「软重启卡在 POST 前黑屏」——**和本机的空闲冻死不是同一个问题**，不能拿来证明「HP 已知此缺陷」。

真正对口的是 "Second Probook 4 G1i 14 causes random freezes and reboot"（14 寸，两台同 part number 复现）。

### 4.3 判断与方案坑（代价最大的三条）

**P20｜「息屏进 S0 才触发」这个归因是错的。**  
第 1~4 轮全建立在这个假设上，因此推出「永不息屏 = 不进 S0 = 不崩」。10-27 的数据直接否掉：**当天 0 次息屏、25 个功耗区间全部 `MonitorOn=True`、包功耗稳定 3.9–4.0 W，然后冻死**。

真正的触发条件是**空闲电源转换本身**，跟屏幕亮不亮、盖子合不合无关。屏幕亮着，CPU 照样进 C-state、PCIe 链路照样降档。

**连带结论：`power-mode.ps1` 的 `remote` 模式（AC 关屏从不）既没治到病，又白耗电，应回退。**

**P21｜`powercfg /h off` 是纯负收益，明确反对。**  
本机休眠可用，而「卡在 S0 / 空闲冻死」时**休眠是唯一的安全网**（20 分钟不进城就落盘 S4，最坏丢 20 分钟）。关掉休眠还会连带关掉快速启动，等于把兜底拆了。正确方向是**保留并启用休眠**，不是关掉。


**P22｜BIOS 版本差点写错进报修材料。**  
第一版报告写「崩溃时 BIOS 是 01.03.02」，来源是 `setupapi.dev.log` 里那行 `DeleteFile X72_01030200.bin`——那是**旧包清理**，不是当前版本。真实版本史只能从 **`HP SFU Service` 日志**读：

| 时间                   | BIOS 版本                   |
| -------------------- | ------------------------- |
| 2026-06-30 装机        | 01.03.00（固件包文件名 01.03.02） |
| 2026-07-08 11:14     | → 01.03.02                |
| **2026-07-08 14:31** | → **01.04.03**            |
| 2026-10-26 16:55     | → 01.05.04（当前）            |

所以 10-22 / 10-23 / 10-26 三次崩溃时跑的是 **01.04.03**。这个错误如果没改就发给 HP，工程师一句「你版本都写错了」就能把整份材料打回来。

**另一条相关教训**：`setupapi.dev.log` 里能看到 `X72_01050400.bin` 于 **10-26 16:46:06** 被拷入刷写，**17:44 就再次崩溃（刷完 58 分钟）**。这条反而是最有价值的证据之一——证明「刷最新 BIOS」解决不了。

### 4.4 补充（10-28 复核阶段新增）

**P23｜按 ProviderName 直接计数会严重误判。**  
`Microsoft-Windows-Kernel-Processor-Power` 在近 90 天有 **624 条**，第一眼像是「大量降频告警」，实际 `Group-Object Id` 一看全部是 **ID=55 的启动期能力枚举**（每个 CPU × 每次开机，纯信息级），**一条 ID=37（固件限制处理器性能）都没有**。

→ 结论：**先看 ID 构成，再看总数。** 差点因此写出「存在大量固件降频」的错误结论。

顺带在这批 ID=55 里挖到个有用细节：`Idle state type: Micro Power Engine Plugin (11 state(s))`——本机 11 个空闲态全由 PEP 微电源引擎统一管理，正好对上崩溃栈里的 `PepIdleExecute`。

**P24｜用两个独立来源交叉校验事件数。**  
`Kernel-Power 41`（18）与 `EventLog 6008`（18）本机完全一一对应，说明统计口径没问题、也没有因日志轮转丢事件。**两者不等就说明数据被截断了**，得先修补数据再分析。

**P25｜`Minidump` 目录「存在但为空」和「不存在」是两种含义。**  
本机是前者（目录在、0 文件、`MEMORY.DMP` 也没有）。要连 `WER\ReportArchive` 一起看（本机 Kernel/BlueScreen 类报告 0 条），三个都空才能下「确实没生成过转储」的结论。

**P26｜「改用平衡方案让 Windows 自己管」是无效思路。**
实测两个方案的 ASPM **都是 `0x2`（最大电源节省量）**：

| 方案 | ASPM(AC/DC) | 休眠(电池) |
|---|---|---|
| 平衡 `381b4222-…` | `0x2` / `0x2` | `0x7fffffff`（≈ 从不） |
| HP Optimized `fb5220ff-…` | `0x2` / `0x2` | `0x3f480`（72 h） |

「平衡」在 PCIe 这一项上是**固定取值**，不是动态判断——Windows 挑的正好是要避开的那个值。而且「平衡」的电池休眠比 HP 方案更差。**换方案不能替代手动关 ASPM。**

**P27｜切换电源方案会把 ASPM 打回 `0x2`。**
方案之间互不继承。在 A 方案改过，切到 B 方案，B 里仍是默认的「最大电源节省量」。用脚本（作用于 `SCHEME_CURRENT`）比用界面省事——**切完方案要再跑一次**。

**P28｜「选项在图形界面看不看得见」要查，不要猜。**
Modern Standby 机型常有电源项被 `ATTRIB_HIDE` 隐藏，直接教用户去点会扑空。先查：

```powershell
powercfg -attributes SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```

本机返回 `None`（未隐藏）→ 图形界面可见，不必让用户敲命令。**先查再给路径，能省一轮来回。**

**P29｜把「崩溃前的后台活动」当成诱因，是最容易自我说服的错误。**  
第 18 次崩溃前，系统正在**待机中批量安装 6 个应用更新**（13:26–13:46：myHP、WindowsAppRuntime、Clipchamp、ZuneMusic、Xbox、语言包），装完 4 分钟后就冻死了。时间线看起来极有说服力——"维护任务跑完、系统想回深睡、回不去就死了"。

但把这条候选诱因放到全量 21 次上跑一遍：**只有 6 次**在崩溃前 90 分钟内有更新活动，**其余 15 次毫无更新**（第 20、21 次窗口内更新事件均为 0）。

→ 结论：**单次的"巧合关联"不能当因果。** 任何看起来解释力很强的诱因，都必须放到全量事件上验频率，否则会写出一条听起来很合理、实际只对 1/18 成立的解释。

**P30｜`EventLog 6008` 的时间戳又一次骗人。**  
第 18 次：6008 报「上一次系统的 **13:43:59** 在 2026/10/28 上的关闭是意外的」——可系统日志在 **13:50:14** 还有 Wi-Fi 驱动事件。**6008 报的时间比实际最后一条事件还早 6 分钟。**

这不是首次（第 17 次也错位）。说明它记录的是某个内部标记被刷新的时刻，**不是崩溃时刻**。

→ 结论：**判断崩溃时刻只能用"最后一条正常事件的时间"**；6008 的时间只当「存在非正常关机」的布尔值用，不要拿去算时间差。顺带一提，`Kernel-Power 41` 的 `TimeCreated` 也是**下次开机**的时刻，同样不能当崩溃时刻。

**P31｜`ScenarioInstances` 里真正带信息的是 `ActivityLevel`，不是 `Type`。**  
前 18 次一直盯着 `Type`（0 = Active，1 = 待机），得出的结论绕来绕去。第 19 次才发现判别特征在另一个字段：**21 次崩溃里凡 `ExitReason = Unknown` 的异常记录，`ActivityLevel` 全是 4；正常结束的会话全是 0。**

而 `Type 0` + `ActivityLevel 4` 这种组合最容易骗人——它看起来是"活跃会话"，实际系统已经判定进入最深空闲等级，正在往深 C-state 走。

→ 结论：**先按 `ActivityLevel` 分组，再看 `Type`。** 只看 `Type` 会把"亮屏但深度空闲"误读成"用户在正常使用"。

**P32｜`STANDBYIDLE = 0` 不等于"不会崩"。**  
第 19 次是在 `STANDBYIDLE = 0`（从不进入待机）、`ConnectedStandbyInProgress = false` 的情况下冻死的。整机 31 分钟全程 `Type 0`，一次待机都没进。

前几轮一直有人（包括我自己）把"避开睡眠"当成兜底思路——"只要不进 S0 就没事"。这次直接把这条路堵死了：**不睡，照样死。**

→ 结论：**别再把「不进待机」当缓解措施。** 要限制的是更下层的 CPU 空闲状态深度，不是睡眠行为。

**P33｜HVCI ≠ hypervisor，关掉前者不等于排除后者。**  
第 8 轮的推理是"崩溃栈顶是 `HvRequestIdle`，`Hv` = Hypervisor，所以关掉 hypervisor 相关的东西试试"。实际执行的却是关 HVCI（内存完整性）——那只是 hypervisor 之上的一个**安全服务**。

关完之后的真实状态：`HVCI Enabled = 0`、`SecurityServicesRunning` 从 `2,3,4` 变成 `3,4`，但 **`HypervisorPresent` 仍是 `True`、VBS 仍是 `2`**——hypervisor 一直在跑。

→ 结论：**验证"某个组件是否被排除"要看运行态，不是看设置项。** `bcdedit /enum {current}` 里没有 `hypervisorlaunchtype` 就是默认 `auto`，hypervisor 会启动；只有显式设成 `off` 并重启后 `HypervisorPresent = False`，才算真摘掉。

**P34｜`hypervisorlaunchtype off` 压不住 VBS——两个开关必须一起关。**  
第 9 轮第一次尝试只跑了 `disable-hypervisor.ps1 apply`（当时脚本只做 `bcdedit /set hypervisorlaunchtype off`），15:42:01 重启，结果：

```
15:42:02  Microsoft-Windows-Hyper-V-Hypervisor  事件 1  虚拟机监控程序已成功启动
15:42:02  Microsoft-Windows-Hyper-V-Hypervisor  事件 2  计划程序类型为 0x4
15:42:02  Kernel-Boot / CodeIntegrity          事件 153
          基于虚拟化的安全性(策略: VBS Enabled, VSM Required, Secure Boot, ...)
          是 enabled due to VBS registry configuration
```

`HypervisorPresent` 仍是 `True`，VBS 状态仍是 `2`。原因不在 `bcdedit`，而在注册表：

| 位置 | 值 | 含义 |
| --- | --- | --- |
| `HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\EnableVirtualizationBasedSecurity` | `1` | **VBS 总开关开着** |
| 同上 `WasEnabledBy` | `1` | 由 Windows 默认/策略开启，不是用户手动开的 |
| 同上 `RequirePlatformSecurityFeatures` | `3` | 要求 Secure Boot + DMA 保护（Secured-core 机型常见） |
| 同上 `HyperVVirtualizationBasedSecurityOptout` | `0` | 没有 opt-out |

事件 153 那句 **"enabled due to VBS registry configuration"** 就是铁证：**只要 VBS 注册表开关是 1，Windows 会以「VBS 需要 VSM」为由强行加载 hypervisor**，`bcdedit` 那一条被架空。

→ 结论：**摘 hypervisor = 关 VBS 注册表 + 关 `hypervisorlaunchtype`，缺一个就白重启一次。** 脚本已改为 `apply` 同时写三处（`EnableVirtualizationBasedSecurity`、`HypervisorEnforcedCodeIntegrity\Enabled`、`LSA\LsaCfgFlags`）再设 `bcdedit`。

**P35｜`bcdedit /enum {current}` 在 Win11 26200 上会报「指定的项类型无效」，把回读搞成假失败。**  
脚本原来用 `bcdedit /enum '{current}'` 回读 `hypervisorlaunchtype`。本机实测（PowerShell 和 cmd 都一样）：

```
bcdedit /enum {current}   →  指定的项类型无效。  (exit 1)
bcdedit /enum             →  无法打开启动配置数据存储。拒绝访问。  (说明参数解析没问题，只是没提权)
```

也就是说 `{current}` 这个标识被当成了「项类型」。后果很隐蔽：`$matches` 永远匹配不到 → `Get-LaunchType` 永远返回 `$null` → `apply` 回读那步打印红色「❌ 写入失败或被拒绝」并 `return 1`。**于是「写成功了读不出来」和「真的写失败」在输出上长得一模一样**——本次就是这样把 BCD 的真实状态搞丢了，只能靠重启后的 hypervisor 事件反推。

→ 结论：**不带参数的 `bcdedit /enum` 读的就是默认启动项，用它。** 另外任何"回读验证"都别只信任一种取数方式，取不到值时要区分「真的没写进去」和「读取方式坏了」——这两种情况会导向完全相反的下一步。

**P36｜`Kernel-Power 41` 不止「静默冻死」一种形态，别把新形态当成另一个病。**  
前 20 次的现象都是：画面静止、需要长按电源键。第 21 次完全不是——

```
16:46:20  进入连接待机
17:03:20  Kernel-Power 507：被键盘唤醒（"原因: Input Keyboard"）
17:08:20  按 VIDEOIDLE(AC=300s) 关屏，但没进待机（CS=false）
17:16:18  IsolatedUserMode #2：NGC 安全容器正常停止（最后一条事件）
~17:17:2x 用户按键盘 → 没有亮屏，整机自己复位
17:17:43  开机；17:17:46 补记 Kernel-Power 41
```

关键在事件 41 的字段：`BugcheckCode = 0`、`PowerButtonTimestamp = 0`、`LongPowerButtonPressDetected = false`——**没有蓝屏、没有长按电源键、也没有转储**，是平台自己复位。

→ 结论：**同一个 41 可以表现为"冻死等你去按电源键"，也可以表现为"你按键盘它就地重启"。** 判断是不是同一个病，看 `BugcheckCode = 0` + 无 dump + 最后一条事件突然断掉这三件事，别依赖"用户怎么描述现象"——描述会随场景变化，41 的字段不会。

**P37｜`System` 日志是循环覆盖且已经满了，计数会自己变小、证据会自己消失。**  
排查中途实测同一个查询（`Kernel-Power 109`）两次结果不同：先 40，半小时后 **39**。不是查询写错了，是日志滚出去了：

```
LogMode     : Circular
MaxSizeKB   : 20480
FileSizeKB  : 20484      ← 已满
RecordCount : 27325
最早一条     : 2026-06-30 08:53:05
```

已满的循环日志每写一条就挤掉最老的一条。这带来两个后果：

1. **计数类结论会假性减小**——和「近 30 天次数」是同一类陷阱，只是更隐蔽（它连"窗口"都不告诉你）。
2. **报修证据会消失**——本机最早的 41 在 2026-07-08，而日志只保留到 06-30，说明再写一段时间，最早的几次崩溃就会从日志里被挤掉。等真要走保修流程时，可能已经"查无此事"。

→ 结论：**先导出，再做统计。** 导出不需要管理员：

```powershell
New-Item -ItemType Directory -Force .\evidence | Out-Null
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} |
  Export-Clixml .\evidence\kernel-power-41.xml
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'} |
  Export-Clixml .\evidence\whea.xml
```

另外凡是报"总共 N 次"的地方，都注明**取数时刻**，否则过几天数字变了会被当成造假。

---

**P38｜两次崩溃之间的「日历间隔」不等于「连续运行时长」，绝大多数长间隔其实是关机期间。**  
判断"这次撑了多久"时，我一开始直接用相邻两次 `41` 的时间差，得出"最长干净期 57 天"这种结论——**错的**。把每个间隔窗口里的事件数、开机次数、待机进入次数数一遍就露馅了：

| 间隔（到第 N 次） | 日历天 | 机器真正在用 | 开机次数 | 进入待机 |
| --- | --- | --- | --- | --- |
| #4 | 5.06 天 | **2 天** | 3 | 9 |
| #5 | 6.79 天 | **5 天** | 6 | 7 |
| #6 | **34.27 天** | **2 天** | 3 | **3** |
| #12 | **57.11 天** | 18 天 | 33 | 454 |
| #15 | 2.90 天 | **2 天** | 3 | 0 |

那个"34 天干净期"期间机器只开过 2 天、进过 3 次待机——它根本没被暴露在故障条件里。**用日历间隔做分母会把结论抬高一个数量级。**

正确口径是**在用天数**与**待机进入次数**：按天拆开，07-08 以来只有 **31 天**机器真正开着，其中 12 天出过 `41`；真正的干净纪录是 `08-27 → 09-22` 的 **16 个在用日、443 次待机进入、零崩溃**。

→ 结论：**凡是拿"多久没出问题"当证据，都必须先回答"这段时间里机器真的用了多久、空闲了多少次"。** 计数命令（不需要管理员）：

```powershell
$ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=[datetime]'2026-07-08'}
$ev | Group-Object { $_.TimeCreated.Date } | ForEach-Object {
  [pscustomobject]@{
    Day     = ([datetime]$_.Name).ToString('MM-dd')
    Events  = $_.Count
    CsEnter = @($_.Group | Where-Object Id -eq 506).Count   # 进入连接待机
    Crash41 = @($_.Group | Where-Object Id -eq 41).Count
  }
} | Sort-Object Day | Format-Table -AutoSize
```

顺带一个副产品：这样拆开后才看得见，故障是**发作期（cluster）**式的，不是"每次空闲都掷一次骰子"——三段爆发期之间夹着 16 天完全干净的在用期。这本身就说明**单一晚上的干净记录没有统计分量**。

---

## 5. 最终技术判断

### 5.1 故障机理（当前假设）

```
系统空闲（用户不操作）
   ↓
电源管理器把活动等级降到 ActivityLevel 4（本机所有报告里最深的一档）
   ↓
CPU 请求深 C-state —— PEP（Micro Power Engine Plugin，11 个状态）决定进哪一个
   ↓
这条请求经 hypervisor 发出（栈顶 intelppm!HvRequestIdle，Hv = Hypervisor）
   ↓
某一次转换卡住，CPU 停在半个状态里，再也回不来
   ↓
整机冻死（来不及蓝屏、来不及写 dump，连电池读数都归零）
   ↓
只能长按电源键 → 下次开机记录 Kernel-Power 41（BugcheckCode=0）
```

**这条链上被证伪过的两环**：

- **第 7 轮的「PCIe 链路降档（ASPM L1.2）」**：ASPM 关闭并回读确认 `0x0/0x0` 之后，4 小时 4 分钟仍冻死。问题不在「进入深空闲时顺手做的某件事」，而在转换本身。
- **第 8 轮的「HVCI」**：`Enabled = 0`、`SecurityServicesRunning` 由 `2,3,4` 变为 `3,4` 之后，31 分 25 秒仍冻死。但 HVCI 只是 hypervisor 的安全服务，hypervisor 本身还在（`HypervisorPresent = True`、VBS = 2），所以这一环只否定了「HVCI」这个名字，没有否定「hypervisor」。

**第 19 次给出的新证据（本机唯一一组天然对照）**：

| 会话 | `ActivityLevel` | 时长 | 结果 |
| --- | --- | --- | --- |
| 14:22:28 → 14:43:00 | **0** | 1231 秒 | 正常结束（`ExitReason = Initialization`） |
| 14:43:28 → 15:14:53 | **4** | 1885 秒 | **冻死**（`ExitReason = Unknown`） |

同机、同日、同一个电源方案、相邻两段 `Type 0`（Active）会话。而这次 `STANDBYIDLE = 0`——**整机一次待机都没进**，所以问题不在 S0ix，在更下面一层的 CPU 空闲状态。

冻结瞬间的三个痕迹：日志在 `14:49:32` 之后静默 25 分钟；`ExitRemainingCapacity` 从进入时的 53626 mWh 变成 **0**（EC/SMBus 已无响应）；`WHEA` 一条都没新增。

**第 20 次（1 小时 26 分钟后）：换了个入口，同一个出口**

| 项目 | 第 19 次（15:14） | 第 20 次（16:41） | 第 21 次（17:17） |
| --- | --- | --- | --- |
| 会话类型 | `Type 0`（Active，亮屏） | `Type 1`（连接待机） | `Type 0`（Active，但屏幕已按 `VIDEOIDLE` 关闭） |
| 会话时长 | 1885 秒 | **0 秒**（没有正常退出记录） | 866 秒 |
| `ActivityLevel` | **4** | **4** | **4** |
| `ExitReason` | `Unknown` | `Unknown` | `Unknown` |
| `ExitRemainingCapacity` | **0** | **0** | **0** |
| `ConnectedStandbyInProgress` | `false` | **`true`** | `false` |
| 最后一条系统事件 | 14:49:32（Wi-Fi） | 16:20:55（`Netwaw18`） | **17:16:18**（`IsolatedUserMode`，NGC 容器停止） |
| 静默 → 重启 | 25 分钟，需长按电源键 | 20 分钟，需长按电源键 | **约 85 秒，且平台自行复位**（用户只是按了键盘） |
| 用户看到的现象 | 画面静止、屏幕亮着 | 黑屏、无响应 | **黑屏 → 按键盘 → 整机自己重启** |
| 新增 WHEA | 无 | 无 | 无 |

16:17:58 进待机（`CsEntryScenarioInstanceId = 13`，与报告的会话编号对上），16:20:55 之后彻底静默。

→ **三次的 `Type`、`Duration`、`ConnectedStandbyInProgress`、静默时长、甚至失败形态（冻死 vs 自行复位）全都不同，唯一没变的是 `ActivityLevel = 4` + `ExitReason = Unknown` + `ExitRemainingCapacity = 0`。** 这直接否掉了「必须亮屏空闲才崩」「必须进待机才崩」「必须长按电源键才能恢复」三种说法——三条路最后都汇到同一个最深空闲等级。`ActivityLevel` 比 `Type` 更能定位故障，这一点在第 20、21 次上连续成立。

**第 21 次为什么值得单独记一笔**：它把「唤醒路径」也拉进来了。17:03:20 系统刚从连接待机被键盘唤醒（`Kernel-Power 507`，`原因: Input Keyboard`），随后进入 Active 但无人操作，17:08:20 前后按 `VIDEOIDLE`（AC 300 秒）关屏；17:16:18 NGC 安全容器正常停止（最后一条事件）；**约 85 秒后用户按键盘，机器没有亮屏，而是整机复位**——`BugcheckCode = 0`、`PowerButtonTimestamp = 0`、`LongPowerButtonPressDetected = false`，说明**不是长按电源键、也不是蓝屏**，是平台自己复位。


原本支持 ASPM 假说的线索并没有消失，只是指向变了：同型号那台机器关 ASPM 有效、本机无效——**要么存在多种根因，要么 ASPM 只是掩盖了其中一部分**。

### 5.2 置信度评估

| 判断                  | 置信度    | 依据                                                                                       |
| ------------------- | ------ | ---------------------------------------------------------------------------------------- |
| 故障与睡眠/息屏无关，是「空闲即死」  | **极高** | 21 次全量回溯，7 次明确不在待机中、14 次在待机中——**两边都死**；第 19 次 `STANDBYIDLE = 0` 全程未进待机仍冻死                                        |
| 故障跨 BIOS 版本，刷固件解决不了 | **高**  | 01.03.00 / 01.04.03 / 01.05.04 三个版本都崩；最新版刷后 58 分钟复现                                      |
| 不是电池、内存、SSD、外设      | **高**  | 电池循环 2 次、双条同型号内存、SSD 无错误计数、无外接设备                                                         |
| 崩溃发生在最深空闲等级（`ActivityLevel 4`） | **高** | 21 次里凡 `ExitReason = Unknown` 的记录 `ActivityLevel` 全为 4；正常结束的全为 0；同机同日有天然对照；第 19（Active）、第 20（待机）、第 21（关屏 Active）三种形态均命中              |
| 故障点在 CPU 空闲状态转换本身 | **中高** | ASPM 排除、HVCI 排除后，剩下的只有 PEP 的 C-state 选择；`Kernel-Processor-Power` 事件 55 显示空闲状态由 PEP（11 状态）管理 |
| ~~ASPM 是直接诱因~~          | **已否证** | 2026-10-28：ASPM 关闭并回读确认 `0x0/0x0`，4h04m 后第 18 次冻死。**排除 PCIe 链路层**                      |
| ~~HVCI 参与其中~~           | **已否证** | 2026-10-28 15:14：`Enabled = 0` 回读确认，31m25s 后第 19 次冻死。**但 hypervisor 本身仍未排除**           |
| hypervisor 是必要条件        | **中低** | 崩溃栈顶 `HvRequestIdle` 指向它，但**尚未真正摘掉**（`HypervisorPresent` 一直为 `True`）；同型号那台机器的 VBS 状态未知 |
| 是平台/固件级缺陷而非用户配置     | **中高** | HP 员工仅定性为 "power management or driver interaction during idle-state transitions"，未承认已知缺陷；用户可调项（BIOS/ASPM/HVCI）全部无效，支持这一判断 |

---

## 6. 处置与验证

### 6.1 当前配置实况（2026-10-28 15:18 实测）

| 项目                                | 值                                     | 评估                                                    |
| --------------------------------- | ------------------------------------- | ----------------------------------------------------- |
| **PCIe 链接状态电源管理 (ASPM)**          | `0x0` / `0x0` = 关闭（AC + DC）           | ❌ **已证伪**：10-28 10:08 改好并回读验证，**4h04m 后第 18 次冻死**   |
| **内存完整性 (HVCI)**                   | **已关闭**（`Enabled = 0`；`SecurityServicesRunning` = `3,4`） | ❌ **已证伪**：14:22 关闭重启，**31m25s 后第 19 次冻死**            |
| **hypervisor**                    | 17:20 复查（第 21 次之后）：`HypervisorPresent = True`、VBS = 2、`EnableVirtualizationBasedSecurity = 1`（**仍为 1**）、`WasEnabledBy = 1`、`RequirePlatformSecurityFeatures = 3`。15:39 那次 `apply` 只动了 `bcdedit`，且回读因 `bcdedit /enum {current}` 报错而失真，**BCD 实际值至今未能确认** | ⏳ **第 9 轮实质上还没开始**：`EnableVBS` 仍是 1 说明升级后的 `apply`（会同时关 VBS）**从未执行过**。所以第 20、21 次都不是「第 9 轮失败」，是**在干预完全没生效的状态下又崩了两次** |
| 待机超时 `STANDBYIDLE`               | `0` / `0` = **从不进入待机**                | 关键：第 19 次全程未进待机照样冻死，说明与睡眠无关                          |
| 快速启动（HiberbootEnabled）            | `1` = 开启                              | 未改（可选，非核心）                                            |
| 关屏超时 `VIDEOIDLE`                  | AC = 300 s / DC = 180 s                | 与崩溃无关（第 19 次亮屏时冻死）                                    |
| 最小处理器状态 `PROCTHROTTLEMIN`         | `0x5` = 5%（AC / DC 同值）               | 未改。注意它控制 **P-state**，不控制 C-state——别指望改它能绕开故障      |
| BIOS `Extended Idle Power States` | Enable                                | **第 4 步候选**：直接限制 package C-state 深度                  |

> 上表 ASPM 那一行是**本机当前状态**。具体怎么改的、怎么回读验证的见 **6.1.1**；图形界面看不到这个选项时用 **6.1.2**。  
> **但要注意：改完并不解决问题，只是排除了一个变量。** 已经这样排除掉三项了（BIOS / ASPM / HVCI）。

### 6.1.1 关闭 ASPM 的完整步骤（图形界面，操作已验证有效）

> **⚠️ 先说结论：操作本身有效，但它解决不了这个故障。** 本节保留有两个用处：① 如果你想自己排除这个变量，照着做就行；② 告诉你「改完怎么确认真的改到了」——绝大多数人以为改好了，其实只改了一个下拉框。
>
> 改完请回到 **§6.2** 继续下一步。

这条是**本机实际采用的做法**——比跑脚本更直观，改完当场能看到下拉框变成「关闭」。全程不需要命令行、不需要管理员权限弹窗（点「应用」时若弹出 UAC 确认即可）。

**第 0 步：先确认这个选项在你机器上没被隐藏**（约 10 秒，避免白跑一趟）

打开 PowerShell，执行：

```powershell
powercfg -attributes SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```

- 输出 **`None`** → 没被隐藏，图形界面一定看得到，继续往下。
- 输出里出现 `ATTRIB_HIDE` → 被隐藏了。这时图形界面看不到，**只能走命令行**（见本文 6.1.2 的脚本方式）。

> 本机返回 `None`，所以下面这条路走得通。这一步别省——Modern Standby 机型隐藏电源项是常态，先查再点能省一轮来回。

**第 1 步：打开电源计划**

`Win + R` → 输入 `powercfg.cpl` → 回车。

**第 2 步：进当前方案的设置**

找到**当前正在使用的方案**（本机是「HP Optimized」，它左侧有选中圆点），点它右侧的「**更改计划设置**」。

> 注意别点错方案。改的是「当前方案」，不是列表里的其他项。如果同时改了 HP Optimized 又切到「平衡」，改动不会跟过去（见 P27）。

**第 3 步：进高级设置**

点「**更改高级电源设置**」，展开一个树形对话框。

**第 4 步：找到 PCI Express 节点**

展开 **「PCI Express」** → **「链接状态电源管理」**。

> 如果这一项显示为灰色，说明被隐藏了，回第 0 步走命令行。

**第 5 步：两个都改「关闭」**

这里有两个下拉框，**必须都改**：

| 下拉框 | 改成 |
|---|---|
| 使用电池 | **关闭** |
| 接通电源 | **关闭** |

原来两个都是「最大电源节省量」（也就是 `0x2`，最激进的一档）。

**第 6 步：保存**

点「**应用**」→「**确定**」。对话框关闭即生效，**不需要重启**。

**第 7 步：回读验证（必做，别信界面）**

回到 PowerShell 执行：

```powershell
powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```

看末尾两行：

```
当前交流电源设置索引: 0x00000000
当前直流电源设置索引: 0x00000000
```

**两个都是 `0x00000000` 才算成功。** 只要有一个还是 `0x2`，说明那个下拉框没改到——回去重改那一项。

> 本机 2026-10-28 10:08 实测结果：`0x0 / 0x0`，已验证生效。

**三个容易翻车的点**

| 坑 | 现象 | 处理 |
|---|---|---|
| **切电源方案会打回原值** | 改完好好的，某天切到「平衡」再切回来，ASPM 又变 `0x2` | 方案之间互不继承（P27）。每次切方案后重跑第 7 步回读，不对就重改 |
| **只改了「接通电源」** | 插电时正常，拔电用电池照样崩 | Step 5 的**两个下拉框都要改**。本机 AC/DC 原来都是 `0x2` |
| **以为换「平衡」方案就万事大吉** | 「平衡」下 ASPM 实测仍是 `0x2` | 「平衡」在 PCIe 这一项是**固定取值**，不是动态判断，Windows 挑的正好是要避开的那个（P26）。换方案替代不了手动关 |

### 6.1.2 命令行 / 脚本方式（等价，适合批量和远程）

图形界面看不到这一项、或者要给多台机器批量处理时用。两种做法效果完全等同，**选一个就行，不要混着理解**：

**方式 A：单条命令**

```powershell
# 管理员 PowerShell 下执行
powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setactive SCHEME_CURRENT
```

**方式 B：仓库里的脚本**（位于 `scripts/`，以下命令在仓库根目录执行）

```powershell
# 管理员终端
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 status   # 先看现状
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 apply    # 关 ASPM + 关快速启动
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 revert   # 回滚成 0x2
```

`apply` 比单条命令多做两件事：**执行前把当前方案导出备份**到桌面 `power-backup-before-aspm.pow`，以及**顺手关掉快速启动**。其它等价。

> 回滚方式：图形界面把两个下拉框改回「最大电源节省量」，或跑 `revert`。**改之前建议先导出备份**：`powercfg /export "$env:USERPROFILE\Desktop\power-backup.pow" SCHEME_CURRENT`。

### 6.1.3 观察基线（判定依据）

| 指标                     | 基线值（10-28 17:35，BIOS 关掉深度空闲态之后） |
| ---------------------- | ----------------------------- |
| `Kernel-Power 41` 历史总数 | **21**                        |
| 最近一次异常断电（记录时刻）         | **2026-10-28 17:17:46**       |
| 最早一次                   | **2026-07-08 11:12:26**       |

> **第 10 轮干预已于 2026-10-28 17:35:27 生效**：BIOS 里 `Extended Idle Power States` 设为 `Disable`（本机 `X72 01.05.04`）。这是目前唯一直接限制 package C-state 深度的开关，正对 `ActivityLevel 4` 这个唯一不变量。**从这一刻起计时，判负口径不变。**

**判定标准：「最近一次异常断电」时间戳是否仍停在 `10-28 17:17:46`。** 只看这一个数，观察 3–5 天。

- 仍停着 → 这个改动有效，保持。
- 时间戳前进 → 无效，进入 §6.2 下一步。

> **第 10 轮中途记录（19:06，BIOS 生效后 1 小时 31 分、距第 21 次崩溃 1 小时 49 分）**：无 `Kernel-Power 41`、无 `6008`、无 `1001`。期间**顺利进出连接待机 3 次**：`17:59:56 → 18:47:00`（47 分钟）、`18:47:41 → 18:50:01`、`18:50:32 → 19:06:01`——全部正常退出。而今天下午那几次崩溃，都是在进入待机后**20 分钟内的静默期**里死的。这是今天第一次撑过这个窗口。

> **但 1 小时 31 分远不足以判「修好了」，判据必须用「在用天数」而不是「日历天数」。**（我先前的算法错了，见 P38。）
>
> 把 07-08 以来的日志按天拆开：**只有 31 天机器真正开着**，其中 12 天出过 41、19 天干净。真正的干净纪录是 **`08-27 → 09-22` 连续 16 个在用日、443 次进入连接待机、零崩溃**（占全部 558 次待机进入的 79%）。而 07-08 ~ 07-21、08-24 ~ 08-26、10-22 ~ 10-28 三段则以集群形式爆发。
>
> 两个结论：
> 1. **故障是"发作期"式的，不是每次空闲都掷骰子**——所以一晚干净说明不了什么，一晚是 5–10 次待机进入，只是那 443 次的 2%。
> 2. 真正有分量的判据有两个：**连续 5 个以上在用日不出 41**（历史最好 16 天），以及下一次 sleepstudy 里长待机会话 `ActivityLevel` 为 **0** 而非 4。

> **第 10 轮过夜记录（2026-10-29 09:25，生效后 15 小时 50 分）**：零 `41`、零 `6008`、零 `1001`，期间**没有重启过**（uptime 连续 15h50m）。整夜的待机进出全部正常退出：

| 进入 | 退出 | 时长 | 结果 |
| --- | --- | --- | --- |
| 10-28 21:22:06 | **10-29 09:25:17** | **12 小时 03 分** | 正常唤醒（`Kernel-Power 507`，`reason=32`），无复位 |
| 10-28 19:55:42 | 10-28 21:06:33 | 70 分 | 正常 |
| 10-28 19:11:32 | 10-28 19:11:48 | 16 秒 | 正常 |
| 10-28 17:59:56 / 18:47:41 / 18:50:32 | 各自退出 | 2～47 分 | 全部正常 |

**为什么这段比"一晚上没崩"重得多**：故障的发作窗口很短——第 20 次是进待机约 **3 分钟**后开始静默、20 分钟后整机已死；第 18 次约 25 分钟后静默。也就是说只要真的落到 `ActivityLevel 4`，**20 分钟内就会出事**。而这次一段 **12 小时**的连续深待机安然退出，暴露时长是原窗口的 30 倍以上。这不是"没碰上"，是**这条路径确实被改变了**。

整夜唯一的 error 级事件是 `LanguagePackSetup`（1 条，与本故障无关），无 WHEA 新增。

**状态：初步有效，尚未定论。** 按 P38 的口径，需要 **5 个以上在用日**；今天是第 1 天。上一个「连续 16 个在用日不崩」的历史纪录说明这台机器有能力长时间不出事，所以现在唯一要做的就是继续用、别改任何设置。

> **已按此口径判负两次（范例）**：
> - 第 7 轮 ASPM：基线 `17 次 / 09:33:54` → 10:08 关 ASPM，14:12:20 前进，**4h04m 判负**。
> - 第 8 轮 HVCI：基线 `18 次 / 14:12:20` → 14:22 关 HVCI，15:14:53 前进，**31m25s 判负**。
>
> 口径本身没问题——**是这个样本判负得太快了**，说明这两项都不在因果链上。

> **第 20、21 次都不算第 9 轮判负**（这点必须分清）：16:41 与 17:17 两次崩溃后复查，`EnableVirtualizationBasedSecurity` 仍是 `1`、`HypervisorPresent` 仍是 `True`，说明升级后的 `apply`（会同时关 VBS）从未执行。也就是说第 9 轮**还没开始**，不能用这两次去否定它。这条同样是踩坑：**判负的前提是确认干预真的生效了**，而不是"我执行过命令"。

> **口径警告**：不要用「近 30 天次数」判定。那是滚动窗口，旧事件会自然滚出，会让人误以为好转。**只看最近一次的时间戳。**

### 6.2 分步处置顺序（每步观察 3–5 天）

| # | 措施                                                                                                              | 状态                                                                        |
| --- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| 0 | BIOS 升级到 `X72 01.05.04`（HP 当前最新）                                                                                    | ❌ **已证伪**（刷后 58 分钟即复现）                                                    |
| 1 | `fix-idle-hang.ps1 apply` → ASPM 设为「关闭」（AC+DC）                                                                    | ❌ **已证伪**（10-28 10:08 关闭并验证 `0x0/0x0`，14:12 第 18 次冻死）                 |
| 2 | 关闭内存完整性（HVCI），重启观察                                                                                              | ❌ **已证伪**（14:22 关闭重启，`Enabled = 0` 回读确认，15:14 第 19 次冻死）            |
| 3 | `disable-hypervisor.ps1 apply` → **同时**关 VBS 注册表开关与 `hypervisorlaunchtype`，重启观察                          | ⏸️ **暂缓，被第 4 步抢先**：第一次只关了 `bcdedit`，被 VBS 架空（P34），升级后的 `apply` 从未执行。第 4 步更贴靶心且不牺牲虚拟化，故先走第 4 步；第 4 步判负后再回来执行它  |
| 4 | BIOS 里 `Extended Idle Power States` 设 `Disable`；或 HP 应用 System Control 从 Smart Sense 改 High Performance            | 🟢 **当前步骤（10-28 17:35:27 生效）— 15h50m 零复现，含 12h03m 连续待机**：BIOS `X72 01.05.04` 中已设 `Disable`。**直接限制 package C-state 深度**，代价是续航变差，不影响虚拟化。**观察中，需 5 个以上在用日** |
| 5 | 报修（材料见 `warranty-claim.md`）                                                                                     | 材料已备，含第 19 次现场                                                          |

**第 3、4 步为什么都指向 CPU 空闲路径**：崩溃栈顶部是 `intelppm!HvRequestIdle`，`Hv` = **Hypervisor**；本机 `Kernel-Processor-Power` 事件 55 又显示空闲状态由 **Micro Power Engine Plugin（11 个状态）** 管理——正是栈里 `PepIdleExecute` 那一层。ASPM 和 HVCI 被排除之后，只剩这条链。

**如果只能选一个**：第 4 步比第 3 步更贴靶心（直接砍掉最深 package C-state），代价是续航变差而不是废掉虚拟化。第 3 步胜在一条命令、可逆。**实际选择：先走第 4 步**（10-28 17:35 已生效）。

### 6.3 已回退 / 已废弃

- **关闭 PCIe ASPM（第 7 轮方案）**：2026-10-28 实测无效。设置目前仍留在 `0x0/0x0`——回滚也没有收益（关掉 ASPM 会略增功耗，想省电可以 `revert`，但别指望它影响故障频率）。⚠️ **README 曾把它写成「修复方法」，那是错的，已于 10-28 更正。**
- **关闭内存完整性（第 8 轮方案）**：2026-10-28 实测无效，31 分 25 秒后第 19 次冻死。设置保持关闭状态（回滚没有收益，且它只是 hypervisor 的一个安全服务，第 9 轮会一并处理）。
- **「待机中跑 Windows 更新是诱因」**：**已排除**。20 次崩溃里只有 **6 次**在崩溃前 90 分钟内有更新活动，其余 14 次毫无更新。第 18 次恰好赶上了批量装应用，属于巧合。
- **「靠不进待机来回避」（第 4、5 轮思路）**：**已彻底排除**。第 19 次在 `STANDBYIDLE = 0`（从不进待机）、全程 `Type 0` 的情况下照样冻死；第 21 次则是「关屏但未进待机」时直接复位。
- `power-mode.ps1` 的 `remote` 模式（AC 永不息屏）：**无效且费电**，不再推荐（脚本文件保留，仅 `hibernate` 档可作兜底）。
- 第一版 Word 取证报告（`output/` 下）：含 BIOS 版本错误与过时结论，**连同整个流水线中间件已于 10-28 删除**，以本目录两份 MD 为准。

---

## 7. 遗留问题

| 问题                        | 说明                                                                   |
| ------------------------- | -------------------------------------------------------------------- |
| AMD/Intel 固件层面能否根本修复      | 只能等 HP 出新 BIOS，且要求 release notes 出现 Modern Standby / idle 相关修复；无固定周期 |
| **摘掉 hypervisor 后若仍崩，还剩什么** | 下一位是 BIOS 的 `Extended Idle Power States`（直接限制 package C-state 深度）。再往下就是平台固件本身，用户侧已无可调项——那时只能报修或等 HP 出 BIOS |
| 为什么第 19 次崩溃前 25 分钟零事件 | `14:49:32` 之后到 `15:14:50` 重启，系统日志完全静默 25 分钟——**冻死时来不及记录任何东西**，这也是抓不到 dump 的同一个原因。同一现象在第 18 次也出现过（静默 22 分钟） |
| 为什么 `ExitRemainingCapacity` 会变成 0 | 进入时读到 53626 mWh，退出时读到 **0**。说明冻结瞬间连 EC / SMBus 都不响应了。这更像平台整体停摆，而不是某个驱动挂掉——但还不能据此指认具体硬件 |
| 为什么第 18、19、20 次没有 WHEA 记录 | WHEA 停在 `10-28 09:34:09`（第 17 次），此后三次崩溃一条都没新增。**WHEA 与崩溃并非一一对应**，不能拿"没有 WHEA"反证硬件正常。原因未明 |
| 为什么同型号机器关 ASPM 有效、本机无效    | 目前无法解释。可能是不同批次的固件差异，也可能是两台机器的根因本就不同——但这意味着**网上任何「关 ASPM 就好了」的经验都不该当作通用解** |
| 远程可用性 vs 休眠兜底             | 休眠时远程连不上（物理限制），需配 WOL 才能兼顾                                           |
| `DEADBEEF` 36% 的真实含义      | 已知是「结构体未初始化」，但无法判断是「代码忘初始化」还是「SPI/NVRAM 区域损坏」                        |
| 6008 自报时间错位原因             | 已记录为不可信，未深究具体成因。第 18 次：6008 报 `13:43:59`，但 13:50:14 仍有 Wi-Fi 事件，说明它记的不是崩溃时刻 |
| 10-23 17:03 那次 17.4 W 的归因 | `SrumData` 为空，报告无法给出进程级能耗，查不到当时是谁在跑                                  |
| 为什么第 18 次崩溃前没有任何预兆事件      | 13:50:14 Wi-Fi 事件之后到 14:12 重启，系统日志完全静默 22 分钟——**冻死时来不及记录任何东西**，这也是抓不到 dump 的同一个原因 |

---

## 附：可复现的取证命令

```powershell
# 1. 睡眠研究（生成的 HTML 数据在 var LocalSprData 里）
powercfg /sleepstudy

# 2. 全部异常断电（关键字段：ConnectedStandbyInProgress / BugcheckCode / LongPowerButtonPressDetected）
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 60 |
  Sort-Object TimeCreated | ForEach-Object {
    $d=@{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }
    [pscustomobject]@{
      时间=$_.TimeCreated
      CS中=$d['ConnectedStandbyInProgress']
      Bugcheck=$d['BugcheckCode']
      长按=$d['LongPowerButtonPressDetected']
    }
  } | Format-Table -AutoSize

# 3. 固件错误记录
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'} |
  Group-Object Id | Select-Object Name,Count

# 4. BIOS 真实版本史（唯一可靠来源）
Get-WinEvent -LogName 'HP SFU Service' | Where-Object { $_.Message -match 'BIOS' } |
  Sort-Object TimeCreated | Select-Object TimeCreated,Message

# 5. 当前 ASPM 档位（0=关闭 1=中等 2=最大电源节省量）
powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```
