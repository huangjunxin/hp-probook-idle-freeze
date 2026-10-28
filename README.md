# HP ProBook 4 G1i 14 — Freezes Solid When Idle, No BSOD, No Dump

**HP ProBook 4 G1i 14 笔记本「一闲就死」的完整排查记录，以及被验证过的缓解方案。**  
*A real-machine investigation into a Windows 11 idle hard-freeze — seven rounds of hypotheses, and the one mitigation that actually held.*

> **关于「死亡睡眠」这个代号 / On the name.** 我们一开始把这个故障叫作 **Dead Sleep（死亡睡眠）**，查到最后发现**叫错了**——它跟睡眠没有因果关系。名字留在这里只当个纪念。  
> *We called this bug "dead sleep" at first. That turned out to be a misdiagnosis — the freeze was never caused by sleep. The name is kept here as a memento only.*

> **English TL;DR**
>
> This repo documents a HP ProBook 4 G1i 14 inch Notebook AI PC (Intel Core Ultra, Windows 11 25H2 build 26200) that **hard-freezes when idle**: screen on, no apps running, ~4 W package power, then the whole machine locks up — mouse and keyboard dead, no blue screen, no reboot, no crash dump. Every occurrence leaves exactly one `Kernel-Power 41` event with `BugcheckCode = 0`.
>
> **17 occurrences** between 2026-07-08 and 2026-10-28, spanning **3 BIOS versions** — and **5 of them happened while the machine was not in Modern Standby at all** (plain screen-on idle).
>
> Working hypothesis: **PCIe ASPM (Link State Power Management) drops the link into a deep power-saving state during an idle transition and fails to wake up in time.** The only mitigation with same-model reproduction (two units, official HP community thread) is **disabling PCIe ASPM**. This is not a "sleep death" — it is an **"idle death"**.
>
> The docs below are written in Chinese, but every command is copy-paste ready. The two things you probably want: **`scripts/fix-idle-hang.ps1`** (the fix, 30 seconds) and **`docs/troubleshooting-log.md`** (the full investigation log — seven rounds of hypotheses, each one and what disproved it, plus 28 pitfalls).
>
> **Search terms**: `HP ProBook 4 G1i 14 random freeze` · `HP laptop freezes when idle` · `Kernel-Power 41` · `BugcheckCode 0` · `no BSOD no dump` · `Modern Standby freeze` · `S0ix hang` · `ASPM` · `PCIe Link State Power Management` · `L1.2` · `powercfg sleepstudy` · `intelppm!HvRequestIdle` · `PepIdleExecute` · `Windows 11 25H2 26200`

**症状**：CPU 请求深空闲态时整机冻死——屏幕亮着、没开任何程序、功耗只有 4 W 的时候一样会冻。  
**规模**：2026-07-08 至 2026-10-28 共 **17 次**无蓝屏硬断电，横跨 3 个 BIOS 版本，其中 **5 次发生在完全没待机的时候**。

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

第 3 条如果输出 `0x00000002`，且前两条对得上，那你和这台机器的处境一样。  
*If #3 returns `0x00000002` and #1/#2 line up, you are in the same boat.*

---

## 修复：关闭 PCIe 链接状态电源管理（ASPM） / The Fix: Disable PCIe ASPM

这是目前**唯一有同型号双机复现实证**的缓解手段。原理见下方「为什么会这样」。  
*The only mitigation with same-model, two-unit reproduction. See "Why This Happens" below.*

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

## 判定有没有效 / How to Tell If It Worked

改完后观察 **3–5 天** / *Observe for 3–5 days:*

- ✅ 「最近一次异常断电」的时间戳**停住不动** → 就是它，保持现状  
  *Timestamp of the most recent `Kernel-Power 41` **stops moving** → this was it, keep the setting*
- ❌ 时间戳**继续往前** → 无效，执行 `revert`，进入下一步  
  *Timestamp **keeps advancing** → didn't work, run `revert` and move to the next step*

仍然反复时的后续顺序（每步观察 3–5 天）：  
*If it still happens, escalate in this order (3–5 days each):*

1. ~~关闭 ASPM~~（本仓库的方案 / *this repo's fix*）
2. 关闭内存完整性 / VMBus（VBS）——本机崩溃栈里有 `HvRequestIdle`，Hyper-V 空闲钩子值得怀疑  
   *Disable Memory Integrity / VBS — the crash stack contains `HvRequestIdle`, the Hyper-V idle hook is suspect*
3. BIOS 里 `Extended Idle Power States` 设 `Disable`；或 HP 应用里 System Control 改成 High Performance  
   *Set `Extended Idle Power States` to `Disable` in BIOS, or System Control → High Performance in the HP app*
4. 以上都无效 → 带证据报修（用 `docs/warranty-claim.md` 模板）  
   *All of the above fail → open a warranty case with evidence (template: `docs/warranty-claim.md`)*

---

## 为什么会这样 / Why This Happens

```
系统空闲 → CPU 请求深空闲态（C-state / PEP idle transition）
Idle → CPU requests a deep idle state
   ↓
电源管理顺手把 PCIe 链路降到深省电档（ASPM L1.2）
Power management drops the PCIe link into a deep power-saving state (ASPM L1.2)
   ↓
唤醒请求到达，链路无法在时限内恢复
Wake request arrives, link fails to come back in time
   ↓
整机冻死（来不及蓝屏，来不及写 dump）
Whole machine hangs — too fast for a BSOD, too fast for a dump
   ↓
只能长按电源键 → 下次开机补记一条 Kernel-Power 41（BugcheckCode=0）
Hold the power button → next boot writes one Kernel-Power 41 (BugcheckCode=0)
```

与 HP 官方社区同型号帖 *"Second Probook 4 G1i 14 causes random freezes and reboot"* 一致：两台同 part number 复现，空闲必冻、高负载稳定，内核栈落在  
*Matches the official HP community thread "Second Probook 4 G1i 14 causes random freezes and reboot" — two units of the same part number, freeze always at idle, rock solid under load, with this kernel stack:*

```
intelppm!HvRequestIdle → PepIdleExecute → PpmIdleExecuteTransition → PoIdle → KiIdleLoop
```

该用户唯一有效的缓解同样是关闭 PCIe ASPM。HP 员工仅定性为 "power management or driver interaction during idle-state transitions"，**未承认为已知缺陷**。  
*That user's only effective mitigation was the same: disable PCIe ASPM. An HP employee characterised it as "power management or driver interaction during idle-state transitions" and **did not acknowledge it as a known defect**.*

---

## 仓库内容 / Repository Contents


| 路径 / Path                               | 说明 / Description                                                                                                                                                      |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/fix-idle-hang.ps1` | 关闭 ASPM + 快速启动，带备份和回滚（`status` / `apply` / `revert`）<br>*Disables ASPM + fast startup, with backup and rollback* |
| `scripts/power-mode.ps1` | 电源模式切换（`hibernate` 档可作兜底；`remote` 档已被证伪，见文档 P20）<br>*Power plan switcher (`hibernate` = fallback; `remote` was disproven, see P20)* |
| `docs/troubleshooting-log.md`           | **核心文档**：七轮结论演进、每轮被哪条证据推翻、9 个数据源的能力边界、28 条踩坑<br />**Core doc** — seven rounds of hypotheses and what disproved each, capability limits of 9 data sources, 28 pitfalls |
| `docs/warranty-claim.md`                | 可直接套用的报修模板（含 17 次断电全量表、排除项、诉求表述）<br />*Warranty claim template (full 17-event table, ruled-out causes, requested actions)*                                            |
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
- 本仓库不主张「这是硬件损坏」。在 HP 明确承认缺陷或给出修复 BIOS 之前，关 ASPM 只是**缓解**，不是根治。  
  *This repo does **not** claim the hardware is broken. Until HP acknowledges the defect or ships a fixed BIOS, disabling ASPM is a **mitigation**, not a cure.*

---

## License

[MIT](LICENSE)
