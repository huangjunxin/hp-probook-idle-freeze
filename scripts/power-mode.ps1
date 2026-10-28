param(
    [ValidateSet('hibernate', 'remote', 'save', 'status', 'check')]
    [string]$Mode = 'status'
)

$ErrorActionPreference = 'Stop'

$SUB_VIDEO     = 'SUB_VIDEO'
$VIDEOIDLE     = 'VIDEOIDLE'
$SUB_SLEEP     = 'SUB_SLEEP'
$SUB_BUTTONS   = 'SUB_BUTTONS'
$STANDBYIDLE   = '29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA'
$HIBERNATEIDLE = '9D7815A6-7EE4-497E-8888-515A05F02364'
$LIDACTION     = '5CA83367-6E45-459F-A27B-476B1D01C936'
$PBUTTONACTION = '7648EFA3-DD9C-4E3E-B566-50F929386280'

function Set-Power {
    param([string]$Sub, [string]$Setting, [string]$AC, [string]$DC)
    powercfg /setacvalueindex SCHEME_CURRENT $Sub $Setting $AC | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $Sub $Setting $DC | Out-Null
}

function Get-Val {
    param([string]$Sub, [string]$Setting)
    $o = powercfg /query SCHEME_CURRENT $Sub $Setting 2>$null
    if (-not $o) { return '-' }
    $ac = ($o | Select-String 'Current AC Power Setting|当前交流电源设置' | ForEach-Object { ($_ -split ':')[-1].Trim() })
    $dc = ($o | Select-String 'Current DC Power Setting|当前直流电源设置' | ForEach-Object { ($_ -split ':')[-1].Trim() })
    return "AC=$ac  DC=$dc"
}

function Get-ActionName([string]$hex) {
    if (-not $hex) { return '-' }
    switch ($hex.Trim().ToLower()) {
        '0x00000000' { '不操作' }
        '0x00000001' { '睡眠 (S0)' }
        '0x00000002' { '休眠 (S4)' }
        '0x00000003' { '关机' }
        default { $hex }
    }
}

function Get-RegAction([string]$settingGuid, [string]$acOrDc) {
    $scheme = ((powercfg /getactivescheme) -join ' ')
    if ($scheme -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $scheme = $Matches[1] }
    $p = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\4f971e89-eebd-4455-a8de-9e59040e7347\$settingGuid"
    if (-not (Test-Path $p)) { return '未定义(等同不操作)' }
    $v = Get-ItemProperty $p
    $raw = if ($acOrDc -eq 'AC') { $v.ACSettingIndex } else { $v.DCSettingIndex }
    if ($null -eq $raw) { return '未定义(等同不操作)' }
    return (Get-ActionName ('0x{0:x8}' -f $raw))
}

function Show-Status {
    Write-Host "===== 当前电源配置 ====="
    Write-Host ("  合盖动作    : AC=" + (Get-RegAction '5ca83367-6e45-459f-a27b-476b1d01c936' 'AC') + "  DC=" + (Get-RegAction '5ca83367-6e45-459f-a27b-476b1d01c936' 'DC'))
    Write-Host ("  电源键动作  : AC=" + (Get-RegAction '7648efa3-dd9c-4e3e-b566-50f929386280' 'AC') + "  DC=" + (Get-RegAction '7648efa3-dd9c-4e3e-b566-50f929386280' 'DC'))
    Write-Host ("  关屏超时    : " + (Get-Val $SUB_VIDEO $VIDEOIDLE))
    Write-Host ("  睡眠超时    : " + (Get-Val $SUB_SLEEP $STANDBYIDLE))
    Write-Host ("  休眠超时    : " + (Get-Val $SUB_SLEEP $HIBERNATEIDLE))
    $bright = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue).CurrentBrightness
    if ($null -ne $bright) { Write-Host ("  当前亮度    : $bright%") }
    Write-Host "  超时为十六进制秒: 0x12c=5分  0x1c2=7分  0x384=15分  0x0=从不"
}

function Show-Check {
    Write-Host "===== 健康检查（判断这套设置有没有起作用）====="
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ("  本次开机时间 : " + $os.LastBootUpTime)
    Write-Host ("  已连续运行   : " + ([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)) + " 小时")

    $since = (Get-Date).AddDays(-7)
    $kp41 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=$since} -ErrorAction SilentlyContinue)
    $kp6008 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=6008; StartTime=$since} -ErrorAction SilentlyContinue)
    $whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since} -ErrorAction SilentlyContinue)
    $hib = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=42; StartTime=$since} -ErrorAction SilentlyContinue)

    Write-Host " "
    Write-Host "  近 7 天统计:"
    Write-Host ("    Kernel-Power 41 (异常断电) : " + $kp41.Count)
    Write-Host ("    意外关机 6008              : " + $kp6008.Count)
    Write-Host ("    WHEA 硬件/固件错误         : " + $whea.Count)
    Write-Host ("    进入睡眠 42               : " + $hib.Count)

    Write-Host " "
    Write-Host "  虚拟化安全 (VBS):"
    $vbs = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    if ($vbs) {
        $vbsText = switch ($vbs.VirtualizationBasedSecurityStatus) { 0 { '未启用' } 1 { '已启用但未运行' } 2 { '运行中' } default { '未知' } }
        Write-Host ("    状态              : $vbsText")
        Write-Host ("    运行中的服务      : " + ($vbs.SecurityServicesRunning -join ', ') + "  (1=凭据保护 2=内存完整性 3=安全启动 4=SMM固件度量)")
    } else { Write-Host "    状态              : 查询失败" }

    Write-Host " "
    Write-Host "  驱动版本对照 (HP 官方当前版本):"
    $gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1).DriverVersion
    $mei = (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'Management Engine Interface' } | Select-Object -First 1).DriverVersion
    $wlan = (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'Wi-Fi' } | Select-Object -First 1).DriverVersion
    Write-Host ("    Intel 显卡    : 本机 $gpu   官方 32.0.101.8801")
    Write-Host ("    Intel ME 接口 : 本机 $mei   官方 2613.9.28.0")
    Write-Host ("    Intel WLAN    : 本机 $wlan   官方 24.60.0.3")

    $verdict = if ($kp41.Count -eq 0 -and $whea.Count -eq 0) { '通过：这一周没有异常断电，也没有新的固件错误' }
               elseif ($whea.Count -gt 0) { '未通过：仍有固件级错误，说明问题不在软件层，应报修' }
               else { '部分通过：仍有异常断电，但无固件错误，继续观察' }
    Write-Host " "
    Write-Host "  结论: $verdict" -ForegroundColor $(if ($kp41.Count -eq 0 -and $whea.Count -eq 0) { 'Green' } else { 'Yellow' })

    if ($whea.Count -gt 0) {
        Write-Host " "
        Write-Host "  最近 3 条 WHEA:"
        $whea | Sort-Object TimeCreated | Select-Object -Last 3 | ForEach-Object {
            Write-Host ("    " + $_.TimeCreated + "  ID=" + $_.Id)
        }
    }
    if ($kp41.Count -gt 0) {
        Write-Host " "
        Write-Host "  最近 3 次异常断电:"
        $kp41 | Sort-Object TimeCreated | Select-Object -Last 3 | ForEach-Object {
            Write-Host ("    " + $_.TimeCreated)
        }
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

switch ($Mode) {
    'status' { Show-Status; exit 0 }
    'check'  { Show-Check;  exit 0 }
}

if (-not $isAdmin) {
    Write-Host "需要管理员权限：右键开始菜单 -> 终端(管理员)，再运行本脚本。" -ForegroundColor Yellow
    exit 1
}

$backup = Join-Path $env:USERPROFILE 'Desktop\power-backup.pow'
if (-not (Test-Path $backup)) {
    powercfg /export $backup SCHEME_CURRENT 2>$null | Out-Null
    if (Test-Path $backup) { Write-Host "已备份原电源方案到: $backup"; Write-Host " " }
}

switch ($Mode) {

    'hibernate' {
        # 推荐模式：完全不进 S0，直接走 S4
        Set-Power $SUB_BUTTONS $LIDACTION     2  2
        Set-Power $SUB_BUTTONS $PBUTTONACTION 2  2
        Set-Power $SUB_VIDEO   $VIDEOIDLE     300  180
        Set-Power $SUB_SLEEP   $STANDBYIDLE   300  180
        Set-Power $SUB_SLEEP   $HIBERNATEIDLE 420  300
        Write-Host "已切换到 [休眠优先模式]" -ForegroundColor Green
        Write-Host "  合盖        : 直接休眠 (S4)，完全不经过 S0，不触发固件缺陷"
        Write-Host "  电源键      : 直接休眠"
        Write-Host "  接电源      : 5 分钟关屏 -> 7 分钟自动休眠"
        Write-Host "  用电池      : 3 分钟关屏 -> 5 分钟自动休眠"
        Write-Host "  效果        : 屏幕照常关，休眠后整机 0 瓦，不亮屏也不耗电"
        Write-Host "  代价        : 休眠时远程连不上，需在 BIOS 开启 LAN/WLAN 唤醒后配合 WOL"
    }

    'remote' {
        Set-Power $SUB_BUTTONS $LIDACTION     1  2
        Set-Power $SUB_VIDEO   $VIDEOIDLE     0    300
        Set-Power $SUB_SLEEP   $STANDBYIDLE   0    0
        Set-Power $SUB_SLEEP   $HIBERNATEIDLE 0    900
        Write-Host "已切换到 [远程优先模式]（应急用，不建议长期）" -ForegroundColor Yellow
        Write-Host "  接电源: 永不息屏、永不休眠，不进 S0，远程随时可连"
        Write-Host "  用电池: 5 分钟关屏、15 分钟休眠"
        Write-Host "  问题  : 屏幕常亮，属于绕行方案，不是解法"
    }

    'save' {
        Set-Power $SUB_BUTTONS $LIDACTION     2  2
        Set-Power $SUB_VIDEO   $VIDEOIDLE     120  120
        Set-Power $SUB_SLEEP   $STANDBYIDLE   120  120
        Set-Power $SUB_SLEEP   $HIBERNATEIDLE 180  180
        Write-Host "已切换到 [快速休眠模式]" -ForegroundColor Green
        Write-Host "  关屏 2 分钟 -> 3 分钟自动休眠，S0 暴露窗口压到最短"
        Write-Host "  适合：一整天不用、临走前不想手动合盖的场景"
    }
}

powercfg /setactive SCHEME_CURRENT
Write-Host ""
Show-Status
