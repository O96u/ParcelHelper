# Telegram 构建通知

ParcelHelper 的 `Build ParcelHelper IPA` 工作流在 **推送 v* 正式版标签** 和 **Actions → Run workflow 手动预发布构建** 时，都会在构建结束后执行 Telegram 通知。

- 构建成功：通过 `sendDocument` 发送真实的 `ParcelHelper.ipa` 文件，附简短发布介绍、可折叠更新摘要、GitHub Release 及 Actions 链接。
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
- Telegram 的文件标题、大小和附件 UI 是 Telegram 客户端原生生成，Bot API 不支持在消息中嵌入真正的双列表格。折叠更新日志使用 HTML `<blockquote expandable>`，客户端显示效果可能略有差异。
- 如果构建成功但 Telegram 发送失败，`telegram-notify` Job 会失败并可在 Actions 查看原因；已经发布的 GitHub Release 不受影响。
