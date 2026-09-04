# AnLe

## 项目介绍

本项目是针对校园网（锐捷 SAM+ Portal / CAS-SSO，Portal 服务器 `110.184.24.61`）的 Windows 全自动登录看护脚本。它模拟浏览器完整认证链路：离线探测 → 捕获网关强制门户重定向 → 解析 CAS 登录页动态令牌（`croypto` 密钥与 `execution` WebFlow 令牌）→ AES-128-ECB 加密密码提交表单 → 确认在线。支持开机自启与网络重连事件触发（计划任务），用于实现"断网自动重连、开机即可上网"的零手工体验。

核心逆向结论（已验证）：密码字段为 `AES-128-ECB/PKCS7`，密钥来自登录页 `login-croypto` 元素（每次页面加载随机生成）；`captcha_payload` 为同密钥加密的 `{}`；登录 POST 无需 Cookie；在线状态以 `POST /eportal/network/userOnline` 返回 `online:true` 为准。

## 项目文件树状图

```text
G:\autologin_UESTC\
├─ login.py               # 登录核心：离线探测/重定向捕获/CAS 流程/AES 加密/在线确认
├─ watch.py               # 常驻看护主程序：循环探测、失败退避、状态持久化、CLI 模式
├─ install_task.ps1       # Windows 计划任务安装脚本（DNS 重置 + 开机自启 + 网络事件触发）
├─ reset_dns.ps1          # 开机 DNS 重置：全部在线网卡恢复 DHCP 自动 DNS 并刷新缓存
├─ config.example.ini     # 配置模板（复制为 config.ini 后填写账号密码）
├─ config.ini             # 实际配置（含密码，已被 .gitignore 排除）
├─ state.json             # 运行状态（最近登录时间/sessionId，供断网演练用）
├─ .gitignore
└─ logs\                  # 运行日志（watch_YYYYMMDD.log、reset_dns.log，UTF-8）
```

## 使用方法

依赖：Python 3.11+、`requests`、`cryptography`（已随环境可用）。

```bash
# 1. 初始化配置：复制模板并填写 [account] 段的 username / password
copy config.example.ini config.ini

# 2. 仅检测当前在线状态（无需账号）
python watch.py check

# 3. 手动执行一次登录流程（检测到离线才真正登录）
python watch.py once

# 4. 常驻看护（默认模式，每 300 秒探测，离线自动登录，失败指数退避）
python watch.py

# 5. 断网重连演练：注销当前会话并在 5 秒后自动重新登录（需交互输入 YES 确认）
python watch.py test

# 6. 注册计划任务（DNS/DHCP 重置任务需管理员，会弹 UAC 确认一次）
powershell -ExecutionPolicy Bypass -File install_task.ps1
#    CampusResetDNS：登录后 5 秒，管理员权限将所有在线网卡 DNS 重置为 DHCP 自动、
#    强制 release+renew 重新获取 DHCP 地址（清除 Clash 残留 DNS 劫持与失效旧租约，
#    避免开机后等待服务器慢速 DHCPNACK 导致的约 12 分钟断网），需早于登录看护执行
#    CampusAutoLogin：登录后 30 秒 / 网络连接事件后 10 秒，静默运行看护循环
#    立即启动一次：  powershell -File install_task.ps1 -StartNow
#    卸载全部任务：  powershell -File install_task.ps1 -Remove
```

日志位于 `logs\watch_YYYYMMDD.log` 与 `logs\reset_dns.log`；离线事件的网关重定向链会完整记录，便于后续排查认证流程变化。

## 修改与问题解决日志

### 2026-09-04 22:20
- **修改/问题**：开机后校园网 BRAS 侧残留的陈旧在线会话（按 MAC/IP 绑定）导致约 10 分钟流量黑洞，DHCP 层面的 release+renew 无法清除服务端会话状态
- **涉及文件**：`watch.py`、`reset_dns.ps1`、`README.md`
- **解决方案**：双层自愈机制——① 看护循环检测到 `down` 时用 `state.json` 保存的旧 sessionId 主动调用注销 API 清理陈旧会话（每个 sessionId 仅尝试一次）；② 连续 3 次 `down` 后通过 `schtasks /Run` 触发提权任务 `CampusResetDNS` 执行网卡弹跳自修复（release → disable → enable → renew，复刻实测中"链路弹跳+新 IP 即恢复"的路径），该任务同时服务开机初始化与按需修复，无需新增 UAC 授权；实测弹跳后秒级拿到新 IP、看护循环恢复正常
- **影响范围**：开机黑洞期从约 10-12 分钟压缩至最迟 3 个探测周期（约 6-7 分钟）内触发修复，修复后 1-2 分钟内恢复在线；`reset_dns.log` 新增弹跳与 IP 记录

### 2026-09-01 16:55
- **修改/问题**：开机后网卡沿用上午的失效旧租约（`100.67.36.170`），DHCP 服务器迟迟不回 DHCPNACK（事件日志 1002 证实），导致开机后约 12 分钟内一切流量（含 ping Portal 纯 IP）超时
- **涉及文件**：`reset_dns.ps1`、`install_task.ps1`、`README.md`
- **解决方案**：`reset_dns.ps1` 在 DNS 重置基础上增加 DHCP 强制重新获取（对 DHCP 启用的在线网卡执行 `ipconfig /release` + `/renew`），新增网卡就绪等待（最多 30 秒）与获取后 IP 日志；实测 release+renew 秒级拿到新 IP（`100.67.169.167`），IP 变化导致会话失效后看护脚本在下一轮询内自动重登（16:51:17 登录成功）；`install_task.ps1` 中任务描述同步更新
- **影响范围**：开机网络初始化时序升级为"DNS 重置 → DHCP 强制重新获取 → 校园网自动登录"，开机到可用时间从约 13 分钟压缩至 1 分钟内；代价为每次登录 Windows 时网络闪断数秒

### 2026-09-01 12:52
- **修改/问题**：从手机热点切回校园网后，未认证状态下校园 DNS 不解析外部域名，脚本的域名探测被误判为 `down` 而跳过登录，导致"只有手动在浏览器打开登录页后脚本才生效"
- **涉及文件**：`login.py`、`watch.py`、`config.example.ini`、`config.ini`、`README.md`
- **解决方案**：探测与登录入口全面改为 DNS 无关：① 新增纯 IP 三态探测（119.29.29.29/223.5.5.5/1.1.1.1，外网响应=在线、302 劫持到 Portal=待认证、外网不通但 Portal 可达=待认证、Portal 亦不可达=down）；② 实测发现 `eportal/index.jsp` 接受手工构造参数（本机 IP/NAS IP/MAC）并直接签发真实 `sessionId`，作为域名链路失效时的本地直连入口兜底；③ 轮询间隔默认 300→120 秒；重启看护任务加载新代码
- **影响范围**：网络切换后无需任何手动操作，最迟约 2 分钟自动完成认证；端到端验证：纯 IP 探测、本地入口签发 sessionId、CAS 令牌获取全部通过

### 2026-09-01 12:30
- **修改/问题**：用户经常使用 Clash 更改 DNS，开机时若残留 DNS 劫持会导致"链路级断网"（DNS 解析失败），需要在开机联网前先恢复默认 DNS
- **涉及文件**：`reset_dns.ps1`（新增）、`install_task.ps1`、`README.md`
- **解决方案**：新增 `reset_dns.ps1`：将所有在线网卡 DNS 重置为 DHCP 自动（`Set-DnsClientServerAddress -ResetServerAddresses`）并刷新 DNS 缓存，写日志到 `logs/reset_dns.log`，非管理员运行时自动跳过；`install_task.ps1` 新增 `CampusResetDNS` 计划任务（登录后 5 秒、`RunLevel Highest`，早于登录看护的 30 秒），`-Remove` 同时清理两个任务；高权限任务需 UAC 提权注册一次，已实际完成并手动触发验证（LastTaskResult=0，以太网/WLAN 均恢复 DHCP DNS）
- **影响范围**：开机网络初始化流程（DNS 重置 → 校园网自动登录）；不影响 Clash 运行期正常使用（其启动后可照常接管 DNS）

### 2026-09-01 12:35
- **修改/问题**：真实运行中出现"链路级断网"（DNS 解析失败 + Portal 纯 IP 连接超时），脚本未捕获 `ConnectTimeout` 异常导致 traceback 崩溃，且在链路不通时仍盲目执行 16 秒超时的登录流程
- **涉及文件**：`login.py`、`watch.py`、`README.md`
- **解决方案**：新增三态网络探测 `probe_network`（`online`/`captive`/`down`）：DNS 失败或连接失败判定为 `down`，204 为在线，302 为待认证；`do_login` 全程异常兜底（`RequestException`/`LoginError` 转友好消息）；看护循环遇 `down` 状态不尝试登录、不计入失败退避，仅等待下轮探测；`check` 命令输出三态标签
- **影响范围**：网络状态分类与登录入口；验证：真实探测 `online`、模拟 DNS 故障 `down`、`do_login` 在 `down` 下返回友好错误而非崩溃

### 2026-08-31 13:45
- **修改/问题**：`install_task.ps1` 用 schtasks + XML 注册计划任务报"指定的队列无效"（schtasks 对事件触发器 Subscription 元素的已知缺陷）
- **涉及文件**：`install_task.ps1`、`AnLe.md`
- **解决方案**：改用 `Register-ScheduledTask` cmdlet，事件触发器通过 `MSFT_TaskEventTrigger` CIM 实例（`New-CimInstance -ClientOnly`）注入原始 XPath 订阅（`Microsoft-Windows-NetworkProfile/Operational` EventID=10000）；本会话已实际注册成功，验证 `Get-ScheduledTask` 显示 LogonTrigger + EventTrigger 均 Enabled，任务状态 Ready，全程无需管理员权限
- **影响范围**：部署方式变更（schtasks XML → Register-ScheduledTask）；`-Remove` 改用 `Unregister-ScheduledTask`；自动化部署链路闭环

### 2026-08-31 13:39
- **修改/问题**：真实离线场景首跑失败（CAS 登录返回 HTTP 500），且 `confirm_online()` 调用传入不存在的 `timeout` 参数导致 TypeError
- **涉及文件**：`login.py`
- **解决方案**：分析真实离线日志发现 `eportal/index.jsp` 的 302 Location 中已携带后端生成的真实 `sessionId`，原先仅从 `resolveRedirectInfo` 响应取 `flowSessionId` 且该接口在校内返回 `valid:false`，导致用了自造 ID 被 CAS 拒绝；修改为优先使用重定向链中的 `sessionId`（兼容小写 `userip/nasip` 变体），resolve 降级为诊断用途；修复 `confirm_online` 调用签名
- **影响范围**：`do_login` 主流程；修复后经真实离线事件端到端验证：CAS 签发 ticket、回调后网络认证成功，`watch.py once` 确认"当前已在线"

### 2026-08-31 13:25
- **修改/问题**：初始化项目：完成校园网自动登录脚本全部核心功能与文档
- **涉及文件**：`login.py`、`watch.py`、`install_task.ps1`、`config.example.ini`、`.gitignore`、`AnLe.md`
- **解决方案**：基于对 Portal 前端 JS 与 HAR 抓包的逆向，实现 CAS-SSO 表单登录全流程（含每页随机的 AES 密钥提取与加密）；修复两个问题——`do_login` 返回值数量不一致、PowerShell 5.1 要求 UTF-8 BOM 编码；发现并绕过网关对 `Accept-Encoding: gzip` 请求返回 502 的缺陷（强制 `identity`）
- **影响范围**：登录流程核心（login.py）、看护循环与 CLI（watch.py）、部署脚本（install_task.ps1）；干跑测试通过：AES 加密与抓包样本逐字节匹配、登录页令牌解析成功、验证码检查接口连通、在线检测正常
