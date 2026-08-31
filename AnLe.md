# AnLe

## 项目介绍

本项目是针对校园网（锐捷 SAM+ Portal / CAS-SSO，Portal 服务器 `110.184.24.61`）的 Windows 全自动登录看护脚本。它模拟浏览器完整认证链路：离线探测 → 捕获网关强制门户重定向 → 解析 CAS 登录页动态令牌（`croypto` 密钥与 `execution` WebFlow 令牌）→ AES-128-ECB 加密密码提交表单 → 确认在线。支持开机自启与网络重连事件触发（计划任务），用于实现"断网自动重连、开机即可上网"的零手工体验。

核心逆向结论（已验证）：密码字段为 `AES-128-ECB/PKCS7`，密钥来自登录页 `login-croypto` 元素（每次页面加载随机生成）；`captcha_payload` 为同密钥加密的 `{}`；登录 POST 无需 Cookie；在线状态以 `POST /eportal/network/userOnline` 返回 `online:true` 为准。

## 项目文件树状图

```text
G:\autologin_UESTC\
├─ login.py               # 登录核心：离线探测/重定向捕获/CAS 流程/AES 加密/在线确认
├─ watch.py               # 常驻看护主程序：循环探测、失败退避、状态持久化、CLI 模式
├─ install_task.ps1       # Windows 计划任务安装脚本（开机自启 + 网络事件触发）
├─ config.example.ini     # 配置模板（复制为 config.ini 后填写账号密码）
├─ config.ini             # 实际配置（含密码，已被 .gitignore 排除）
├─ state.json             # 运行状态（最近登录时间/sessionId，供断网演练用）
├─ .gitignore
└─ logs\                  # 运行日志（按天分文件，UTF-8）
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

# 6. 注册开机自启 + 网络重连事件触发的计划任务（建议管理员 PowerShell 运行）
powershell -ExecutionPolicy Bypass -File install_task.ps1
#    立即启动一次：  powershell -File install_task.ps1 -StartNow
#    卸载任务：      powershell -File install_task.ps1 -Remove
```

日志位于 `logs\watch_YYYYMMDD.log`；离线事件的网关重定向链会完整记录，便于后续排查认证流程变化。

## 修改与问题解决日志

### 2026-08-31 13:25
- **修改/问题**：初始化项目：完成校园网自动登录脚本全部核心功能与文档
- **涉及文件**：`login.py`、`watch.py`、`install_task.ps1`、`config.example.ini`、`.gitignore`、`AnLe.md`
- **解决方案**：基于对 Portal 前端 JS 与 HAR 抓包的逆向，实现 CAS-SSO 表单登录全流程（含每页随机的 AES 密钥提取与加密）；修复两个问题——`do_login` 返回值数量不一致、PowerShell 5.1 要求 UTF-8 BOM 编码；发现并绕过网关对 `Accept-Encoding: gzip` 请求返回 502 的缺陷（强制 `identity`）
- **影响范围**：登录流程核心（login.py）、看护循环与 CLI（watch.py）、部署脚本（install_task.ps1）；干跑测试通过：AES 加密与抓包样本逐字节匹配、登录页令牌解析成功、验证码检查接口连通、在线检测正常
