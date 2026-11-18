# 主屏幕小组件：实现、签名与验证

ParcelHelper 现已包含两种不同的 WidgetKit 内容：
- **桌面小组件**：小号 / 中号 / 大号，读取待取、在途包裹的本地快照；
- **锁屏实时活动与灵动岛**：继续使用 ActivityKit，配置不受桌面小组件影响。

桌面小组件沿用上传的 Scripting 原版「先显示共享快照，再更新」的设计，但不在扩展内运行电商 WebView 或承诺 3 秒内实时网络同步。App 前台同步 / 保存包裹后写入共享数据，并调用 WidgetCenter.reloadTimelines；WidgetKit 负责实际更新时机。

## 你的证书是否可以使用？

证书详情里出现 **App Groups** 代表描述文件可能授权了某些 Group，但**不能单靠这个勾选确认小组件能运行**。还需要：

1. 给主 App（`com.muxui.ParcelHelper`）和独立 Widget 扩展（`com.muxui.ParcelHelper.widget`）分别用可匹配 Bundle ID 的描述文件签名，且两者属于同一签名团队；
2. 两份签名的 `com.apple.security.application-groups` 必须包含**相同的、真实允许的** `group.xxx` 标识符；
3. 该组标识符必须与主 App 和 Widget 的 `ParcelHelperWidgetGroup` Info.plist 值一致；
4. 使用支持签名嵌入式 `.appex` 的签名工具，并保证安装后 Widget 扩展没有被移除。

不要直接复制别人证书详情中的 Group 名称。Group ID 必须属于自己有效的描述文件；第三方签名不保证 App Group 数据共享可用。

## 构建配置

Xcode 工程中的 `PH_WIDGET_GROUP` 默认是示例值 `group.com.muxui.ParcelHelper`，**并不代表该 Group 已获你的证书授权**。真正用自有 Xcode 签名时，应为两个 target 使用自己在 Apple Developer 中启用的相同 Group。

GitHub Actions 构建未签名 IPA 时，可以在仓库 **Settings → Secrets and variables → Actions → Variables** 设置 `PH_WIDGET_GROUP` 为**你自己的有效** Group ID，工作流会将此值写入两个 Bundle 的 Info.plist 和 Entitlements。它不生成有效签名；安装前仍需要按相同 Group ID 为 App 和扩展签名。未设置时，只使用示例值。

可检查重签后的主 App 和扩展是否都保留了 App Group 权限以及对应的 Group ID；如果 App 内「设置 → 小组件」显示「当前签名未配置」，该 App 无法访问共享快照，桌面组件会提示检查签名。

## 数据与交互

- App 原始包裹文件仍在 App 私有 Documents，**不会搬迁、覆盖或清空现有包裹**。
- App 写入一个只含待取、在途包裹摘要的 `parcelhelper-widget.json`，**不写 Cookie、账号 Token、Keychain 密钥**。
- 组件上的圆圈使用 iOS 17+ AppIntent 写入逐包裹操作文件。组件先隐藏已标记项；打开 App 时才正式写回 ParcelStore，成功落盘后清理操作文件。
- 刷新时机由 iOS 调度。WidgetKit 的 30 分钟时间线刷新只是建议，**不是每 30 分钟后台联网**。
- 没有可用的共享 Group 时，扩展仍可以构建，但组件不会读取真实包裹数据。

## 安装验证

1. 在签名工具中为 **主 App 和 Widget 扩展** 启用相同 App Group，检查 `.appex` 没有被剔除；
2. 签名安装后打开 App → 设置 → 小组件，确认「App Groups：当前签名可访问」；
3. 点击「重新写入小组件数据」；
4. iPhone 主屏幕长按空白处 → 编辑 → 添加小组件 → 搜索「包裹助手」，选择小 / 中 / 大号；
5. 看数量与取件列表是否一致；点圆圈测试已取操作，打开 App 确认数据保存。

如找不到「包裹助手」，优先排查 **Widget 扩展单独签名、Bundle ID、扩展的 provisioning profile**，而不是刷新间隔。