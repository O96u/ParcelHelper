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

## 自己的 App Group：最简步骤

要使用桌面小组件，**需要在 GitHub 手动构建时输入自己证书允许的 App Groups**。成功签名的小组件不必使用仓库示例组。

图文教程（含截图）：[置顶 Issue #2](https://github.com/O96u/ParcelHelper/issues/2) · 图源 [docs/guide/widget-self-sign](https://github.com/O96u/ParcelHelper/tree/main/docs/guide/widget-self-sign)

1. 打开 [Build ParcelHelper IPA](https://github.com/O96u/ParcelHelper/actions/workflows/build-ipa.yml)，点击 **Run workflow**。
2. 在 `widget_group` 中填入**你自己签名描述文件列出的** `group.xxx`，点击运行。不要照抄他人或无关应用的 Group。
3. 下载生成的 IPA，使用 LCSign 等签名工具保留 Widget 扩展，并确认主 App、Widget 使用同一个被允许的 App Group。
4. 安装后在 App 的「设置 → 小组件」确认「当前签名可访问」，再点击「重新写入小组件数据」。

手动构建产生 **Pre-release**（例如 `v1.2.0-pre.42`），**不会**成为 Releases 页的 Latest。推送 `v1.2.x` 标签才是正式 Latest。GitHub 的 IPA 构建本身不会自动颁发签名权限。

## 构建配置

Xcode 工程中的 `PH_WIDGET_GROUP` 默认是示例值 `group.com.muxui.ParcelHelper`，**并不代表该 Group 已获你的证书授权**。真正用自有 Xcode 签名时，应为两个 target 使用自己在 Apple Developer 中启用的相同 Group。

GitHub Actions 构建未签名 IPA 时指定 Group ID：

- **手动预发布（推荐自用签名）：** **Actions → Build ParcelHelper IPA → Run workflow**，必填 `widget_group`（`group.xxx`）。产出为 Pre-release，仅供下载对应 IPA，不替换 Latest。
- **正式版标签发版：** 维护者推送 `v1.2.x` 标签；可选用仓库变量 **`PH_WIDGET_GROUP`**（Settings → Actions → Variables）作为正式构建默认值。未配置时使用示例 `group.com.muxui.ParcelHelper` 并给出警告。

构建过程会检查**主 App 和 Widget 两份 Info.plist 的共享组值是否一致**。但构建是未签名的，此检查不代表设备安装时已有实际权限。

**必须确认主 App 与 Widget 扩展的重签名描述文件都允许这个组。** 如果 LCSign 为二者使用不同 App Group 或把共享权限删除，那么换一个源码中的组名也无法解决；需要在签名器内调整扩展的描述文件/权限后覆盖安装。

可检查重签后的主 App 和扩展是否都保留了 App Group 权限以及对应的 Group ID；如果 App 内「设置 → 小组件」显示「当前签名未配置」，该 App 无法访问共享快照，桌面组件会提示检查签名。

## 数据与交互

- App 原始包裹文件仍在 App 私有 Documents，**不会搬迁、覆盖或清空现有包裹**。
- App 写入一个只含待取、在途包裹摘要的 `parcelhelper-widget.json`，**不写 Cookie、账号 Token、Keychain 密钥**。
- 组件上的圆圈使用 iOS 17+ AppIntent 写入逐包裹操作文件。组件先隐藏已标记项；打开 App 时才正式写回 ParcelStore，成功落盘后清理操作文件。
- 刷新时机由 iOS 调度。WidgetKit 的 30 分钟时间线刷新只是建议，**不是每 30 分钟后台联网**。
- 没有可用的共享 Group 时，扩展仍可以构建，但组件不会读取真实包裹数据。

## 常见问题：显示「当前签名未配置 / 等待小组件共享数据」

这两种提示首先是**共享权限问题，不是 UI 或刷新频率问题**。App 可以安装、桌面能添加 Widget，并不表示共享数据权限有效：

1. 打开 **设置 → 小组件 → 共享数据与签名**，确认「构建共享组」显示的是你在签名工具中使用的实际 Group ID，且「App Groups」是「当前签名可访问」。
2. 这个组必须真实包含在**主 App 与 `ParcelHelperWidget.appex` 两份重签名描述文件**的 App Groups 权限中；两者必须相同。默认的 `group.com.muxui.ParcelHelper` 仅供构建示例，不是第三方证书保证拥有的组。
3. 若 LCSign 使用的描述文件只授权 `group.其他前缀`，应在 **GitHub Actions 仓库变量 `PH_WIDGET_GROUP`** 中设置实际获授权的公共组，重新构建 IPA，然后让 LCSign 对主 App、扩展分别签名，确保保留这个权限。不推荐把其他应用私有、无关的共享组硬编码进项目。
4. App 显示「当前签名可访问」，但「已读取共享快照」未出现时，点击「重新写入小组件数据」，等待出现成功提示。若仍失败，检查磁盘共享容器访问或扩展签名。
5. 若 App 显示 0 件而实际数据曾存在，先核实是否因重签名时变更 Bundle Identifier、安装时卸载旧 App 导致本地包裹数据库发生变化。小组件只能展示 App **当前**的包裹数据，不能恢复卸载前的数据。

新小组件 UI 使用 ParcelHelper 首页的蓝色统计卡片，支持小、中、大尺寸；不可读共享容器与“真无包裹”会显示不同的状态说明，不再都当作零件。WidgetKit 仍遵循系统刷新调度，无法绕过 iOS 的后台限制。

## 安装验证

1. 在签名工具中为 **主 App 和 Widget 扩展** 启用相同 App Group，检查 `.appex` 没有被剔除；
2. 签名安装后打开 App → 设置 → 小组件，确认「App Groups：当前签名可访问」；
3. 点击「重新写入小组件数据」；
4. iPhone 主屏幕长按空白处 → 编辑 → 添加小组件 → 搜索「包裹助手」，选择小 / 中 / 大号；
5. 看数量与取件列表是否一致；点圆圈测试已取操作，打开 App 确认数据保存。

如找不到「包裹助手」，优先排查 **Widget 扩展单独签名、Bundle ID、扩展的 provisioning profile**，而不是刷新间隔。
## 只保留最新构建

仓库的 GitHub Actions 为同一分支设置了 `concurrency.cancel-in-progress: true`。当 `main` 新提交或再次运行 Workflow，旧的**排队中/执行中**任务会自动取消，只继续最新一次；不会删除历史任务记录或已经发布的 Release。手动用专用 App Group 构建时，请避免在它执行期间继续向 `main` 推送，否则也会被最新运行取消。
