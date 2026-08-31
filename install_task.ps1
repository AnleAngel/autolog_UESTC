[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CampusAutoLogin'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Remove) {
    schtasks /Delete /TN $TaskName /F
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK] 任务 $TaskName 已删除" }
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

function Escape-Xml {
    param([string]$Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

$pyExe = Find-Python
$pywExe = Find-PythonW $pyExe
$watchPy = Join-Path $ProjectDir 'watch.py'
if (-not (Test-Path -LiteralPath $watchPy)) { throw "找不到 $watchPy" }

Write-Host "Python:  $pywExe"
Write-Host "脚本:    $watchPy"

$cmdEsc = Escape-Xml $pywExe
$argEsc = Escape-Xml ('"' + $watchPy + '"')
$wdEsc = Escape-Xml $ProjectDir
$subs = '&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select EventId="10000" /&gt;&lt;/Query&gt;&lt;/QueryList&gt;'

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>校园网自动登录看护（锐捷 SAM+ Portal / CAS-SSO）</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$subs</Subscription>
      <Delay>PT10S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"$cmdEsc"</Command>
      <Arguments>"$argEsc"</Arguments>
      <WorkingDirectory>"$wdEsc"</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlFile = Join-Path $env:TEMP "$TaskName.xml"
$xml | Out-File -LiteralPath $xmlFile -Encoding Unicode

schtasks /Create /F /TN $TaskName /XML $xmlFile
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] 计划任务 $TaskName 注册成功" -ForegroundColor Green
    Write-Host "  - 触发：用户登录 30 秒后 / 网络连接事件后 10 秒"
    Write-Host "  - 查看: schtasks /Query /TN $TaskName /V"
    Write-Host "  - 删除: powershell -File install_task.ps1 -Remove"
} else {
    Write-Warning "注册失败（退出码 $LASTEXITCODE）。请用管理员身份运行 PowerShell 后重试。"
}

if ($StartNow) {
    schtasks /Run /TN $TaskName
}
