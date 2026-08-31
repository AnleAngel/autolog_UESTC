[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CampusAutoLogin'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 任务 $TaskName 已删除"
    } else {
        Write-Host "任务 $TaskName 不存在"
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
        -Description '校园网自动登录看护（锐杰 SAM+ Portal / CAS-SSO）' -Force | Out-Null
    Write-Host "[OK] 计划任务 $TaskName 注册成功" -ForegroundColor Green
    Write-Host "  - 触发：用户登录 30 秒后 / 网络连接事件(10000)后 10 秒"
    Write-Host "  - 查看: Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
    Write-Host "  - 删除: powershell -File install_task.ps1 -Remove"
} catch {
    Write-Warning "注册失败：$($_.Exception.Message)"
    Write-Warning "请尝试用管理员身份运行 PowerShell 后重试。"
}

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[OK] 已请求立即启动任务"
}
