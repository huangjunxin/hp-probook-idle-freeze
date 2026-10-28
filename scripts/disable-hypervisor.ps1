<#
  disable-hypervisor.ps1  —  摘掉 Hyper-V hypervisor（第 9 轮排查手段）

  为什么试这个：
    19 次冻结的崩溃栈顶部都是 intelppm!HvRequestIdle —— 这里的 Hv 就是 Hypervisor。
    CPU 决定进入哪个 C-state 时，这条路径要经过 hypervisor。关掉 HVCI 只是摘掉
    hypervisor 的一个安全服务，hypervisor 本身还在跑（VBS 状态仍为 2）。
    本脚本把 hypervisor 整个关掉，让 HvRequestIdle 这条路径彻底不被调用。

  ⚠️ 代价（关掉后立即生效，重启后确认）：
    · WSL2 / Docker Desktop / Hyper-V 虚拟机 / Windows Sandbox —— 全部无法使用
    · Credential Guard / 内存完整性（HVCI）—— 全部失效
    · 部分企业管控软件（依赖 VBS 的）可能报错

  用法（必须以管理员身份运行，在仓库根目录执行）：
      powershell -ExecutionPolicy Bypass -File .\scripts\disable-hypervisor.ps1 status
      powershell -ExecutionPolicy Bypass -File .\scripts\disable-hypervisor.ps1 apply
      powershell -ExecutionPolicy Bypass -File .\scripts\disable-hypervisor.ps1 revert

  apply  = 关两个开关（都需重启生效）：VBS 注册表总开关 EnableVirtualizationBasedSecurity=0
           + bcdedit hypervisorlaunchtype off
           只关后者是不够的 —— VBS 还开着时 Windows 会以「VBS 需要 VSM」为由强行加载
           hypervisor（2026-10-28 实测：只关 bcdedit，重启后事件 1「虚拟机监控程序已成功启动」
           照样出现，HypervisorPresent 仍为 True）。
  revert = 两个都恢复（VBS=1 + launchtype=auto），同样需重启

  判定口径：只看 Kernel-Power 41 的「最近一次」时间戳是否停住，
            不要看「近 30 天次数」—— 那是滚动窗口，会自己变小造成假好转。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'revert')]
    [string]$Mode = 'status',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LaunchType {
    # 注意：本机（Win11 26200）上 bcdedit /enum {current} 会报「指定的项类型无效」，
    # 导致回读永远拿到 $null、apply 误报写入失败。不带参数的 /enum 读的就是默认启动项，稳定得多。
    $out = bcdedit /enum 2>&1 | Out-String
    $script:LaunchReadError = ($out -match '拒绝访问|Access is denied|无法打开')
    if ($out -match 'hypervisorlaunchtype\s+(\S+)') { return $matches[1] }
    return $null
}

function Get-VbsReg {
    # VBS 的注册表总开关。它是独立的、优先级更高的开关：
    # 只要它 = 1，Windows 会以「VBS 需要 VSM」为由强行加载 hypervisor，
    # 单改 hypervisorlaunchtype=off 是压不住的（2026-10-28 实测）。
    try {
        return (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' `
                -Name EnableVirtualizationBasedSecurity -ErrorAction Stop).EnableVirtualizationBasedSecurity
    } catch { return $null }
}

function Get-HvPresent {
    try { return (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent }
    catch { return $null }
}

function Get-Vbs {
    try {
        return Get-CimInstance -ClassName Win32_DeviceGuard `
            -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    } catch { return $null }
}

function Get-FreezeBaseline {
    $e = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41 } -ErrorAction SilentlyContinue |
           Sort-Object TimeCreated)
    if ($e.Count -eq 0) { return @{ Count = 0; First = $null; Last = $null } }
    return @{
        Count = $e.Count
        First = $e[0].TimeCreated
        Last  = $e[-1].TimeCreated
    }
}

function Show-Status {
    $lt = Get-LaunchType
    $hv = Get-HvPresent
    $vbs = Get-Vbs
    $vbsReg = Get-VbsReg
    $base = Get-FreezeBaseline

    Write-Host '===== hypervisor 启动配置 =====' -ForegroundColor Cyan
    if ($lt) {
        $note = switch ($lt) {
            'off'  { '已关闭（本脚本 apply 的目标状态）' }
            'auto' { '自动（Windows 默认，hypervisor 会启动）' }
            default { $lt }
        }
        Write-Host ('  hypervisorlaunchtype : ' + $lt + '   ' + $note)
    } else {
        if ($script:LaunchReadError) {
            Write-Host '  hypervisorlaunchtype : 读取失败 —— 需要管理员权限（别当成「未设置」）' -ForegroundColor Yellow
        } else {
            Write-Host '  hypervisorlaunchtype : 未显式设置 = 默认 auto（hypervisor 会启动）'
        }
    }

    if ($null -ne $vbsReg) {
        $vbsNote = if ($vbsReg -eq 0) { '   <- 已关（真正能压住 hypervisor 的开关）' } else { '   <- 仍开启：会强制 hypervisor 启动，bcdedit off 无效！' }
        Write-Host ('  VBS 注册表开关       : ' + $vbsReg + '   EnableVirtualizationBasedSecurity' + $vbsNote) -ForegroundColor $(if ($vbsReg -eq 0) { 'Green' } else { 'Red' })
    }

    Write-Host ' '
    Write-Host '===== 实际运行状态（重启后才会跟随 bcdedit 变化）=====' -ForegroundColor Cyan
    if ($null -ne $hv) {
        $color = if ($hv) { 'Yellow' } else { 'Green' }
        Write-Host ('  HypervisorPresent    : ' + $hv + $(if ($hv) { '   <- hypervisor 仍在运行' } else { '   <- 已摘掉' })) -ForegroundColor $color
    }
    if ($vbs) {
        Write-Host ('  VBS 状态             : ' + $vbs.VirtualizationBasedSecurityStatus + '   (0=关闭 1=已启用未运行 2=运行中)')
        Write-Host ('  已配置安全服务       : ' + ($vbs.SecurityServicesConfigured -join ','))
        Write-Host ('  正在运行安全服务     : ' + ($vbs.SecurityServicesRunning -join ',') + '   (2=内存完整性 3=凭据保护 4=SMM 固件测量)')
    }

    Write-Host ' '
    Write-Host '===== 冻结基线（判定依据）=====' -ForegroundColor Cyan
    Write-Host ('  Kernel-Power 41 总数 : ' + $base.Count)
    if ($base.Count -gt 0) {
        Write-Host ('  最早                 : ' + $base.First.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host ('  最近一次             : ' + $base.Last.ToString('yyyy-MM-dd HH:mm:ss') + '   <- 只看这个')
    }
    Write-Host ' '
    Write-Host '  判定口径：重启后观察 3-5 天，只看上面「最近一次」是否停住不动。'
    Write-Host '            不要看「近 30 天次数」，滚动窗口会自己变小。'

    Write-Host ' '
    Write-Host '===== 虚拟化依赖检查（关掉后会失效）=====' -ForegroundColor Cyan
    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host ('  wsl.exe              : 存在（' + $wsl.Source + '）—— 关掉 hypervisor 后 WSL2 无法启动')
    } else {
        Write-Host '  wsl.exe              : 未安装'
    }
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        Write-Host ('  docker               : 存在 —— 关掉 hypervisor 后无法启动')
    } else {
        Write-Host '  docker               : 未安装'
    }
    Write-Host '  Hyper-V / Sandbox    : 关掉 hypervisor 后均无法启动（需按功能名在「启用或关闭 Windows 功能」里确认）'
}

function Invoke-Apply {
    if (-not (Test-Admin)) {
        Write-Host '需要管理员权限。请以管理员身份重新打开 PowerShell 再运行。' -ForegroundColor Red
        return 1
    }

    $cur = Get-LaunchType
    $vbsReg = Get-VbsReg

    # 只关 hypervisorlaunchtype 是不够的：VBS 注册表总开关还开着的话，
    # Windows 会以「VBS 需要 VSM」为由强行加载 hypervisor（2026-10-28 实测踩到）。
    # 两个开关必须一起关，少一个就白重启一次。
    if ($cur -eq 'off' -and $vbsReg -eq 0) {
        Write-Host 'hypervisorlaunchtype = off 且 VBS 开关 = 0，两个开关都已关闭，无需重复设置。' -ForegroundColor Yellow
        Write-Host '如果机器仍然冻结，说明问题不在 hypervisor —— 直接进下一步（BIOS 关深度空闲态）。'
        return 0
    }

    Write-Host '即将关闭 Hyper-V hypervisor。重启后以下功能全部失效：' -ForegroundColor Yellow
    Write-Host '  · WSL2 / Docker Desktop / Hyper-V 虚拟机 / Windows Sandbox'
    Write-Host '  · Credential Guard / 内存完整性（HVCI）'
    Write-Host ' '

    if (-not $Force) {
        $ans = Read-Host '确认继续？输入 YES 执行，其它任意键取消'
        if ($ans -ne 'YES') {
            Write-Host '已取消，未做任何修改。' -ForegroundColor Yellow
            return 0
        }
    }

    $base = Get-FreezeBaseline
    $fail = $false

    Write-Host ' '
    Write-Host '=== 1/2 关闭 VBS 注册表开关 ==='
    $vbsKeys = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Enabled' },
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\LSA'; Name = 'LsaCfgFlags' }
    )
    foreach ($k in $vbsKeys) {
        try {
            if (-not (Test-Path $k.Path)) { New-Item -Path $k.Path -Force | Out-Null }
            Set-ItemProperty -Path $k.Path -Name $k.Name -Value 0 -Type DWord -ErrorAction Stop
            Write-Host ('  ' + $k.Path.Substring(6) + ' \ ' + $k.Name + ' = 0   ✅')
        } catch {
            Write-Host ('  ' + $k.Name + ' 写入失败：' + $_.Exception.Message) -ForegroundColor Red
            $fail = $true
        }
    }

    Write-Host ' '
    Write-Host '=== 2/2 关闭 hypervisorlaunchtype ==='
    $out = bcdedit /set hypervisorlaunchtype off 2>&1 | Out-String
    if ($out.Trim()) { Write-Host ('  ' + $out.Trim()) }

    Write-Host ' '
    Write-Host '回读确认（两个都必须绿）：'
    $after = Get-LaunchType
    $afterVbs = Get-VbsReg
    if ($after -eq 'off') {
        Write-Host '  hypervisorlaunchtype = off   ✅ 已写入' -ForegroundColor Green
    } else {
        Write-Host ('  hypervisorlaunchtype = ' + $after + '   ❌ 写入失败或被拒绝') -ForegroundColor Red
        $fail = $true
    }
    if ($afterVbs -eq 0) {
        Write-Host '  EnableVBS            = 0     ✅ 已写入' -ForegroundColor Green
    } else {
        Write-Host ('  EnableVBS            = ' + $afterVbs + '   ❌ 未生效，重启后 hypervisor 大概率还会起来') -ForegroundColor Red
        $fail = $true
    }

    Write-Host ' '
    Write-Host '=== 本次观察基线 ===' -ForegroundColor Cyan
    Write-Host ('  Kernel-Power 41 总数 : ' + $base.Count)
    if ($base.Count -gt 0) {
        Write-Host ('  最近一次             : ' + $base.Last.ToString('yyyy-MM-dd HH:mm:ss'))
    }

    Write-Host ' '
    Write-Host '现在请重启。重启后验证（两条都要满足）：' -ForegroundColor Green
    Write-Host '  1) powershell -ExecutionPolicy Bypass -File .\scripts\disable-hypervisor.ps1 status'
    Write-Host '     应看到 HypervisorPresent : False 且 VBS 状态 : 0'
    Write-Host '  2) 查 hypervisor 有没有偷偷起来（这才是硬证据）：'
    Write-Host '     Get-WinEvent -LogName System -MaxEvents 300 |'
    Write-Host "       Where-Object { `$_.ProviderName -eq 'Microsoft-Windows-Hyper-V-Hypervisor' -and `$_.Id -eq 1 }"
    Write-Host '     本次开机之后不该再出现「虚拟机监控程序已成功启动」'
    Write-Host ' '
    Write-Host '  若 HypervisorPresent 仍是 True / 事件 1 仍在：'
    Write-Host '    · 看 status 里 VBS 注册表开关是否被 Windows 又改回 1（Secured-core 机型可能强制）'
    Write-Host '    · 再去 BIOS 找 Virtualization Based Security / Device Guard 相关项关掉'
    Write-Host ' '
    Write-Host '然后正常使用 3-5 天：'
    Write-Host '  「最近一次异常断电」时间戳停住  -> 就是 hypervisor 的空闲请求路径，保持现状'
    Write-Host '  时间戳继续前进                -> hypervisor 也排除了，进下一步：BIOS 关 Extended Idle Power States'
    Write-Host ' '
    Write-Host '要恢复的话执行：'
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\scripts\disable-hypervisor.ps1 revert'
    if ($fail) { return 1 }
    return 0
}

function Invoke-Revert {
    if (-not (Test-Admin)) {
        Write-Host '需要管理员权限。请以管理员身份重新打开 PowerShell 再运行。' -ForegroundColor Red
        return 1
    }

    Write-Host '=== 1/2 恢复 VBS 注册表开关（EnableVirtualizationBasedSecurity = 1）==='
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' `
            -Name EnableVirtualizationBasedSecurity -Value 1 -Type DWord -ErrorAction Stop
        Write-Host '  EnableVirtualizationBasedSecurity = 1   ✅'
    } catch {
        Write-Host ('  写入失败：' + $_.Exception.Message) -ForegroundColor Red
    }
    # 内存完整性（HVCI）保持第 8 轮的关闭状态，不在这里顺手打开
    # —— 打开会同时改动观察基线，回退时只回退本轮改过的东西。

    Write-Host ' '
    Write-Host '=== 2/2 恢复 bcdedit /set hypervisorlaunchtype auto ==='
    $out = bcdedit /set hypervisorlaunchtype auto 2>&1 | Out-String
    Write-Host $out.Trim()

    $after = Get-LaunchType
    Write-Host ' '
    Write-Host '回读确认：'
    if ($after -eq 'auto') {
        Write-Host '  hypervisorlaunchtype = auto  ✅ 已恢复' -ForegroundColor Green
        Write-Host ' '
        Write-Host '重启后 WSL2 / Docker / Hyper-V / Credential Guard / 内存完整性恢复可用。'
        Write-Host '注意 1：内存完整性（HVCI）的开关保持本轮之前的关闭状态，需另行打开（windowsdefender://coreisolation）。'
        Write-Host '注意 2：Credential Guard 的 LsaCfgFlags 也被 apply 置 0 了，要恢复请把它设回 1（或 2 带 UEFI 锁）。'
    } else {
        Write-Host ('  hypervisorlaunchtype = ' + $after + '  ❌ 未能确认') -ForegroundColor Red
        return 1
    }
    return 0
}

$code = 0
switch ($Mode) {
    'status' { Show-Status }
    'apply'  { $code = Invoke-Apply }
    'revert' { $code = Invoke-Revert }
}

if ($Mode -ne 'status') { exit $code }
