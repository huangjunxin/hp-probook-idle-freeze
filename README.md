# HP ProBook 4 G1i 14 — Freezes Solid When Idle, No BSOD, No Dump

**HP ProBook 4 G1i 14 笔记本「一闲就死」的完整排查记录——十轮假设，前九轮都被证据推翻，第十轮（BIOS 关掉深度空闲态）初步有效。**  
*A real-machine investigation into a Windows 11 idle hard-freeze — nine hypotheses, each disproved by evidence, and a tenth (disabling deep idle power states in BIOS) that has now held through a 12-hour standby session.*

> ### 🟢 最新（2026-10-29 09:25）：第 10 轮干预后 15 小时 50 分，零复现
>
> 干预内容：BIOS 里 **`Extended Idle Power States` = `Disable`**（本机 `X72 01.05.04`），2026-10-28 17:35:27 生效。这是唯一直接限制 **package C-state 深度**的开关，正对着唯一不变量 `ActivityLevel 4`。
>
> 此后经历的空闲暴露——**是这台机器四个月来最长的一段**：
>
> | 进入连接待机 | 退出 | 时长 | 结果 |
> | --- | --- | --- | --- |
> | 10-28 21:22:06 | 10-29 09:25:17 | **12 小时 03 分** | 正常唤醒，无复位 |
> | 10-28 19:55:42 | 10-28 21:06:33 | 70 分 | 正常 |
> | 10-28 17:59 / 18:47 / 18:50 / 19:11 | 各自退出 | 2～47 分 | 全部正常 |
>
> **对照很关键**：第 20 次是进入待机约 3 分钟后开始静默、20 分钟后整机已死；第 18 次约 25 分钟。而这次一段 12 小时的深空闲安然退出——**远超原来 20 分钟就出事的窗口**。
>
> **而且这一切是在虚拟化完全没动的前提下发生的**：`HypervisorPresent = True`、VBS = 2、`hypervisorlaunchtype` 仍是默认 `auto`。也就是说 `intelppm!HvRequestIdle` 这条栈当时就在，机器照样没死。**触发点不在 hypervisor 层，而在它下面一层的 package C-state 深度**——这也是为什么第 9 轮（摘 hypervisor）被撤销，不必牺牲 WSL2 / Credential Guard。
>
> **但仍不能宣布「已解决」**：按本仓库自己的口径（P38），这台机器历史上曾连续 16 个在用日不崩，所以初步结论要 **5 个以上在用日**。今天是第 1 天。**当前判定：初步有效，观察中。**
>
> ***Latest (2026-10-29 09:25): 15 h 50 min with zero recurrences after round 10.** The BIOS switch `Extended Idle Power States` was set to `Disable` (build `X72 01.05.04`) at 2026-10-28 17:35:27 — the only switch that directly caps package C-state depth, which is exactly what the sole invariant `ActivityLevel 4` points to. Since then the machine has been through its longest idle exposure in four months, including a single **12 h 03 min** connected-standby session that woke up normally (the 20th crash went silent ~3 min after entering standby and was dead within 20). **Not declared fixed yet** — by this repo's own P38 rule, a machine that once ran 16 consecutive on-days without a freeze needs 5+ on-days to call it. Day 1.*

> ### ⚠️ 干预之前的状态（2026-10-28 17:17）：21 次，没有找到有效解
>
> 三项干预已全部被证伪：**最新 BIOS**（刷后 58 分钟复现）、**关闭 PCIe ASPM**（回读确认 `0x0/0x0`，4 小时 4 分钟后冻死）、**关闭内存完整性 HVCI**（回读确认 `Enabled = 0`，31 分钟后冻死）。
>
> 第 19～21 次留下了前 18 次都没有的东西：**崩溃前的完整现场**。同一天、同一台机器，三次完全不同的入口——
> `ActivityLevel 0` 那段跑 1231 秒正常结束，`ActivityLevel 4` 那段跑 1885 秒后冻死（亮屏）；1 小时 26 分钟后再崩一次，这次是从**待机**（`Type 1`、`CS = true`）进去的；又过 36 分钟第三次，**黑屏状态下按键盘，整机自己复位**（既没蓝屏也没长按电源键）。
> 三次的 `Type`、`Duration`、是否待机、连「怎么死的」全都不同，**只有 `ActivityLevel 4` 没变**——失效瞬间连电池读数都归了零。
>
> **本仓库现在的价值不是「修复方法」，而是完整的排除过程、9 个数据源的能力边界，和 38 条踩坑记录**——帮你少走这四个月的弯路。
>
> ***No working fix after 21 occurrences.** Three interventions have been disproved: the latest BIOS, PCIe ASPM off (verified `0x0/0x0`), and HVCI off (verified `Enabled = 0`). Occurrences 19–21 did leave one thing the previous 18 never did — a complete pre-crash scene. On the same machine on the same day, three very different entry points: an `ActivityLevel 0` session ran 1231 s and ended normally, an `ActivityLevel 4` session ran 1885 s and froze with the screen on; 1 h 26 min later a second one arrived from **connected standby** (`Type 1`, `CS = true`); 36 min after that a third one **reset the machine by itself when a key was pressed on a black screen** — no BSOD, no power-button press. Type, duration, standby state and even the failure shape all differed; **only `ActivityLevel 4` stayed constant**. At the moment of failure the battery reading had dropped to zero. What this repo offers now is the **elimination process, the capability limits of 9 data sources, and 37 documented pitfalls**.*

> **关于「死亡睡眠」这个代号 / On the name.** 我们一开始把这个故障叫作 **Dead Sleep（死亡睡眠）**，查到最后发现**叫错了**——它跟睡眠没有因果关系。名字留在这里只当个纪念。  
> *We called this bug "dead sleep" at first. That turned out to be a misdiagnosis — the freeze was never caused by sleep. The name is kept here as a memento only.*

> **English TL;DR**
>
> This repo documents a HP ProBook 4 G1i 14 inch Notebook AI PC (Intel Core Ultra, Windows 11 25H2 build 26200) that **hard-freezes when idle**: screen on, no apps running, ~4 W package power, then the whole machine locks up — mouse and keyboard dead, no blue screen, no reboot, no crash dump. Every occurrence leaves exactly one `Kernel-Power 41` event with `BugcheckCode = 0`.
>
> **21 occurrences** between 2026-07-08 and 2026-10-28, spanning **3 BIOS versions** — and **7 of them happened while the machine was not in Modern Standby at all** (plain screen-on idle).
>
> Working hypothesis: the freeze happens inside the **CPU idle-state transition**, managed by the **PEP (Micro Power Engine Plugin, 11 idle states)** and requested through the hypervisor. The kernel stack from the HP community thread tops out at `intelppm!HvRequestIdle` — `Hv` meaning **hypervisor**. PCIe ASPM was the leading suspect and **has been tested and disproved on this machine**. This is not a "sleep death" — it is an **"idle death"**.
>
> The docs below are written in Chinese, but every command is copy-paste ready. Start with **`docs/troubleshooting-log.md`** (the full investigation log — ten rounds of hypotheses, each one and what disproved it, plus 38 pitfalls). The scripts are still useful as **diagnostic tools** and for the settings they check — just don't expect them to fix anything.
>
> **Search terms**: `HP ProBook 4 G1i 14 random freeze` · `HP laptop freezes when idle` · `Kernel-Power 41` · `BugcheckCode 0` · `no BSOD no dump` · `Modern Standby freeze` · `S0ix hang` · `ASPM` · `PCIe Link State Power Management` · `L1.2` · `powercfg sleepstudy` · `intelppm!HvRequestIdle` · `PepIdleExecute` · `Windows 11 25H2 26200`

**症状**：CPU 请求深空闲态时整机冻死——屏幕亮着、没开任何程序、功耗只有 4 W 的时候一样会冻。  
**规模**：2026-07-08 至 2026-10-28 共 **21 次**无蓝屏硬断电，横跨 3 个 BIOS 版本，其中 **7 次发生在完全没待机的时候**（14 次在连接待机中）。

**暴露量（这个数字比日历时间重要得多）**：这三个月里机器**真正开着的只有 31 天**，其余是关机。31 个在用日中 12 天出过 `41`；而**最长的无故障纪录是连续 16 个在用日、443 次进入连接待机、零崩溃**（`08-27 → 09-22`）。故障呈**发作期**式分布——三段爆发期之间夹着这段 16 天的干净期。**所以「一晚上没崩」在这个样本里没有任何统计分量**，详见 `docs/troubleshooting-log.md` 的 P38。

**两种表现**：大多数时候是「画面定格、键鼠无响应、必须长按电源键」（第 1～20 次）；但 2026-10-28 17:17 那一次是「黑屏 → 按键盘 → 整机自行复位」，既没蓝屏也没长按电源键。**别看现象，看 `Kernel-Power 41` 的字段**：`BugcheckCode = 0`、无 dump、`LongPowerButtonPressDetected = false`，三条对上就是同一个病。

---

## 你的机器是不是同一个病？ / Is This Your Problem?

符合以下 3 条以上，大概率是。**3 or more of these → very likely the same issue:**

- [ ] 空闲时（不操作、CPU 占用接近 0）突然整车冻住，画面静止、键鼠无响应  
  *Freezes when idle (CPU near 0%), screen frozen, mouse & keyboard dead*
- [ ] **不蓝屏、不重启、不报错**，只能长按电源键  
  ***No BSOD, no reboot, no error*** *— the only recovery is holding the power button*
- [ ] 跑高负载反而稳定（玩游戏、编译、渲染时不出事）  
  *Rock solid under heavy load (gaming, compiling, rendering)*
- [ ] 系统日志有 `Kernel-Power 41`，且 `BugcheckCode` 为 `0`  
  *`Kernel-Power 41` in System log with `BugcheckCode = 0`*
- [ ] `C:\Windows\Minidump` 是空的，也没有 `MEMORY.DMP`  
  *`C:\Windows\Minidump` is empty and there is no `MEMORY.DMP`*
- [ ] 无论插电还是用电池、无论屏幕亮还是灭，都会发生  
  *Happens on AC and battery, screen on or off*
- [ ] BIOS 刷到最新也没用  
  *Updating to the latest BIOS changed nothing*

**关键判别 / Key insight**：如果你一直以为是「睡眠」的问题，先去查一下——很多时候崩溃时**根本没进过待机**。  
*If you assumed it was a sleep problem, check first — very often the machine was never in standby when it hung.*

---

## 30 秒自查 / 30-Second Self-Check

管理员 PowerShell 里跑 / *Run in an elevated PowerShell:*

```powershell
# 1. 异常断电次数与最近时间 / Count abnormal shutdowns and show the most recent ones
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 50 |
  Sort-Object TimeCreated | Select-Object TimeCreated, Id

# 2. 崩溃时是否在连接待机中 / Was the machine in Modern Standby when it died?
#    true = 在待机 / in standby,  false = 没在待机 / NOT in standby
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 50 | ForEach-Object {
    $d = @{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
    [pscustomobject]@{ 记录时刻=$_.TimeCreated; CS中=$d['ConnectedStandbyInProgress']; Bugcheck=$d['BugcheckCode'] }
} | Format-Table -AutoSize

# 3. 当前 PCIe 链接状态电源管理档位 / Current PCIe ASPM level
#    0=关闭 off  1=中等 moderate  2=最大省电 maximum power savings
powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```

第 1、2 条对得上，症状就一致。第 3 条**只是记录当前档位，不是判据**——本机把 ASPM 关到 `0x0` 之后仍然会崩，所以 `0x2` 既不是必要条件，也不是病因。  
*If #1 and #2 match, you have the same symptom. #3 is informational only — **this machine still froze with ASPM at `0x0`**, so `0x2` is neither required nor causal.*

---

## 第一次尝试：关闭 PCIe 链接状态电源管理（ASPM）— ❌ 已证伪 / Attempt #1: Disable PCIe ASPM — DISPROVED

> **2026-10-28 实测结论：无效。** ASPM 已确认为 `0x0 / 0x0`（回读验证），**4 小时 4 分钟后第 18 次冻死**，且当时电源方案未变、设置未被打回。
>
> 保留下面这段操作步骤，是因为：① 该方法在 HP 社区另一台**同型号**机器上确实缓解过，对别人可能仍有参考价值；② “连这个都不管用”本身就是一条诊断信息——说明故障点不在 PCIe 链路层。
>
> ***Measured 2026-10-28: it does not work.** ASPM verified at `0x0/0x0` by reading back the value, and the machine froze again 4 h 4 min later (18th occurrence), with the same power plan and the setting still in place. Kept because it helped another user with the identical model, and because "even this didn't help" tells you the fault is not at the PCIe link layer.*
### 图形界面（推荐，5 步，不用命令行） / GUI (recommended, 5 steps, no CLI)

1. **先确认选项没被隐藏** / *confirm the setting isn't hidden*，PowerShell 执行：
   ```powershell
   powercfg -attributes SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
   ```
   输出 `None` 就能在界面看到；出现 `ATTRIB_HIDE` 说明被藏了，直接用下面的脚本方式。  
   *`None` → visible in the GUI. `ATTRIB_HIDE` → hidden, use the script instead.*
2. `Win + R` → 输入 `powercfg.cpl` → 回车 / *Enter*
3. 找到**当前正在使用的**方案 → 点右侧「更改计划设置」→「更改高级电源设置」  
   *Pick the **currently active** plan → "Change plan settings" → "Change advanced power settings"*
4. 展开 **PCI Express** → **链接状态电源管理** → **使用电池**和**接通电源**两个下拉框**都**改成「关闭」  
   *Expand **PCI Express** → **Link State Power Management** → set **both** "On battery" and "Plugged in" to **Off***
5. 「应用」→「确定」。**不用重启** / *Apply → OK. **No reboot needed***

> 英文版 Windows 里这一项叫 **Link State Power Management**，位置在 **PCI Express** 节点下。  
> *On an English Windows install, the item is **Link State Power Management** under the **PCI Express** node.*

### 验证（必做，别信界面） / Verify (mandatory — don't trust the dialog)

```powershell
powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5
```

末尾两行都必须是 / *The last two lines must both be:*

```
当前交流电源设置索引: 0x00000000
当前直流电源设置索引: 0x00000000
```

> 英文系统显示为 `Current AC Power Setting Index: 0x00000000` / `Current DC Power Setting Index: 0x00000000`。

只要有一个还是 `0x2`，就是没改到——回去重改那一项。  
*If either one is still `0x2`, you missed one dropdown — go back and fix it.*

### 脚本方式（等价，适合批量 / 界面看不到时） / Script (equivalent, for batch or hidden settings)

```powershell
# 管理员终端，在本仓库根目录下 / elevated terminal, from the repo root
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 status   # 看现状 / show current state
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 apply    # 关 ASPM + 关快速启动 / disable ASPM + fast startup
powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 revert   # 回滚成 0x2 / roll back to 0x2
```

---

## 三个必须知道的坑 / Three Gotchas

| 坑 / Gotcha                                                         | 说明 / Detail                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **切换电源方案会把设置打回原值**<br />*Switching power plans resets it*          | 方案之间互不继承。改完切到「平衡」再切回来，ASPM 又变 `0x2`。**每次切方案后重新回读**<br />*Plans don't inherit from each other. Switch to "Balanced" and back, and ASPM is `0x2` again. **Re-verify after every plan switch.***                                                      |
| **换「平衡」方案替代不了手动关**<br />*"Balanced" doesn't do it for you*         | 实测「平衡」和 HP Optimized 两个方案下 ASPM **都是 `0x2`**。这是固定取值，不是动态判断，Windows 挑的正好是要避开的那个<br />*Measured: **both** Balanced and HP Optimized ship ASPM at `0x2`. It's a fixed value, not a smart decision — Windows picks exactly the one you need to avoid.* |
| **不要用「近 30 天次数」判断有没有效**<br />*Never judge by "last 30 days" count* | 那是滚动窗口，旧事件会自然滚出，次数下降是假象。**只看「最近一次异常断电的时间戳」是否还在往前走**<br />*Rolling window — old events drop out and the count falls on its own. **Only check whether the timestamp of the most recent Kernel-Power 41 moved.***                                     |

还有一条：**不要 `powercfg /h off`**。休眠在这类故障里是唯一的安全网（冻死前能落盘），关掉它等于把兜底拆了，纯负收益。  
*Also: **do not run `powercfg /h off`.** Hibernation is the only safety net here (state gets flushed before a hang). Disabling it removes your fallback and buys you nothing.*

---

## 判定口径 / How to Tell If It Worked

观察 **3–5 天**，**只看一个指标**：`Kernel-Power 41` 里**最近一次**的时间戳，是不是还在往前走。

- ✅ 时间戳**停住不动** → 这个改动有效，保持  
  *Timestamp **stops moving** → this one worked, keep it*
- ❌ 时间戳**继续往前** → 无效，进入下一步  
  *Timestamp **keeps advancing** → didn't work, move on*

> ⚠️ **不要看「近 30 天次数」。** 那是滚动窗口，旧事件会自然滚出去，次数自己就降了，会制造假好转。  
> ***Never judge by the "last 30 days" count.** It's a rolling window — old events drop out and the number falls on its own. It will lie to you.*

### 处置顺序（每步观察 3–5 天）/ Escalation Order

| # | 措施 / Measure | 状态 / Status |
| --- | --- | --- |
| 0 | 升级到最新 BIOS（`X72 01.05.04`）/ *Latest BIOS* | ❌ **已证伪** — 刷后 58 分钟复现<br />*Disproved — froze 58 min after flashing* |
| 1 | 关闭 PCIe ASPM / *Disable PCIe ASPM* | ❌ **已证伪** — 2026-10-28，`0x0/0x0` 生效 4h04m 后仍崩<br />*Disproved — froze 4 h 4 min after verifying `0x0/0x0`* |
| 2 | 关闭内存完整性 HVCI / *Disable Memory Integrity (HVCI)* | ❌ **已证伪** — 14:22 关闭重启，`Enabled = 0` 回读确认，**31 分钟后仍崩（第 19 次）**<br />*Disproved — disabled and verified `Enabled = 0`, froze again 31 min later (19th)* |
| 3 | 摘掉 hypervisor：**VBS 注册表 + `bcdedit` 两个开关都要关**<br />*Remove the hypervisor: turn off **both** the VBS registry switch and `bcdedit`* | ✅ **不需要了** — 第 10 轮生效后，机器是在 **hypervisor 全程运行**（`HypervisorPresent = True`、VBS = 2）的前提下度过 12 小时连续待机的，说明触发点不在这一层<br />*No longer needed — the 12-hour clean standby happened **with the hypervisor running**, so the trigger is below it* |
| 4 | BIOS `Extended Idle Power States` = `Disable`<br />*or System Control → High Performance* | ⏳ **当前步骤** — **2026-10-28 17:35:27 已在 BIOS 中设为 `Disable` 并重启**；直接限制 package C-state 深度，不动虚拟化，代价是续航<br />*Current — set to `Disable` in BIOS on 2026-10-28 17:35:27; caps package C-state depth, costs battery life, leaves virtualisation alone* |
| 5 | 带证据报修 / *Warranty claim* | 材料已备好（含第 19～21 次现场）/ *Evidence package ready* |

**为什么第 3、4 步都指向 CPU 空闲路径**：HP 社区同型号机的崩溃栈顶部是 `intelppm!HvRequestIdle` —— **`Hv` 就是 Hypervisor**。CPU 进入空闲态这件事本身，是 hypervisor 在发请求。ASPM 关掉无效，恰好说明故障点不在 PCIe 链路层；而本机 `Kernel-Processor-Power` 事件 55 显示空闲状态由 **Micro Power Engine Plugin（11 个状态）**管理，正是崩溃栈里 `PepIdleExecute` 那一层。  
*Why steps 3–4 point at the CPU idle path: the stack tops out at `intelppm!HvRequestIdle` — **`Hv` = Hypervisor**. And this machine's `Kernel-Processor-Power` event 55 reports idle states managed by the **Micro Power Engine Plugin (11 states)** — exactly the layer `PepIdleExecute` sits in.*

---

## 为什么会这样 / Why This Happens

```
系统空闲 → 电源管理器把活动等级降到 ActivityLevel 4（本仓库所有报告里最深的一档）
Idle → the power manager drops the activity level to 4, the deepest seen in these reports
   ↓
CPU 请求深 C-state —— 由 PEP（Micro Power Engine Plugin，11 个状态）决定进哪一个
CPU asks for a deep C-state — PEP (Micro Power Engine Plugin, 11 states) picks which one
   ↓
这条请求经 hypervisor 发出（栈顶 intelppm!HvRequestIdle）
The request goes through the hypervisor (stack top: intelppm!HvRequestIdle)
   ↓
某一次转换卡住，CPU 停在半个状态里，再也回不来
One transition wedges; the CPU never completes it
   ↓
整机冻死 —— 来不及蓝屏、来不及写 dump，连电池读数都归零
Whole machine hangs: no BSOD, no dump, even the battery reading goes to zero
   ↓
只能长按电源键 → 下次开机补记一条 Kernel-Power 41（BugcheckCode=0）
Hold the power button → next boot writes one Kernel-Power 41 (BugcheckCode=0)
```

**支撑这条链路的两组证据**（2026-10-28，同机同日、同一个电源方案）。第一组是天然对照——相邻两段 Active 会话：

| 会话 | `ActivityLevel` | 时长 | 结果 |
| --- | --- | --- | --- |
| 14:22:28 → 14:43:00 | **0** | 1231 秒 | 正常结束（`ExitReason = Initialization`） |
| 14:43:28 → 15:14:53 | **4** | 1885 秒 | **冻死**（`ExitReason = Unknown`） |

之后 1 小时 26 分钟、再 36 分钟，又来了两次——**入口和「死法」都不一样**：

| 会话 | 类型 | `ActivityLevel` | 时长 | 结果 |
| --- | --- | --- | --- | --- |
| 16:17:58 → 16:41:14 | `Type 1`（待机），`CS = true` | **4** | 0 秒（无正常退出） | **冻死**（`ExitReason = Unknown`） |
| 17:03:20 → 17:17:46 | `Type 0`（Active，但已关屏），`CS = false` | **4** | 866 秒 | **按键盘后整机自行复位**（`ExitReason = Unknown`） |

全部 21 次的 `ScenarioInstances` 里，凡是 `ExitReason = Unknown` 的异常记录，`ActivityLevel` 全是 4；正常结束的全是 0。**三次崩溃的 `Type`、`Duration`、是否待机、甚至「怎么死的」全都不同，只有 `ActivityLevel 4` 不变**——所以问题既不在 S0ix 这个"睡眠流程"，也不在"亮屏空闲"这个特定场景，而在两者共有的、更下面一层的 CPU 最深空闲状态。

*Then, 1 h 26 min and 36 min later, two more — with different entry points and different failure shapes:*

| Session | Type | `ActivityLevel` | Duration | Outcome |
| --- | --- | --- | --- | --- |
| 16:17:58 → 16:41:14 | `Type 1` (connected standby), `CS = true` | **4** | 0 s (no normal exit) | frozen to death |
| 17:03:20 → 17:17:46 | `Type 0` (Active, display already off), `CS = false` | **4** | 866 s | **machine reset itself on a key press** |

*Across all 21 occurrences, every `ExitReason = Unknown` record sits at `ActivityLevel 4`; every normal record sits at 0. **Type, duration, standby state and even the failure shape all differed; only `ActivityLevel 4` stayed constant.** So the fault is neither the S0ix flow itself nor the screen-on-idle scenario, but the CPU's deepest idle state, one layer below both.*

这条链上，**PCIe ASPM 曾经是头号嫌疑**——它正好位于"进入深空闲"这一步，会顺手把 PCIe 链路降到 L1.2。HP 社区那台同型号机器关掉它就缓解了。

但本机关掉之后照样崩，所以嫌疑已经退回上一层：**问题出在空闲状态转换本身，不是它顺手做的某件事**。

*PCIe ASPM was suspect #1 on this chain — it sits exactly on the "enter deep idle" step and drops the link to L1.2. It fixed the other user's machine. It did not fix this one, which pushes the suspect one level down: **the fault is in the idle-state transition itself, not in a side effect of it.***

与 HP 官方社区同型号帖 *"Second Probook 4 G1i 14 causes random freezes and reboot"* 一致：两台同 part number 复现，空闲必冻、高负载稳定，内核栈落在  
*Matches the official HP community thread "Second Probook 4 G1i 14 causes random freezes and reboot" — two units of the same part number, freeze always at idle, rock solid under load, with this kernel stack:*

```
intelppm!HvRequestIdle → PepIdleExecute → PpmIdleExecuteTransition → PoIdle → KiIdleLoop
```

> **一条重要的负面结论**：帖子里关 ASPM 有效，本机无效。**同型号、同症状、同一个药，结果不同**——说明要么存在多种根因，要么 ASPM 只是掩盖了其中一部分。任何"我按网上说的关了 ASPM 就好了"的说法，都不能当作通用解。
>
> ***An important negative result:*** *disabling ASPM worked there and not here — same model, same symptom, different outcome. Either there is more than one root cause, or ASPM merely masked part of it. **No "I disabled ASPM and it's fine now" post should be treated as a general fix.***

HP 员工仅定性为 "power management or driver interaction during idle-state transitions"，**未承认为已知缺陷**。  
*An HP employee characterised it as "power management or driver interaction during idle-state transitions" and **did not acknowledge it as a known defect**.*

---

## 仓库内容 / Repository Contents


| 路径 / Path                               | 说明 / Description                                                                                                                                                      |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/fix-idle-hang.ps1` | 检查/设置 ASPM 与快速启动，带备份和回滚（`status` / `apply` / `revert`）。**作为诊断工具仍有价值，别指望它治病**<br>*Inspects/sets ASPM + fast startup, with backup and rollback. **Useful as a diagnostic; don't expect a cure*** |
| `scripts/disable-hypervisor.ps1` | 摘掉 hypervisor：**同时**关 VBS 注册表开关和 `bcdedit hypervisorlaunchtype`（`status` / `apply` / `revert`），带虚拟化依赖检查和冻结基线输出<br>*Removes the hypervisor by disabling **both** the VBS registry switch and `hypervisorlaunchtype`, with virtualisation-dependency checks and a freeze baseline* |
| `scripts/power-mode.ps1` | 电源模式切换（`hibernate` 档可作兜底；`remote` 档已被证伪，见文档 P20）<br>*Power plan switcher (`hibernate` = fallback; `remote` was disproven, see P20)* |
| `docs/troubleshooting-log.md`           | **核心文档**：九轮结论演进、每轮被哪条证据推翻、9 个数据源的能力边界、38 条踩坑<br />**Core doc** — nine rounds of hypotheses and what disproved each, capability limits of 9 data sources, 38 pitfalls |
| `docs/warranty-claim.md`                | 可直接套用的报修模板（含 21 次断电全量表、排除项、诉求表述）<br />*Warranty claim template (full 19-event table, ruled-out causes, requested actions)*                                            |
| `samples/sleepstudy-report.sample.html` | 脱敏后的真实 `powercfg /sleepstudy` 报告，用来看清数据结构长什么样<br />*A real, redacted `powercfg /sleepstudy` report — see what the data actually looks like*                           |
| `private/`                              | 未脱敏原始取证材料的存放位置，**不进版本控制**（见 `private/README.md`）<br />*Home for raw, unredacted evidence — **git-ignored** (see `private/README.md`)*                                 |

> `samples/` 里的报告已脱敏：计算机名、Windows 用户名、用户目录路径、电池序列号均已替换为占位符。  
> *The sample report is redacted: computer name, Windows username, user profile paths and battery serial are all replaced with placeholders.*

> **别把自己的报告直接提交上去。** `powercfg /sleepstudy` 的 HTML 里每条进程能耗记录都带 `"UserId"`（你的 Windows 用户名），本机样本出现 **866 次**，还有 **123 处** `Users\<用户名>\...` 绝对路径。先按 `private/README.md` 脱敏，再放 `samples/`。  
> ***Don't commit your own report as-is.** Every per-process energy record in the `powercfg /sleepstudy` HTML carries `"UserId"` — your Windows username, **866 times** in this machine's sample — plus **123** absolute `Users\<you>\...` paths. Redact first (see `private/README.md`), then put it in `samples/`.*

**最值得先看的是** `docs/troubleshooting-log.md` 的第 2 节和第 3 节——排查时最耗时的不是「查不到」，而是「以为这个数据源能回答，其实不能」。  
*Start with sections 2 and 3 of the investigation log. The expensive part of this debugging wasn't "couldn't find it" — it was **"assumed this data source could answer, and it couldn't."***

---

## 适用范围与免责 / Scope & Disclaimer

- 本仓库记录的是**一台具体机器**（HP ProBook 4 G1i 14 inch Notebook AI PC）的排查过程。**同症状的其他机型可以借鉴思路，但不能保证结论成立。**  
  *This documents **one specific machine**. Other models with similar symptoms may benefit from the reasoning, but the conclusion is not guaranteed to transfer.*
- `WHEA-Logger` 的 CPER 记录在本机 36% 是 `0xDEADBEEF` 未初始化填充、引用 GUID 全零——**它只能证明「上次是非正常关机」，不能指认任何具体组件**。别拿它当组件级诊断。  
  *On this machine, 36% of the `WHEA-Logger` CPER record is `0xDEADBEEF` (uninitialised memory) and every referenced GUID is zero. It only proves "last shutdown was abnormal" — **it identifies no component**. Do not use it as component-level diagnostics.*
- 脚本会修改系统电源设置。`apply` 前会自动把当前电源方案导出到桌面，但不做任何额外保护。**跑之前自己确认能接受这个改动**，出问题用 `revert` 或导入备份 `.pow` 恢复。  
  *The scripts modify system power settings. `apply` exports the current plan to the Desktop first, but offers no other protection. **Know what you're changing**; recover with `revert` or by importing the `.pow` backup.*
- **本仓库目前不提供已确认有效的修复方法。** 截至 2026-10-28 第 21 次崩溃，所有尝试过的措施（最新 BIOS、关 ASPM、关 HVCI）**全部被证伪**。ASPM 一节保留操作步骤，但它对本机无效——请勿照做后认为问题已解决。  
  *This repo **does not offer a confirmed fix.** As of the 19th freeze on 2026-10-28, every measure tried (latest BIOS, ASPM off, HVCI off) has been **disproved**. The ASPM section keeps its how-to, but **it did not work here** — do not walk away thinking it did.*
- 本仓库不主张「这是硬件损坏」。崩溃栈和同型号群发性指向**平台层/固件层缺陷**，但 21 次全部 `BugcheckCode = 0`、WHEA 无有效组件信息，**没有硬件故障的直接证据**。  
  *This repo does **not** claim the hardware is broken. The stack trace and same-model clustering point to a **platform/firmware defect**, but all 19 events carry `BugcheckCode = 0` and WHEA yields no valid component data — **there is no direct evidence of failed hardware**.*

---

## License

[MIT](LICENSE)
