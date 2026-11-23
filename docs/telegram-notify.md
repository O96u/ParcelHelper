# Telegram 构建通知

ParcelHelper 的 `Build ParcelHelper IPA` 工作流在 **推送 v* 正式版标签** 和 **Actions → Run workflow 手动预发布构建** 时，都会在构建结束后执行 Telegram 通知。

- 构建成功：优先通过 `sendRichMessage` 在同一条富文本消息内嵌真实 IPA 文件（显示名为 `包裹助手_v版本号.ipa`），提供双列表格、可折叠更新日志和项目截图、GitHub 链接。若 Telegram 明确拒绝富文本请求，则回退 `sendDocument` 发送真实 IPA 附件。
- 构建失败：通过 `sendMessage` 发送失败提示和 Actions 构建日志链接。
- 无需为 Telegram 另外触发一次 IPA 构建；通知是构建工作流的第二个 Job。
- 未配置接收信息时，通知步骤会输出中文警告并跳过，不会将密钥写入源代码或日志。
- GitHub Actions 的手动预发布依旧需要填写 App Group。签名安装需要用户自己的证书。
- 被强制终止或取消的整个工作流不保证执行后续通知（GitHub Actions 运行约束）。

## 首次配置

1. 在 Telegram 打开 [@guaguawa_bot](https://t.me/guaguawa_bot)，点击 **Start** 并向机器人发送一条消息。如果要发送到频道，则先把机器人添加为管理员，授予发布消息权限。
2. 确认接收聊天的 **Chat ID**：私聊可通过 Telegram 的 ID 查询机器人获取；频道可使用该频道的数字 ID（通常为 `-100...`）。如果使用频道讨论主题，可另设 Topic ID。
3. **重要：若机器人 Token 曾在聊天、截图或提交中公开，请先通过 @BotFather 撤销并重新生成。**
4. 打开 GitHub 仓库 **Settings → Secrets and variables → Actions → Secrets → New repository secret**，创建以下两项：
   - `TELEGRAM_BOT_TOKEN`：重新生成的 Bot Token（请勿复制到仓库文件）。
   - `TELEGRAM_CHAT_ID`：接收通知的私聊或频道 Chat ID。
5. 如需发送到话题，在同一页面的 **Variables** 中创建可选变量 `TELEGRAM_TOPIC_ID`，值为该话题的数字 ID。
6. 手动运行一次 **Build ParcelHelper IPA**，填写 `widget_group`，构建成功后验证 TG 中是否收到 IPA 和更新摘要。

## 注意

- 只有 `build-ipa.yml` 的构建触发通知，`pr-validation.yml` 的 PR 代码检查不打包 IPA，因此不发送。
- 机器人不能主动发私聊给从未点过 **Start** 的用户。
- 新版 Telegram Bot API 的 `sendRichMessage` 支持真正的表格、`<details>` 折叠区域和内嵌文件。旧版客户端可能无法完整呈现；富文本消息明确被拒绝时回退普通 `sendDocument` 文件消息。
- 如果构建成功但 Telegram 发送失败，`telegram-notify` Job 会失败并可在 Actions 查看原因；已经发布的 GitHub Release 不受影响。

## 富文本资源帖

发送脚本优先使用 Bot API 10.3 的 `sendRichMessage`：按参考图布局展示包裹助手标题、已发布 IPA、系统要求/功能表格、折叠更新日志、可展开的六张官方仓库截图以及 GitHub 链接。通过 `InputRichMessage.media` + multipart 文件上传保证 IPA 作为真实附件，而非仅写文件名。更新摘要最多提取四个不同类别的条目，并剥除 Markdown 加粗标记。Telegram 是否完整渲染取决于客户端版本。
