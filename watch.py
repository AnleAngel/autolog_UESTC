"""Campus network watchdog: probe -> auto login loop with CLI modes."""
from __future__ import annotations

import argparse
import configparser
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Optional

import login

BASE_DIR = Path(__file__).resolve().parent
LOG_DIR = BASE_DIR / "logs"
STATE_FILE = BASE_DIR / "state.json"

DEFAULTS = {
    "server": "110.184.24.61",
    "custom_page_id": "5f8dcce7c1904743951c7112e62691b7",
    "probe_url": "http://edge-http.microsoft.com/captiveportal/generate_204",
    "interval": "300",
    "timeout": "8",
    "backoff_max": "600",
}

logger = logging.getLogger("campus")


def setup_logging(verbose: bool = False) -> None:
    LOG_DIR.mkdir(exist_ok=True)
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    fh = logging.FileHandler(LOG_DIR / f"watch_{time.strftime('%Y%m%d')}.log", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.DEBUG if verbose else logging.INFO)
    ch.setFormatter(fmt)
    logger.addHandler(fh)
    logger.addHandler(ch)


def load_config(require_account: bool = True) -> dict[str, Any]:
    cfg_file = BASE_DIR / "config.ini"
    if not cfg_file.exists():
        example = BASE_DIR / "config.example.ini"
        logger.error("缺少配置文件 config.ini，请参照 %s 创建并填写账号密码", example.name)
        sys.exit(2)
    cp = configparser.ConfigParser()
    cp.read(cfg_file, encoding="utf-8-sig")
    merged: dict[str, Any] = dict(DEFAULTS)
    for section in ("portal", "watch"):
        if cp.has_section(section):
            merged.update({k: v for k, v in cp.items(section)})
    account = {}
    if cp.has_section("account"):
        account = dict(cp.items("account"))
    merged["username"] = account.get("username", "")
    merged["password"] = account.get("password", "")
    if require_account and (not merged["username"] or not merged["password"]):
        logger.error("config.ini 中未填写账号或密码")
        sys.exit(2)
    merged["interval"] = float(merged["interval"])
    merged["backoff_max"] = float(merged["backoff_max"])
    return merged


def load_state() -> dict[str, Any]:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            pass
    return {}


def save_state(state: dict[str, Any]) -> None:
    try:
        STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError as e:
        logger.warning("状态文件写入失败: %s", e)


def run_login_once(cfg: dict[str, Any]) -> tuple[bool, str]:
    ok, msg = login.do_login(cfg, logger)
    if ok and "sessionId=" in msg:
        fid = msg.split("sessionId=")[-1].strip()
        state = load_state()
        state["last_login"] = time.strftime("%Y-%m-%d %H:%M:%S")
        state["session_id"] = fid
        state["server"] = cfg["server"]
        save_state(state)
    return ok, msg


def cmd_check(cfg: dict[str, Any]) -> int:
    sess = login.new_session()
    online = login.is_online(sess, cfg["probe_url"], float(cfg["timeout"]))
    logger.info("在线状态: %s", "已在线" if online else "离线")
    return 0 if online else 1


def cmd_once(cfg: dict[str, Any]) -> int:
    ok, msg = run_login_once(cfg)
    logger.info("%s", msg)
    return 0 if ok else 1


def cmd_test(cfg: dict[str, Any]) -> int:
    state = load_state()
    fid = state.get("session_id")
    if not fid:
        logger.error("state.json 中没有可用的 sessionId，无法执行断网测试（请先成功登录一次）")
        return 2
    logger.warning("即将注销当前网络会话 sessionId=%s（约 5 秒后自动重新登录）", fid)
    if input("输入 YES 确认: ").strip() != "YES":
        logger.info("已取消")
        return 1
    ok, msg = login.do_logout(cfg, fid)
    logger.info("注销: %s", msg)
    time.sleep(5)
    ok2, msg2 = run_login_once(cfg)
    logger.info("%s", msg2)
    return 0 if ok2 else 1


def cmd_loop(cfg: dict[str, Any]) -> int:
    interval = float(cfg["interval"])
    backoff_max = float(cfg["backoff_max"])
    fail_count = 0
    logger.info("看护循环启动：server=%s interval=%ss", cfg["server"], interval)
    while True:
        try:
            sess = login.new_session()
            online = login.is_online(sess, cfg["probe_url"], float(cfg["timeout"]))
            if online:
                if fail_count:
                    logger.info("网络已恢复")
                fail_count = 0
            else:
                logger.info("检测到离线（连续第 %d 次），尝试登录...", fail_count + 1)
                ok, msg = run_login_once(cfg)
                logger.info("%s", msg)
                if ok:
                    fail_count = 0
                else:
                    fail_count += 1
                    sleep_for = min(30 * (2 ** (fail_count - 1)), backoff_max)
                    logger.info("登录失败，%.0f 秒后重试", sleep_for)
                    time.sleep(sleep_for)
                    continue
        except Exception:
            logger.exception("循环出现未预期异常")
            fail_count += 1
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(description="校园网自动登录看护")
    parser.add_argument("mode", nargs="?", default="loop", choices=["loop", "once", "check", "test"],
                        help="loop=常驻看护(默认) once=登录一次 check=仅检测在线 test=断网重连演练")
    parser.add_argument("-v", "--verbose", action="store_true", help="控制台输出 DEBUG 日志")
    args = parser.parse_args()
    setup_logging(args.verbose)
    cfg = load_config(require_account=(args.mode != "check"))
    if args.mode == "check":
        return cmd_check(cfg)
    if args.mode == "once":
        return cmd_once(cfg)
    if args.mode == "test":
        return cmd_test(cfg)
    return cmd_loop(cfg)


if __name__ == "__main__":
    sys.exit(main())
