$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ProjectDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir 'reset_dns.log'
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Out-File -Append -LiteralPath $LogFile -Encoding utf8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log '[WARN] 未以管理员身份运行，DNS/DHCP 重置已跳过'
    exit 1
}

$deadline = (Get-Date).AddSeconds(30)
$upAdapters = @()
while ((Get-Date) -lt $deadline) {
    $upAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    if ($upAdapters.Count -gt 0) { break }
    Start-Sleep -Seconds 2
}
if ($upAdapters.Count -eq 0) {
    Write-Log '[WARN] 等待 30 秒仍无在线网卡，跳过本次重置'
    exit 1
}

$dnsReset = @()
foreach ($a in $upAdapters) {
    try {
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
        $dnsReset += $a.Name
    } catch {
        Write-Log ("[ERROR] DNS 重置失败 {0}: {1}" -f $a.Name, $_.Exception.Message)
    }
}

$renewed = @()
foreach ($a in $upAdapters) {
    $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipif -and $ipif.Dhcp -eq 'Enabled') {
        try {
            $null = ipconfig /release "$($a.Name)" 2>$null
            $null = ipconfig /renew "$($a.Name)" 2>$null
            $renewed += $a.Name
        } catch {
            Write-Log ("[ERROR] DHCP 重新获取失败 {0}: {1}" -f $a.Name, $_.Exception.Message)
        }
    }
}

Clear-DnsClientCache -ErrorAction SilentlyContinue

if ($dnsReset.Count -gt 0) {
    Write-Log ("[OK] DNS 已重置为自动(DHCP): {0}" -f ($dnsReset -join ', '))
} else {
    Write-Log '[OK] DNS 无需修改（所有在线网卡均为自动 DNS）'
}
if ($renewed.Count -gt 0) {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Dhcp' } |
        ForEach-Object { "{0}={1}" -f $_.InterfaceAlias, $_.IPAddress }
    Write-Log ("[OK] DHCP 已强制重新获取: {0}; 当前 IP: {1}; DNS 缓存已刷新" -f ($renewed -join ', '), ($ips -join ', '))
} else {
    Write-Log '[OK] 无 DHCP 网卡需要重新获取; DNS 缓存已刷新'
}
