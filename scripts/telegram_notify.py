#!/usr/bin/env python3
"""将 GitHub Actions 构建结果发送到 Telegram。密钥仅从环境变量读取。"""
import html
import json
import os
import re
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
    override = os.environ.get("TELEGRAM_RELEASE_TAG", "").strip()
    if override:
        return next((r for r in releases if r.get("tag_name") == override), None)
    if EVENT == "workflow_dispatch":
        wanted = f"-pre.{RUN_NUMBER}"
        return next((r for r in releases if r.get("tag_name", "").endswith(wanted)), None)
    return next((r for r in releases if r.get("tag_name") == REF_NAME), None)

def send(method, fields, filename=None, display_name=None):
    import subprocess
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    args = ["curl", "--fail-with-body", "--silent", "--show-error",
            "--retry", "2", "--max-time", "120", "-X", "POST", url]
    for key, value in fields.items():
        args.extend(["--form-string", f"{key}={value}"])
    if filename:
        args.extend(["-F", f"document=@{filename};filename={display_name or 'ParcelHelper.ipa'};type=application/octet-stream"])
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

def rich_release_html(tag, kind, link, body):
    """简洁单版本资源帖：文件和表格直接呈现，日志与可点击图片画廊默认收起。"""
    safe_tag = html.escape(tag)
    highlights = compact_release_notes(body)
    log_items = "".join(
        f"<li><b>{html.escape(category)}</b>：{html.escape(item[:115])}</li>"
        for category, item in highlights
    ) or "<li>请查看完整更新日志。</li>"
    pictures = "".join(
        f'<img src="https://raw.githubusercontent.com/{REPO}/main/docs/screenshots/poster-0{i}.png"/>'
        for i in range(1, 7)
    )
    return (
        '<p><b>包裹助手</b></p>'
        '<tg-document src="tg://document?id=parcel_ipa"></tg-document>'
        '<table bordered compact>'
        '<tr><th>系统要求</th><td>iOS 17.0 及以上</td></tr>'
        '<tr><th>应用功能</th><td>订单同步 · 物流追踪 · 取件码</td></tr>'
        '<tr><th>扩展功能</th><td>灵动岛 · 锁屏实时活动 · 桌面小组件</td></tr>'
        '<tr><th>安装说明</th><td>未签名 IPA，需自行签名</td></tr>'
        '</table>'
        f'<details><summary>{safe_tag} 更新日志</summary><ul>{log_items}</ul></details>'
        '<details><summary>截图预览 · 点击展开</summary>'
        f'<tg-collage>{pictures}</tg-collage></details>'
        '<p>'
        f'<a href="{html.escape(link, quote=True)}">完整更新日志</a> · '
        f'<a href="https://github.com/{REPO}">GitHub</a>'
        '</p>'
    )


def send_rich_document(common, rich_html, ipa, display_name):
    """multipart 上传与富文本同一条消息，确定性 API 拒绝才回退旧版。"""
    import subprocess
    payload = {
        "html": rich_html,
        "media": [{
            "id": "parcel_ipa",
            "media": {"type": "document", "media": "attach://parcel_attachment"}
        }],
    }
    args = ["curl", "--silent", "--show-error", "--max-time", "120", "-X", "POST",
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendRichMessage"]
    for key, value in common.items():
        args.extend(["--form-string", f"{key}={value}"])
    args.extend([
        "--form-string", "rich_message=" + json.dumps(payload, ensure_ascii=False),
        "-F", f"parcel_attachment=@{ipa};filename={display_name};type=application/octet-stream",
    ])
    response = subprocess.run(args, capture_output=True, text=True)
    # 超时等网络错误无法判断消息是否已经发出，避免重试导致重复消息。
    if response.returncode:
        print("::error::Telegram 富文本请求网络错误，未回退以防重复发送。")
        return False, False
    try:
        result = json.loads(response.stdout)
    except json.JSONDecodeError:
        print("::error::Telegram 富文本响应无法解析，未回退以防重复发送。")
        return False, False
    if result.get("ok"):
        print("Telegram 富文本发布成功：包含内嵌 IPA、表格、折叠更新日志和截图。")
        return True, False
    print("::warning::Telegram 拒绝富文本消息，尝试使用普通 IPA 附件发送。")
    return False, True


def compact_release_notes(markdown):
    """从 Release Markdown 中提取精简中文摘要，不把 ** 等标记原样发到 Telegram。"""
    categories = {"新增", "调整", "修复", "优化", "移除"}
    found = []
    current = ""
    for raw in markdown.splitlines():
        line = raw.strip()
        header = re.match(r"^#{2,4}\s*(.+)$", line)
        if header:
            title = re.sub(r"[*`#]", "", header.group(1)).strip()
            current = title if title in categories else ""
            continue
        if current and line.startswith(("- ", "* ")):
            item = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", line[2:])
            item = re.sub(r"\*\*(.*?)\*\*", r"\1", item)
            item = item.replace("`", "").strip()
            if item and not any(category == current for category, _ in found):
                found.append((current, item))
    return found[:4]


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
        status = {"failure": "构建失败", "cancelled": "构建取消", "skipped": "构建跳过"}.get(RESULT, "构建未成功")
        message = (
            f"<b>包裹助手｜{status}</b>\n"
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
    tag = (release or {}).get("tag_name") or os.environ.get("TELEGRAM_RELEASE_TAG") or REF_NAME
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-pre\.[0-9]+)?", tag):
        print("::error::无法从 Release 识别合法版本号，取消发送，避免文件名称错误。")
        return 1
    display_name = f"包裹助手_{tag}.ipa"
    link = (release or {}).get("html_url") or RELEASES_LINK
    body = (release or {}).get("body") or ""
    kind = ("手动重发" if os.environ.get("TELEGRAM_RELEASE_TAG")
            else "手动构建" if EVENT == "workflow_dispatch" else "正式发布")
    caption = (
        f"<b>包裹助手 · {html.escape(tag)}</b>\n"
        "系统要求：iOS 17.0 及以上\n"
        "应用功能：订单同步、物流追踪、取件码\n"
        "扩展功能：灵动岛、锁屏实时活动、桌面小组件\n"
        "安装说明：未签名 IPA，需自行签名\n"
    )
    highlights = compact_release_notes(body)
    if highlights:
        snippet = "\n".join(
            f"• {category}：{html.escape(content[:65])}{'…' if len(content) > 65 else ''}"
            for category, content in highlights
        )
        caption += f"\n<blockquote expandable>{html.escape(tag)} 更新日志\n{snippet}</blockquote>\n"
    caption += (f'\n<a href="{html.escape(link, quote=True)}">完整更新日志</a>'
                f' · <a href="https://github.com/{REPO}">GitHub</a>')
    if len(caption) > 950:
        caption = (
            f"<b>包裹助手 · {html.escape(tag)}</b>\n"
            "iOS 17.0 及以上 · 未签名 IPA\n"
            f'<a href="{html.escape(link, quote=True)}">完整更新日志</a>'
            f' · <a href="https://github.com/{REPO}">GitHub</a>'
        )
    ipa = Path("telegram-ipa/ParcelHelper.ipa")
    if not ipa.is_file():
        print("::error::构建成功，但没有找到 IPA 工件。")
        return 1
    rich_html = rich_release_html(tag, kind, link, body)
    sent, rejected = send_rich_document(common, rich_html, ipa, display_name)
    if sent:
        return 0
    if rejected:
        print("::warning::富文本不可用：回退为普通 Telegram 文件消息。")
        return 0 if send("sendDocument", {**common, "caption": caption, "parse_mode": "HTML"}, ipa, display_name) else 1
    return 1

if __name__ == "__main__":
    sys.exit(main())
