# HP ProBook 4 G1i 14 空闲冻死 — 已解决

**症状**：空闲时整机冻住，无蓝屏、无 dump，只能长按电源键。
**解法**：BIOS 里把 `Extended Idle Power States` 设为 `Disable`。
**结果**：113 小时 29 分、81 次待机、累计 42 小时 31 分实际待机，零复现。

*Idle hard-freeze on a HP ProBook 4 G1i 14 — fixed by setting BIOS `Extended Idle Power States` to `Disable`. Verified over 113 h uptime / 81 standby cycles, zero freezes.*

---

## 现象

2026-07-08 至 2026-10-28，共 **21 次**异常断电（`Kernel-Power 41`，`BugcheckCode = 0`）。

典型现场：屏幕亮着、没开任何程序、整机功耗约 4 W，然后突然定格——鼠标键盘全无反应，风扇还在转，**不蓝屏、不重启、不写 dump**，只能长按电源键。开机后日志里补记一条 `Kernel-Power 41`，`BugcheckCode` 为 `0`。

有时是从待机里死的（21 次中 14 次），有时根本没进待机、纯亮屏空闲就死了（7 次）。有一次是关屏后按键盘，整机自己复位。

**判断是不是同一个病，看这几点**：

- [ ] 空闲时（CPU 接近 0）突然冻住，键鼠无响应
- [ ] 不蓝屏、不重启、不报错，只能长按电源键
- [ ] 高负载反而稳定（玩游戏、编译时不出事）
- [ ] `System` 日志有 `Kernel-Power 41`，且 `BugcheckCode = 0`
- [ ] `C:\Windows\Minidump` 是空的，没有 `MEMORY.DMP`
- [ ] 插电、用电池都会发生，屏幕亮着或关着都会发生
- [ ] BIOS 刷到最新也没改善

对上 3 条以上，大概率是同一个问题。

---

## 解法

**BIOS → `Extended Idle Power States` → 改为 `Disable` → 保存重启。**

这是 BIOS 里唯一能直接限制 **package C-state 深度**的开关，也就是不让 CPU 进最深那几档空闲状态。代价是续航略差、机身温度略高，其他没有影响——**完全不动虚拟化**（VBS、hypervisor、WSL2、Hyper-V 全程正常运行）。

### 操作

1. 关机，开机时连按 `F10` 进 BIOS Setup（本机 BIOS 版本 `X72 01.05.04`）
2. 在 `Advanced` / Power 相关的页面里找到 **`Extended Idle Power States`**
3. 改成 **`Disable`**
4. `F10` 保存退出，正常开机

> 找不到这一项时，也可以试 HP 应用里的 **System Control → 从 Smart Sense 改成 High Performance**，走的是同一条电源策略。
>
> 改完不需要重装系统、不需要动 Windows 电源方案、不需要关任何安全功能。

### 怎么确认有效

**只看一个指标**：`Kernel-Power 41` 里**最近一次**的时间戳，有没有继续往前走。

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 50 |
  Sort-Object TimeCreated | Select-Object -Last 3 TimeCreated
```

- 时间戳停住不动 → 有效，保持
- 时间戳继续前进 → 这项对你不成立，另找原因

> ⚠️ **别看「近 30 天次数」，也别看事件总数。** 那是滚动窗口，日志写满后旧事件会被挤出去，总数甚至会自己变少——本机就出现过 21 变成 20 的假好转。只有「最近一次的时间戳」是可靠的。

---

## 结果

干预时间：**2026-10-28 17:35:27**，统计至 2026-11-02 11:04。

| 指标 | 数值 |
| --- | --- |
| 连续运行 | **113 小时 29 分**（其中 97 小时 26 分未重启） |
| 进入 / 退出连接待机 | **81 / 81**，一一配对，无一缺失 |
| 累计待机 | **42 小时 31 分** |
| 单段最长 | **14 小时 25 分**，正常唤醒 |
| 第二长 | 12 小时 03 分，正常唤醒 |
| ≥20 分钟的待机 | 19 段，全部正常退出 |
| `Kernel-Power 41` / `6008` / `1001` | **五天全为 0** |

**为什么这算修好了**：干预前那半天，崩溃间隔是 63、86、37 分钟，平均 62 分钟一次，而且越来越密；干预就落在那天最后一次崩溃之后 18 分钟，此后 113 小时再没出现——约等于 **110 个「预期崩溃窗口」全部落空**。

**机理上也对得上**：`powercfg /sleepstudy` 报告里，崩溃会话的特征是 `ActivityLevel = 4`（最深活动等级）+ `ExitReason = Unknown`。179 段历史会话中 `ActivityLevel 4` 共出现 18 次，**最后一段正是第 21 次崩溃本身，干预之后 0 次**；干预后的所有待机都停在 Level 0/1 并由键鼠正常唤醒。不是「碰巧没崩」，是那条路径下不去了。

---

## 走过的弯路（别重复）

下面这些都试过，**全部无效**，不要浪费时间：

| 措施 | 结果 |
| --- | --- |
| 刷到最新 BIOS（`X72 01.05.04`） | 刷完 58 分钟就复现 |
| 关闭 PCIe ASPM（`0x0/0x0`） | 4 小时 4 分钟后复现 |
| 关闭内存完整性 HVCI | 31 分钟后复现 |
| 摘掉 hypervisor / 关 VBS | 不需要——修复后 hypervisor 全程在跑，机器照样好 |

完整排查过程、10 个数据源的能力边界、45 条踩坑，见 [`docs/troubleshooting-log.md`](docs/troubleshooting-log.md)。

---

## 仓库内容

| 路径 | 说明 |
| --- | --- |
| `docs/troubleshooting-log.md` | 完整排查记录：十轮假设、每轮的证伪证据、数据源能力边界、45 条踩坑 |
| `docs/warranty-claim.md` | 可直接套用的报修模板（21 次断电全量表、排除项、诉求表述） |
| `scripts/fix-idle-hang.ps1` | 查看 / 设置 PCIe ASPM 与快速启动（诊断用，不治病） |
| `scripts/disable-hypervisor.ps1` | 摘 hypervisor（**本机已确认不需要**，仅保留排查路径） |
| `scripts/power-mode.ps1` | 电源方案切换（`hibernate` 档可作冻死兜底） |
| `samples/sleepstudy-report.sample.html` | 脱敏后的真实 `powercfg /sleepstudy` 报告 |
| `private/` | 未脱敏原始取证材料，不进版本控制 |

---

## 三点提醒

1. **更新 BIOS 后回来看这一项。** 机器上唯一偏离出厂设置的只有 `Extended Idle Power States`，BIOS 升级可能把它重置回 `Enable`。
2. **不要 `powercfg /h off`。** 休眠是这类故障唯一的安全网（冻死前能落盘状态），关掉纯亏。
3. **别只凭「一晚上没崩」下结论。** 这台机器历史上曾连续 16 个在用日、443 次待机不崩，然后又坏了。看的是累计暴露量，不是日历天数。

---

## 适用范围

本仓库记录的是一台具体机器（HP ProBook 4 G1i 14 inch Notebook AI PC，Intel Core Ultra，Windows 11 25H2 build 26200）。同症状的其他机型可以借鉴思路，但结论不保证通用——尤其「关 ASPM 有效」这种说法，在同型号的两台机器上就得出过不同结果。

本仓库不主张这是硬件损坏：21 次全部 `BugcheckCode = 0`、WHEA 无有效组件信息，没有硬件故障的直接证据。崩溃栈和同型号群发指向平台层 / 固件的空闲电源管理缺陷。

---

**Search terms**: `HP ProBook 4 G1i 14 random freeze` · `HP laptop freezes when idle` · `Kernel-Power 41` · `BugcheckCode 0` · `no BSOD no dump` · `Modern Standby freeze` · `S0ix hang` · `Extended Idle Power States` · `package C-state` · `powercfg sleepstudy` · `ActivityLevel 4` · `intelppm!HvRequestIdle`

## License

[MIT](LICENSE)
