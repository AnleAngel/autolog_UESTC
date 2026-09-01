[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CampusAutoLogin'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Remove) {
    foreach ($name in @($TaskName, 'CampusResetDNS')) {
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "[OK] 任务 $name 已删除"
        } else {
            Write-Host "任务 $name 不存在"
        }
    }
    return
}

function Find-Python {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "未找到 Python，请先安装并加入 PATH"
}

function Find-PythonW {
    param([string]$PyPath)
    $dir = Split-Path -Parent $PyPath
    $pyw = Join-Path $dir 'pythonw.exe'
    if (Test-Path -LiteralPath $pyw) { return $pyw }
    return $PyPath
}

$pyExe = Find-Python
$pywExe = Find-PythonW $pyExe
$watchPy = Join-Path $ProjectDir 'watch.py'
if (-not (Test-Path -LiteralPath $watchPy)) { throw "找不到 $watchPy" }

Write-Host "Python:  $pywExe"
Write-Host "脚本:    $watchPy"

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction -Execute $pywExe -Argument ('"' + $watchPy + '"') -WorkingDirectory $ProjectDir

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$logonTrigger.Delay = 'PT30S'

$eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$eventTrigger = New-CimInstance -CimClass $eventClass -ClientOnly -Property @{
    Enabled      = $true
    Delay        = 'PT10S'
    Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select>*[System[(EventID=10000)]]</Select></Query></QueryList>'
}

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.ExecutionTimeLimit = 'PT0S'
$settings.StartWhenAvailable = $true
$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries = $false

$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($logonTrigger, $eventTrigger) `
        -Settings $settings -Principal $principal `
        -Description '校园网自动登录看护（锐捷 SAM+ Portal / CAS-SSO）' -Force | Out-Null
    Write-Host "[OK] 计划任务 $TaskName 注册成功" -ForegroundColor Green
    Write-Host "  - 触发：用户登录 30 秒后 / 网络连接事件(10000)后 10 秒"
} catch {
    Write-Warning "注册失败：$($_.Exception.Message)"
    Write-Warning "请尝试用管理员身份运行 PowerShell 后重试。"
}

$resetScript = Join-Path $ProjectDir 'reset_dns.ps1'
if (Test-Path -LiteralPath $resetScript) {
    $resetAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $resetScript + '"') `
        -WorkingDirectory $ProjectDir
    $resetTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $resetTrigger.Delay = 'PT5S'
    $resetPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName 'CampusResetDNS' -Action $resetAction `
            -Trigger $resetTrigger -Settings $settings -Principal $resetPrincipal `
            -Description '开机登录时将所有在线网卡 DNS 重置为自动(DHCP)并刷新缓存' -Force | Out-Null
        Write-Host "[OK] 计划任务 CampusResetDNS 注册成功（登录后 5 秒执行，先于登录看护）" -ForegroundColor Green
    } catch {
        Write-Warning "CampusResetDNS 注册失败：$($_.Exception.Message)"
    }
} else {
    Write-Warning "未找到 reset_dns.ps1，已跳过 DNS 重置任务注册"
}

Write-Host "  - 查看: Get-ScheduledTask CampusAutoLogin, CampusResetDNS"
Write-Host "  - 删除: powershell -File install_task.ps1 -Remove"

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[OK] 已请求立即启动任务"
}
