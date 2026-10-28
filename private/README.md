# private/

本地私有目录。**不纳入版本控制**——`.gitignore` 已排除本目录下所有文件，只放行这个 README。

把**未脱敏的原始取证材料**放这里：

- `powercfg /sleepstudy` 生成的报告（`sleepstudy-report*.html`）
- 事件日志导出（`.evtx` / `.csv`）
- `WHEA` / `WER` 原始记录
- 电源方案备份（`powercfg /export` 产生的 `.pow`）

## 为什么不入库

这些文件含个人信息，而且是**你意识不到的那种**：

| 泄露项 | 位置 | 本机样本出现次数 |
|---|---|---|
| **Windows 用户名** | 每条进程能耗记录里的 `"UserId":"..."` | **866** |
| **用户目录绝对路径** | `\Device\HarddiskVolume3\Users\<用户名>\AppData\...` | **123** |
| 计算机名 | `SystemInformation.ComputerName` | 1 |
| 电池序列号 | `Batteries[].SerialNumber` | 1 |

`powercfg /sleepstudy` 的报告本质是一份**带用户名的进程级能耗流水账**，不是"匿名系统数据"。

## 要公开怎么办

先脱敏，再放到 [`samples/`](../samples/)：

```powershell
# 至少替换掉这四类，替换后 grep 一遍确认零残留
# "UserId":"<用户名>"        -> "UserId":"user"
# Users\<用户名>              -> Users\user
# "ComputerName":"<机器名>"    -> "ComputerName":"SAMPLE-PC"
# "SerialNumber":"<电池序列>"   -> "SerialNumber":"SAMPLE-BATTERY"
```

参考已脱敏的样本：`samples/sleepstudy-report.sample.html`。
