<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="ParcelHelper App 图标" width="112" height="112">

# ParcelHelper for iOS

[![iOS](https://img.shields.io/badge/iOS-17%2B-blue)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://www.swift.org/)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-4b93d1)](https://developer.apple.com/xcode/swiftui/)
[![License: GPL v3](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![release](https://img.shields.io/github/v/release/O96u/ParcelHelper)](https://github.com/O96u/ParcelHelper/releases)

一款使用 **Swift 和 SwiftUI** 构建的开源 iPhone 快递管理工具，帮助整理取件码、查看已授权平台的订单与物流轨迹，并管理待取、运输中、已签收和已取件的包裹。

项目参考了 [Scripting 版「包裹助手」](https://t.me/scripting_app/913) 的交互、短信解析和部分物流同步思路，采用原生 iOS 界面重新实现；**不是原 Scripting 工程的完整 1:1 复刻**，也不是菜鸟、淘宝或任何快递公司的官方应用。

</div>

## 应用预览

以下截图均保留原始分辨率，涉及具体驿站地址的文字已遮挡。

<p align="center">
  <img src="docs/screenshots/preview-01.png" alt="账号授权" width="270">
  <img src="docs/screenshots/preview-02.png" alt="设置" width="270">
  <img src="docs/screenshots/preview-03.png" alt="统计" width="270">
  <img src="docs/screenshots/preview-04.png" alt="包裹列表" width="270">
  <img src="docs/screenshots/preview-05.png" alt="取件列表" width="270">
  <img src="docs/screenshots/preview-06.png" alt="取件列表示例" width="270">
</p>

> 点击截图可在 GitHub 中查看原始像素尺寸的图片。图片文件均为无损 PNG。

## 主要功能

| 模块       | 功能说明                                                                                               |
| ---------- | ------------------------------------------------------------------------------------------------------ |
| 包裹管理   | 取件码、运单号、驿站、备注、轨迹；待取 / 在途 / 签收 / 取件状态；搜索、编辑与手动标记已取              |
| 平台同步   | 登录授权后尝试读取淘宝、京东订单网页物流；菜鸟、拼多多、丰巢及小米快递聚合使用各自支持的会话与接口     |
| 短信识别   | 复制取件短信后打开 App 可确认导入；支持 App Shortcuts 文字 / 剪贴板导入（无法直接读取 iOS 短信数据库） |
| 物流提醒   | 前台同步识别派送、到站、签收等事件后发送本地通知（非 24 小时云端实时推送）                             |
| 统计与驿站 | 取件趋势、常用驿站、在轨迹数据可用时的到站时间统计；驿站支持展开式卡片编辑、关键词匹配与自动识别                                                     |
| 实时活动与小组件 | 灵动岛、锁屏实时活动及主屏幕小 / 中 / 大 WidgetKit 组件；显示本地包裹快照，App Group 共享依赖实际签名授权 |
| 本地保存   | 包裹数据默认保存在 App 沙盒 Documents；卸载或更换 Bundle Identifier 可能导致数据丢失，请先备份         |

平台页面、私有接口及登录策略可能随时变化，**不保证所有订单均能同步**。重要取件信息请以快递公司或平台官方页面为准。

## 安装与构建

**源代码构建（推荐）**

1. 在 macOS 项目根目录先执行 `swift scripts/create_dark_icon.swift`，生成 `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png`，再用 Xcode 16 或更新版本打开 `ParcelHelper.xcodeproj`（最低部署目标 iOS 17）。深色图标文件是构建生成物，不直接提交到 Git 仓库。
2. 选择 `ParcelHelper` scheme 和设备，在 Xcode 中为主 App 与实时活动扩展分别配置适合自己账号的签名、Bundle Identifier 和所需能力。
3. Build / Run 或使用 Xcode Archive 导出可签名版本。

**GitHub Actions 自动构建**

- 每次向 `main` 推送代码（包括合并 PR）都会自动运行 `.github/workflows/build-ipa.yml`，构建 `ParcelHelper.ipa` 并在成功后发布到 [Releases](https://github.com/O96u/ParcelHelper/releases)。也可以从 Actions 手动运行工作流。
- CI 会在编译前生成深色图标，校验它不是普通图标的原样复制，检查资产目录已声明 `luminosity: dark`，并保留编译后的资产诊断数据。iOS 18 及以上需在主屏幕长按空白处选择「编辑 → 自定义 → 深色」或「自动」才能看到相应图标；仅打开 ParcelHelper 内的深色主题不改变主屏幕图标。
- 不需要手动创建或推送 Git Tag。版本号由 Actions 自动生成，使用纯数字 `1.1.<运行序号>`（例如 `1.1.12`，无 `v` 前缀）；成功构建后会自动创建对应的 Git Tag 和 Release。失败的构建不会发布新 Release，但仍保留 Actions 日志。重新运行同一次构建会覆盖对应 Release 的 IPA。

- 文件名不含 `unsigned`，但仍须使用有效证书签名后才能安装到普通 iPhone。第三方重签名可能影响快捷指令、通知和实时活动扩展。
- 正式版本从 **v1.0.0** 起编号；后续每版根据实际提交内容生成更新日志，按需使用「新增 / 修改 / 修复 / 优化 / 移除 / 文档 / 构建与发布」等栏目，不显示没有对应改动的空栏目。Release 版本号不代表 Apple 签名或功能兼容性保证。发布时请确认 Tag 指向要发布的提交。

**主屏幕小组件签名说明：** 支持小、中、大三种桌面组件，以及在组件中标记已取；需要主 App 与嵌入式 Widget 扩展分别签名，并使用相同且被描述文件允许的 App Group。证书显示 App Groups 权限不等于已经完成共享设置，具体流程见 [小组件签名与验证](docs/widget-signing.md)。WidgetKit 读取 App 共享的本地快照，不保证锁屏或后台按固定频率联网更新。

[查看构建记录](https://github.com/O96u/ParcelHelper/actions)

> 构建流程使用 Xcode、Swift 与系统工具；**App 无需 Python、Node.js 或 Scripting 运行环境**。深色 App 图标由 `scripts/create_dark_icon.swift` 在 macOS 构建时生成。

## 版本记录

- **首个正式版**：`v1.0.0`，基准发行说明见 [docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md)。
- 日常提交建议使用 `feat:`（新增）、`fix:`（修复）、`refactor:`、`docs:` 等前缀，便于 Actions 归类到对应栏目。

## 刷新机制与数据来源

| 数据来源        | 获取方式                                      | 主要限制                                    |
| --------------- | --------------------------------------------- | ------------------------------------------- |
| 淘宝 / 京东     | 已授权 WKWebView 订单和物流页面解析           | 页面结构及安全验证变化、每轮订单数上限      |
| 菜鸟            | 淘宝会话对应的 MTOP 接口与部分轨迹补查        | 接口变化、分页及单轮详情补查数量            |
| 拼多多          | 驿站包裹接口 + 官方购物订单网页；前台自动触发网页读取，手动入口复用相同解析器 | 网页风控、账号会话互斥、iOS 后台执行限制 |
| 丰巢 / 小米聚合 | 对应登录流程与原生网络请求                    | 账号会话和接口可用性                        |
| 运单号兜底      | 支持在官方快递鸟网页登录后尝试自动导入本人 API 密钥，也可手动配置凭据查询                | 需有效 API 凭据，部分运单可能需要手机号尾号 |

「设置 → 刷新频率」配置的是 **前台自动检查的最短间隔**（默认 15 分钟）。切到后台或锁屏后，iOS **不会**保证按该间隔周期执行；在 App 内主动下拉同步可尝试即时检查。

在「账号授权 → 快递鸟」中可打开官方网页登录或注册；完成官方验证后，App 会尝试从该账号已有的 API 密钥列表读取 `EBusinessID / API Key` 并写入本机 Keychain，**不会保存登录密码或验证码**。若账号尚未创建 API 密钥、网页协议变化或获取失败，仍可使用手动配置入口。

首页身份码仅展示目前支持真实动态出码的淘宝、菜鸟、拼多多三项，改为等宽快捷卡片并提供「管理」入口；其他平台不会使用模拟二维码冒充官方身份码。

拼多多的「驿站包裹」与「购物订单」是不同数据来源：前者可返回 0 件，但不代表后者没有待收货订单。**为保护官方拼多多 App 的登录状态，新安装默认禁用拼多多网页授权及自动同步**（包含后台隐藏网页读取与原生私有接口请求）。在「账号授权 → 拼多多」中可以自行开启；点击网页授权时会明确警告可能使官方 App 退出。即便已授权，登录完成也不再立刻触发一次自动网页订单同步。关闭开关只停止 ParcelHelper 后续访问，不会恢复已被服务端注销的官方 App 登录。仍保留用户主动选择的「读取拼多多购物订单」入口。与 HandyCode 的已知情况类似，同一拼多多账号在官方 App 与网页登录时可能出现**服务器端会话互斥**；拦截网页 Deep Link、换 UA 或隔离 Cookie 均不能保证同时在线。若官方 App 登录优先，请保持此开关关闭，并使用复制取件短信、运单号等方式导入包裹。

## 项目结构

| 路径                             | 用途                                                       |
| -------------------------------- | ---------------------------------------------------------- |
| `App/`                           | SwiftUI 界面、平台授权、物流同步、短信识别、通知和快捷指令 |
| `Shared/`                        | 包裹数据模型与本地存储                                     |
| `Widget/`                        | WidgetKit 小 / 中 / 大主屏幕组件 + ActivityKit 锁屏实时活动 / 灵动岛扩展 |
| `Resources/`                     | 图标、Info.plist 和签名能力配置                            |
| `ParcelHelper.xcodeproj/`        | 已提交的 Xcode 工程                                        |
| `scripts/create_dark_icon.swift` | 构建时生成深色 App 图标                                    |
| `docs/`                          | 签名说明及图标素材来源                                     |
| `Tests/`                         | 部分解析逻辑测试                                           |

界面以 SwiftUI 为主；网页登录、剪贴板、远程请求和通知等仍会使用 WebKit、UIKit、Foundation、UserNotifications、ActivityKit 等原生 API。

## 反馈与问题

请在仓库 [Issues](https://github.com/O96u/ParcelHelper/issues) 中按模板填写：**先选「Bug 报告」或「功能建议」**，再提供环境、复现步骤与期望结果。欢迎附上可复现的物流轨迹样本，但请删除姓名、地址、手机号、Cookie、Token 和真实运单号等敏感信息。

## 隐私与免责声明

- 订单与物流只在用户授权的会话中尝试读取。第三方平台可能调整页面或接口；请遵循其使用条款及适用法律。
- App 本身不提供云端账户或 APNs 远程物流推送。通知、快捷指令和实时活动依赖本机 iOS 环境。
- 软件按现状提供，可能存在同步遗漏、物流状态误判或平台授权失效。
- 淘宝、京东、菜鸟、拼多多、丰巢、小米及快递公司名称和标识属于各自权利人；本项目不代表其官方立场。第三方图标等素材可能另受权利人许可约束。

## 开源协议

本项目源代码以 **GNU General Public License v3.0（GPL-3.0-only）** 发布，具体条款见 [LICENSE](LICENSE)。你可以在遵守 GPL-3.0 条款的前提下使用、研究、修改和再分发源代码；分发修改后的受 GPL 约束版本时，需要履行相应的源代码及许可义务。
