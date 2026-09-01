$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ProjectDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir 'reset_dns.log'
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Write-Log {
    param([string]$Message)
    "$ts $Message" | Out-File -Append -LiteralPath $LogFile -Encoding utf8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log '[WARN] 未以管理员身份运行，DNS 重置已跳过'
    exit 1
}

$changed = @()
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    try {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -ErrorAction Stop
        $changed += $_.Name
    } catch {
        Write-Log ("[ERROR] {0}: {1}" -f $_.Name, $_.Exception.Message)
    }
}
Clear-DnsClientCache -ErrorAction SilentlyContinue

if ($changed.Count -gt 0) {
    Write-Log ("[OK] DNS 已重置为自动(DHCP): {0}; DNS 缓存已刷新" -f ($changed -join ', '))
} else {
    Write-Log '[OK] 无需修改（所有在线网卡均为自动 DNS）; DNS 缓存已刷新'
}
