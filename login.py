"""UESTC campus network auto login via Ruijie SAM+ Portal / CAS-SSO."""
from __future__ import annotations

import base64
import json
import random
import re
import time
from typing import Any, Optional
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse

import requests
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
)
PROBE_FALLBACK = "http://www.msftconnecttest.com/connecttest.txt"
LOGIN_PAGE_PATH = "/cas-sso/login"
CAPTCHA_PATH = "/cas-sso/api/protected/user/findCaptchaCount"
RESOLVE_PATH = "/eportal/json/resolveRedirectInfo/resolve"
CURRENT_NODE_PATH = "/eportal/workFlow/getCurrentNode"
USER_ONLINE_PATH = "/eportal/network/userOnline"
OFFLINE_PATH = "/eportal/network/offline"


class LoginError(Exception):
    pass


def aes_encrypt_b64(key_b64: str, plaintext: str) -> str:
    key = base64.b64decode(key_b64)
    padder = PKCS7(128).padder()
    data = padder.update(plaintext.encode("utf-8")) + padder.finalize()
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return base64.b64encode(enc.update(data) + enc.finalize()).decode("ascii")


def new_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": UA, "Accept-Encoding": "identity"})
    return s


def resp_text(r: requests.Response) -> str:
    raw = r.content
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("gbk", "replace")


def is_online(sess: requests.Session, probe_url: str, timeout: float = 8.0) -> bool:
    try:
        r = sess.get(probe_url, allow_redirects=False, timeout=timeout)
    except requests.RequestException:
        return False
    if 300 <= r.status_code < 400:
        return False
    if r.status_code == 204:
        return True
    try:
        r2 = sess.get(PROBE_FALLBACK, allow_redirects=False, timeout=timeout)
    except requests.RequestException:
        return False
    return r2.status_code == 200 and "Microsoft Connect Test" in resp_text(r2)


def capture_redirect_chain(
    sess: requests.Session, probe_url: str, timeout: float = 8.0, max_hops: int = 8
) -> list[str]:
    hops: list[str] = []
    url = probe_url
    for _ in range(max_hops):
        try:
            r = sess.get(url, allow_redirects=False, timeout=timeout)
        except requests.RequestException as e:
            hops.append(f"<error {e}>")
            break
        loc = r.headers.get("Location", "")
        hops.append(f"{r.status_code} {url}" + (f" -> {loc}" if loc else ""))
        if 300 <= r.status_code < 400 and loc:
            url = urljoin(url, loc)
            continue
        break
    return hops


def extract_gateway_params(hops: list[str]) -> dict[str, str]:
    for line in reversed(hops):
        m = re.search(r" -> (\S+)$", line)
        if not m:
            continue
        q = urlparse(m.group(1)).query
        params = {k: v for k, v in parse_qsl(q, keep_blank_values=True)}
        if params:
            return params
    return {}


def resolve_redirect(sess: requests.Session, server: str, params: dict[str, str], timeout: float = 8.0) -> dict[str, Any]:
    url = f"http://{server}{RESOLVE_PATH}"
    r = sess.get(url, params=params, timeout=timeout)
    r.raise_for_status()
    return r.json()


def random_flow_session_id() -> str:
    return "".join(random.choices("0123456789abcdef", k=12))


def build_login_query(
    flow_session_id: str,
    custom_page_id: str,
    user_ip: Optional[str] = None,
    nas_ip: Optional[str] = None,
) -> str:
    fields = [
        ("flowSessionId", flow_session_id),
        ("customPageId", custom_page_id),
        ("preview", "false"),
        ("appType", "normal"),
        ("language", "zh-CN"),
        ("timer", str(int(time.time() * 1000))),
    ]
    if user_ip:
        fields.append(("userIp", user_ip))
    if nas_ip:
        fields.append(("nasIp", nas_ip))
    fields.append(("accept-language", "zh-CN"))
    return urlencode(fields)


def fetch_login_page(sess: requests.Session, server: str, query: str, timeout: float = 8.0) -> dict[str, str]:
    url = f"http://{server}{LOGIN_PAGE_PATH}?{query}"
    r = sess.get(url, timeout=timeout)
    r.raise_for_status()
    html = resp_text(r)
    m_key = re.search(r'id="login-croypto">([^<]*)<', html)
    m_exec = re.search(r'id="login-page-flowkey">([^<]*)<', html)
    if not m_key or not m_key.group(1) or not m_exec or not m_exec.group(1):
        raise LoginError("登录页缺少 croypto/execution 令牌（页面结构可能已变更）")
    return {"croypto": m_key.group(1), "execution": m_exec.group(1), "html": html}


def captcha_required(sess: requests.Session, server: str, username: str, timeout: float = 8.0) -> tuple[bool, str]:
    url = f"http://{server}{CAPTCHA_PATH}/{username}?{int(time.time() * 1000)}"
    try:
        r = sess.get(url, timeout=timeout)
        data = (r.json().get("data") or {}) if r.status_code == 200 else {}
    except (requests.RequestException, ValueError):
        return False, "验证码检查接口异常（忽略）"
    if data.get("captchaInvisible"):
        return False, "无需验证码"
    if int(data.get("count") or 0) > 0:
        return True, "该账号需要验证码，脚本无法自动处理"
    return False, "无需验证码"


def cas_login(
    sess: requests.Session,
    server: str,
    query: str,
    username: str,
    password: str,
    croypto: str,
    execution: str,
    timeout: float = 10.0,
) -> dict[str, Any]:
    url = f"http://{server}{LOGIN_PAGE_PATH}?{query}"
    body = urlencode(
        [
            ("username", username),
            ("type", "UsernamePassword"),
            ("_eventId", "submit"),
            ("geolocation", ""),
            ("execution", execution),
            ("captcha_code", ""),
            ("croypto", croypto),
            ("password", aes_encrypt_b64(croypto, password)),
            ("captcha_payload", aes_encrypt_b64(croypto, "{}")),
        ]
    )
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": f"http://{server}",
        "Referer": f"http://{server}{LOGIN_PAGE_PATH}?{query}",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    }
    r = sess.post(url, data=body, headers=headers, allow_redirects=False, timeout=timeout)
    result: dict[str, Any] = {"status": r.status_code, "location": r.headers.get("Location", "")}
    if r.status_code in (301, 302, 303, 307, 308):
        result["ticket_url"] = result["location"]
    else:
        result["html"] = resp_text(r)
    return result


def json_post(sess: requests.Session, server: str, path: str, payload: dict, timeout: float = 8.0) -> dict[str, Any]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/plain, */*",
        "Origin": f"http://{server}",
        "Referer": f"http://{server}/portal/entry/pc/finish;flowParams=undefined;from=authenticate;sid=false",
        "isPortal": "true",
    }
    r = sess.post(f"http://{server}{path}", data=json.dumps(payload), headers=headers, timeout=timeout)
    r.raise_for_status()
    try:
        return r.json()
    except ValueError:
        return {}


def confirm_online(
    sess: requests.Session, server: str, flow_session_id: str, tries: int = 6, delay: float = 2.0
) -> tuple[bool, dict[str, Any]]:
    last: dict[str, Any] = {}
    for i in range(tries):
        try:
            node = json_post(
                sess, server, CURRENT_NODE_PATH, {"sessionId": flow_session_id, "flowKey": "portal_auth"}
            )
            last["currentNode"] = node
        except (requests.RequestException, ValueError) as e:
            last["currentNodeError"] = str(e)
        try:
            online = json_post(sess, server, USER_ONLINE_PATH, {"sessionId": flow_session_id})
            last["userOnline"] = online
            data = online.get("data") or {}
            if data.get("online"):
                return True, last
        except (requests.RequestException, ValueError) as e:
            last["userOnlineError"] = str(e)
        if i < tries - 1:
            time.sleep(delay)
    return False, last


def do_login(cfg: dict[str, Any], log) -> tuple[bool, str]:
    server: str = cfg["server"]
    username: str = cfg["username"]
    password: str = cfg["password"]
    custom_page_id: str = cfg["custom_page_id"]
    probe_url: str = cfg["probe_url"]
    timeout: float = float(cfg.get("timeout", 8))

    sess = new_session()

    if is_online(sess, probe_url, timeout):
        return True, "当前已在线"

    log.info("检测到离线，捕获网关重定向链...")
    hops = capture_redirect_chain(sess, probe_url, timeout)
    for h in hops:
        log.info("  重定向: %s", h)
    gw_params = extract_gateway_params(hops)
    if gw_params:
        log.info("网关参数: %s", gw_params)

    user_ip = gw_params.get("userIp") or gw_params.get("userip")
    nas_ip = gw_params.get("nasIp") or gw_params.get("nasip")
    flow_session_id: Optional[str] = gw_params.get("sessionId") or gw_params.get("flowSessionId")
    if flow_session_id:
        log.info("使用重定向链中的 sessionId: %s", flow_session_id)

    try:
        resolved = resolve_redirect(sess, server, gw_params or {}, timeout)
        log.info("resolveRedirectInfo: %s", json.dumps(resolved, ensure_ascii=False)[:500])
        msg = resolved.get("message") or {}
        if isinstance(msg, dict):
            user_ip = user_ip or msg.get("userIp")
            nas_ip = nas_ip or msg.get("nasIp")
            if not flow_session_id and msg.get("valid"):
                text = json.dumps(msg, ensure_ascii=False)
                m = re.search(r'"flowSessionId"\s*[:=]\s*"?([0-9a-f]{8,32})', text) or re.search(
                    r"flowSessionId=([0-9a-f]{8,32})", text
                )
                if m:
                    flow_session_id = m.group(1)
    except (requests.RequestException, ValueError) as e:
        log.warning("resolveRedirectInfo 失败: %s", e)

    if not flow_session_id:
        flow_session_id = random_flow_session_id()
        log.info("使用自生成 flowSessionId: %s", flow_session_id)

    query = build_login_query(flow_session_id, custom_page_id, user_ip, nas_ip)

    need, captcha_msg = captcha_required(sess, server, username, timeout)
    if need:
        return False, captcha_msg

    log.info("获取登录页令牌...")
    page = fetch_login_page(sess, server, query, timeout)
    log.info("croypto=%s execution=%s...", page["croypto"], page["execution"][:36])

    log.info("提交登录凭证...")
    login = cas_login(sess, server, query, username, password, page["croypto"], page["execution"], timeout)
    ticket_url = login.get("ticket_url", "")
    if not ticket_url:
        log.error("CAS 登录未返回 ticket，status=%s", login.get("status"))
        log.debug("CAS 响应片段: %s", (login.get("html") or "")[:1000])
        return False, f"CAS 登录失败（HTTP {login.get('status')}），详见日志"
    log.info("登录成功，ticket 回调: %s", ticket_url[:120])

    try:
        sess.get(ticket_url, timeout=timeout)
    except requests.RequestException as e:
        log.warning("ticket 回调访问失败（继续确认在线状态）: %s", e)

    ok, detail = confirm_online(sess, server, flow_session_id)
    if ok:
        return True, f"登录成功 sessionId={flow_session_id}"
    log.error("在线确认失败: %s", json.dumps(detail, ensure_ascii=False)[:1000])
    return False, "凭证已提交但在线确认失败（可能需要合规检查或账号受限）"


def do_logout(cfg: dict[str, Any], flow_session_id: str) -> tuple[bool, str]:
    sess = new_session()
    try:
        resp = json_post(
            sess, cfg["server"], OFFLINE_PATH, {"sessionId": flow_session_id}, timeout=float(cfg.get("timeout", 8))
        )
    except (requests.RequestException, ValueError) as e:
        return False, f"注销请求失败: {e}"
    code = resp.get("code")
    if code == 200:
        return True, "注销请求已受理"
    return False, f"注销返回异常: {json.dumps(resp, ensure_ascii=False)[:300]}"
