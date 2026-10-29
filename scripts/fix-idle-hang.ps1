<#
  fix-idle-hang.ps1  —  HP ProBook 4 G1i 14 空闲卡死「诊断」工具
  目标：检查/设置 PCIe 链接状态电源管理（ASPM）与快速启动。

  ⚠️ 2026-10-28 实测更新：这条措施在本机【无效】。
     ASPM 已关闭并回读确认 0x0 / 0x0（AC + DC），4 小时 4 分钟后（14:12）仍然冻死，为第 18 次。
     保留本脚本的用途是：① 帮你排除这个变量  ② 随时回读当前档位。
     不要指望 apply 之后问题就消失 —— 详见 docs/troubleshooting-log.md 第 8 轮。

  📌 2026-10-29 14:35：本机已执行 revert，ASPM 回到出厂默认 0x2（AC + DC 均已回读确认）。
     本机真正的修复是 BIOS 里的 Extended Idle Power States = Disable，与本脚本无关。
     现在再跑 apply 只会让 PCIe 链路常开、白耗电，不会改善故障。
     另外：实测普通用户即可修改「当前」电源方案，不必以管理员身份运行（见 P42）。

  用法（必须以管理员身份运行，在仓库根目录执行）：
      powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 status
      powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 apply
      powershell -ExecutionPolicy Bypass -File .\scripts\fix-idle-hang.ps1 revert

  apply  = ASPM 关闭（交流 + 电池），并关闭快速启动
  revert = ASPM 恢复为「最大电源节省量」(2)

  注意：apply 只改「当前电源方案」。切换电源方案后设置不会跟过去（方案间互不继承），
        需要对新方案再执行一次 apply。改完务必跑 status 回读确认两个值都是 0x0。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'revert')]
    [string]$Mode = 'status'
)

$ErrorActionPreference = 'Stop'

$SUB_PCIEXPRESS = 'SUB_PCIEXPRESS'
$ASPM           = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
$SUB_BUTTONS    = 'SUB_BUTTONS'
$LIDACTION      = '5ca83367-6e45-459f-a27b-476b1d01c936'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PowerValue([string]$sub, [string]$setting) {
    $out = powercfg /query SCHEME_CURRENT $sub $setting 2>$null
    if (-not $out) { return @{ AC = $null; DC = $null } }
    $ac = ($out | Select-String '当前交流电源设置|Current AC Power Setting' |
           ForEach-Object { ($_ -split ':')[-1].Trim() }) | Select-Object -First 1
    $dc = ($out | Select-String '当前直流电源设置|Current DC Power Setting' |
           ForEach-Object { ($_ -split ':')[-1].Trim() }) | Select-Object -First 1
    @{ AC = $ac; DC = $dc }
}

function Get-SchemeGuid {
    $line = powercfg /getactivescheme
    $m = [regex]::Match($line, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { $m.Value } else { $null }
}

function Get-AspmName([string]$hex) {
    switch ($hex) {
        '0x00000000' { '关闭  <- 缓解措施要的就是这个' }
        '0x00000001' { '中等电源节省量' }
        '0x00000002' { '最大电源节省量（Windows 出厂默认值；本机已恢复到此档）' }
        default      { $hex }
    }
}

function Show-Status {
    Write-Host "===== PCIe 链接状态电源管理（ASPM）====="
    $a = Get-PowerValue $SUB_PCIEXPRESS $ASPM
    Write-Host ("  接电源 : " + (Get-AspmName $a.AC))
    Write-Host ("  用电池 : " + (Get-AspmName $a.DC))

    Write-Host " "
    Write-Host "===== 其它相关状态 ====="
    $vbs = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $vbsTxt = switch ($vbs.VirtualizationBasedSecurityStatus) {
        0 { '未启用' } 1 { '已启用但未运行' } 2 { '运行中' } default { '未知' }
    }
    Write-Host ("  虚拟化安全 VBS     : $vbsTxt  (运行的服务: " + ($vbs.SecurityServicesRunning -join ',') + ")")

    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    Write-Host ("  快速启动           : " + $(if ($hb -eq 1) { '开启' } else { '关闭' }))

    $mei = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceName -match 'Management Engine Interface' } | Select-Object -First 1
    if ($mei) { Write-Host ("  Intel MEI 驱动     : " + $mei.DriverVersion) }

    $ipf = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceName -match 'Innovation Platform Framework Manager' } | Select-Object -First 1
    if ($ipf) { Write-Host ("  Intel IPF 驱动     : " + $ipf.DriverVersion + "  (平台电源框架，管空闲状态转换)") }

    try {
        $bi = Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HPBIOS_BIOSEnumeration -ErrorAction Stop
        foreach ($n in @('Extended Idle Power States', 'Runtime Power Management', 'Power Control')) {
            $s = $bi | Where-Object { $_.Name -eq $n } | Select-Object -First 1
            if ($s) { Write-Host ("  BIOS " + $n.PadRight(18) + " : " + $s.CurrentValue) }
        }
    } catch { }

    # 判定只看「最近一次异常断电的时间戳」，不要用滚动窗口的次数：
    # 旧事件会自然滚出 30 天窗口，次数下降是假象，会让人误以为好转。
    $k41 = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41 } -MaxEvents 300 -ErrorAction SilentlyContinue)
    Write-Host ("  异常断电历史总数   : " + $k41.Count + " 次")
    if ($k41.Count -gt 0) {
        $sorted = @($k41 | Sort-Object TimeCreated)
        Write-Host ("  最早一次           : " + $sorted[0].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host ("  最近一次（判定基线）: " + $sorted[-1].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host "  判定：改完后观察 3-5 天，这个「最近一次」时间戳不再往前 = 有效；前进了 = 无效，执行 revert 并进入下一步。"
    } else {
        Write-Host "  未发现异常断电记录（Kernel-Power 41）。"
    }
}

function Invoke-Apply {
    Write-Host "备份当前电源方案到桌面 ..."
    $bak = Join-Path ([Environment]::GetFolderPath('Desktop')) 'power-backup-before-aspm.pow'
    powercfg /export $bak SCHEME_CURRENT 2>$null | Out-Null
    if (Test-Path $bak) { Write-Host "  已备份: $bak" }

    Write-Host "关闭 PCIe 链接状态电源管理（交流）..."
    powercfg /setacvalueindex SCHEME_CURRENT $SUB_PCIEXPRESS $ASPM 0
    Write-Host "关闭 PCIe 链接状态电源管理（电池）..."
    powercfg /setdcvalueindex SCHEME_CURRENT $SUB_PCIEXPRESS $ASPM 0
    Write-Host "应用方案..."
    powercfg /setactive SCHEME_CURRENT

    Write-Host "关闭快速启动（多次强制断电后，它能避免文件系统被反复写坏）..."
    try {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
        Write-Host "  已关闭（下次关机生效；休眠功能本身保留）"
    } catch { Write-Host "  修改失败: $($_.Exception.Message)" }

    Write-Host " "
    Write-Host "完成。验证结果：" -ForegroundColor Green
    $a = Get-PowerValue $SUB_PCIEXPRESS $ASPM
    Write-Host ("  接电源 : " + (Get-AspmName $a.AC))
    Write-Host ("  用电池 : " + (Get-AspmName $a.DC))
    Write-Host " "
    Write-Host "接下来请正常使用 3-5 天观察。判定标准（只看时间戳，不看次数）："
    Write-Host "  最近一次异常断电的时间戳不再往前 -> 就是这个原因，保持现状"
    Write-Host "  时间戳继续往前                   -> 无效，执行 revert，然后关内存完整性再试"
}

function Invoke-Revert {
    Write-Host "恢复 PCIe 链接状态电源管理为「最大电源节省量」(2)..."
    powercfg /setacvalueindex SCHEME_CURRENT $SUB_PCIEXPRESS $ASPM 2
    powercfg /setdcvalueindex SCHEME_CURRENT $SUB_PCIEXPRESS $ASPM 2
    powercfg /setactive SCHEME_CURRENT
    $a = Get-PowerValue $SUB_PCIEXPRESS $ASPM
    Write-Host ("  接电源 : " + (Get-AspmName $a.AC))
    Write-Host ("  用电池 : " + (Get-AspmName $a.DC))
    if ($a.AC -ne '0x00000002' -or $a.DC -ne '0x00000002') {
        Write-Host "回读值与预期 (0x00000002) 不一致——请用「终端(管理员)」重跑本命令。若刚切换过电源方案，也要重跑（方案间不继承）。" -ForegroundColor Yellow
    }
}

if ($Mode -eq 'status') {
    Show-Status
    exit 0
}

# 2026-10-29 实测（P42）：powercfg 修改「当前」电源方案并不需要管理员权限。
# 因此这里不再硬性拦截，只在非管理员时提示一句——真正的判据是执行后的回读值。
if (-not (Test-Admin)) {
    Write-Host "提示：当前会话非管理员。本机实测修改当前电源方案无需提权，将直接尝试；若回读值没变化，再用管理员终端重跑。" -ForegroundColor Yellow
}

switch ($Mode) {
    'apply'  { Invoke-Apply }
    'revert' { Invoke-Revert }
}
