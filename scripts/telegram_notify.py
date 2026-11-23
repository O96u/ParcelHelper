#!/usr/bin/env python3
"""将 GitHub Actions 构建结果发送到 Telegram。密钥仅从环境变量读取。"""
import html
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
TOPIC_ID = os.environ.get("TELEGRAM_TOPIC_ID", "").strip()
REPO = os.environ["GITHUB_REPOSITORY"]
RUN_ID = os.environ["GITHUB_RUN_ID"]
RUN_NUMBER = os.environ["GITHUB_RUN_NUMBER"]
RESULT = os.environ["BUILD_RESULT"].lower()
EVENT = os.environ["GITHUB_EVENT_NAME"]
REF_NAME = os.environ.get("GITHUB_REF_NAME", "")
RUN_LINK = f"https://github.com/{REPO}/actions/runs/{RUN_ID}"
RELEASES_LINK = f"https://github.com/{REPO}/releases"

def release_info():
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        return None
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/releases?per_page=30",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "ParcelHelper-Telegram",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as resp:
        releases = json.load(resp)
    if EVENT == "workflow_dispatch":
        wanted = f"-pre.{RUN_NUMBER}"
        return next((r for r in releases if r.get("tag_name", "").endswith(wanted)), None)
    return next((r for r in releases if r.get("tag_name") == REF_NAME), None)

def send(method, fields, filename=None):
    import subprocess
    import tempfile
    import uuid
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    args = ["curl", "--fail-with-body", "--silent", "--show-error",
            "--retry", "2", "--max-time", "120", "-X", "POST", url]
    for key, value in fields.items():
        args.extend(["--form-string", f"{key}={value}"])
    if filename:
        args.extend(["-F", f"document=@{filename};filename=ParcelHelper.ipa;type=application/octet-stream"])
    # 避免 curl 将含 token 的 URL / 机器人响应写入 Actions 日志。
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        print(f"::error::Telegram {method} 发送失败（HTTP 或网络错误，退出码 {result.returncode}）。")
        return False
    try:
        response = json.loads(result.stdout)
        if not response.get("ok"):
            print("::error::Telegram 拒绝请求，请检查 Chat ID、机器人权限及文件大小。")
            return False
    except (json.JSONDecodeError, TypeError):
        print("::error::Telegram 响应不是预期的 JSON。")
        return False
    print(f"Telegram {method} 发送成功。")
    return True

def main():
    if not BOT_TOKEN or not CHAT_ID:
        print("::warning::未配置 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID，跳过 Telegram 通知。")
        return 0
    if TOPIC_ID and not TOPIC_ID.isdigit():
        print("::error::TELEGRAM_TOPIC_ID 必须为数字。")
        return 1
    common = {"chat_id": CHAT_ID}
    if TOPIC_ID:
        common["message_thread_id"] = TOPIC_ID
    if RESULT != "success":
        status = {"failure": "❌ 构建失败", "cancelled": "⚪ 构建取消", "skipped": "⚪ 构建跳过"}.get(RESULT, "⚠️ 构建未成功")
        message = (
            f"<b>📦 ParcelHelper｜{status}</b>\n"
            f"触发方式：{'手动构建' if EVENT == 'workflow_dispatch' else '标签自动构建'}\n"
            f"引用：<code>{html.escape(REF_NAME)}</code>\n"
            f"<a href=\"{RUN_LINK}\">查看构建日志</a>"
        )
        return 0 if send("sendMessage", {**common, "text": message, "parse_mode": "HTML"}) else 1
    try:
        release = release_info()
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        print("::warning::读取 GitHub Release 失败，仍尝试发送 IPA。")
        release = None
    tag = (release or {}).get("tag_name") or REF_NAME
    link = (release or {}).get("html_url") or RELEASES_LINK
    body = (release or {}).get("body") or ""
    # Telegram 文件 caption 最大 1024 字符；仅保留简短概要，其余通过 Release 链接查看。
    lines = [line.strip().lstrip("- ") for line in body.splitlines()
             if line.strip() and not line.startswith("#") and not line.startswith("##")]
    notes = "\n".join("• " + html.escape(line[:110]) for line in lines[:6])
    caption = (
        "<b>📦 ParcelHelper｜包裹助手</b>\n"
        f"<b>✅ {html.escape(tag)} 构建成功</b>\n"
        f"🔹 {'手动预发布' if EVENT == 'workflow_dispatch' else '正式版本'} · iOS 17+\n"
        "📦 ParcelHelper.ipa（未签名，需自行签名）\n"
        "✨ 订单同步 · 物流追踪 · 取件码 · 灵动岛 · 桌面小组件\n"
    )
    if notes:
        caption += "<blockquote expandable>📝 更新说明\n" + notes + "</blockquote>\n"
    caption += f'<a href="{html.escape(link, quote=True)}">GitHub Release</a> · <a href="{RUN_LINK}">构建记录</a>'
    if len(caption) > 950:
        caption = (
            f"<b>📦 ParcelHelper｜✅ {html.escape(tag)} 构建成功</b>\n"
            "📦 ParcelHelper.ipa（未签名）\n"
            f'<a href="{html.escape(link, quote=True)}">查看完整更新日志与下载</a> · '
            f'<a href="{RUN_LINK}">构建记录</a>'
        )
    ipa = Path("telegram-ipa/ParcelHelper.ipa")
    if not ipa.is_file():
        print("::error::构建成功，但没有找到 IPA 工件。")
        return 1
    return 0 if send("sendDocument", {**common, "caption": caption, "parse_mode": "HTML"}, ipa) else 1

if __name__ == "__main__":
    sys.exit(main())
