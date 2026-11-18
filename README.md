<div align="center">

<img src="./Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="ParcelHelper App 图标" width="112" height="112" />

# ParcelHelper

**让快递管理更简单**

面向 iPhone 的轻量级包裹与取件管理工具

**快递聚合 · 物流追踪 · 取件码管理 · 灵动岛 · 本地提醒**

[![release](https://img.shields.io/github/v/release/O96u/ParcelHelper?label=release&color=0089d6)](https://github.com/O96u/ParcelHelper/releases)
![version](https://img.shields.io/badge/version-1.0.0-0089d6)
![platform](https://img.shields.io/badge/平台-iOS%2017%2B-27ae60)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-f05138)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-3b82f6)
[![license](https://img.shields.io/badge/license-GPL--3.0-0089d6)](LICENSE)

</div>

---

## 简介

**ParcelHelper** 是一款以 **Swift + SwiftUI** 为基础的开源 iOS 包裹管理项目，旨在把不同平台的运单、物流轨迹、驿站取件码和取件提醒集中在同一个界面。

项目借鉴了 Scripting 版「包裹助手」的部分交互和实现思路，以原生 iOS 架构重新开发。它是独立的第三方开源项目，不隶属于菜鸟、淘宝、京东或任何快递公司。

## 主要功能

| 模块 | 功能说明 |
| --- | --- |
| 📦 包裹管理 | 管理运输中、待取件、已签收、已取件的快递及取件码 |
| 🚚 物流轨迹 | 查看运单号、快递公司、最新轨迹和完整物流节点 |
| 🔗 平台同步 | 在用户授权的前提下，尝试读取淘宝、京东、菜鸟、拼多多等平台的物流信息 |
| 📋 智能识别 | 识别复制的短信、取件码及物流文字，支持手动核对 |
| 🏪 驿站管理 | 整理取件地点、驿站及包裹归属 |
| 📊 数据统计 | 查看取件趋势与包裹统计 |
| 🔔 物流提醒 | 在 App 同步发现物流状态变化后发送本地通知 |
| 📱 灵动岛 | 使用 ActivityKit 展示待取件信息和锁屏实时活动 |

部分平台同步依赖网页登录会话和非公开接口，可能因平台调整、安全验证或登录失效而中断。物流通知不是云端 24 小时实时推送；设备被 iOS 挂起后不能保证定时查询。

## 安装与构建

项目面向 **iOS 17 或更新版本**，使用 Xcode 和 Swift 开发。源代码就绪后，可在 macOS 上用 Xcode 打开 `ParcelHelper.xcodeproj`，为 App 及实时活动扩展配置合法签名并构建。

安装包统一命名为 `ParcelHelper.ipa`。**文件名不包含 unsigned，不代表安装包已签名**；通过 GitHub Actions 构建的未签名版本仍需自行签名。

[查看 Releases](https://github.com/O96u/ParcelHelper/releases) · [查看构建记录](https://github.com/O96u/ParcelHelper/actions)

## 版本记录

从 **v1.0.0** 开始建立正式版本序列。每个 Release 按以下栏目记录具体变化：

- **新增**：本次加入的功能与能力
- **修改**：已有功能、界面及体验调整
- **修复**：Bug、兼容性及数据识别问题

正式发布前请检查构建结果、实际签名权限和真机表现。

## 技术栈

`Swift` · `SwiftUI` · `Foundation` · `WebKit` · `ActivityKit` · `AppIntents` · `UserNotifications` · `Xcode`

应用界面采用 SwiftUI，平台登录网页、通知、快捷指令和实时活动等能力由必要的苹果系统框架实现，不需要 Python 运行环境。

## 隐私与说明

包裹内容默认保存在应用本地沙盒中。平台登录状态、运单号、地址及取件码属于敏感信息，请勿在 Issue 中公开真实账号、Cookie、Token、手机号、完整地址或真实取件码。

本项目并非任何电商、快递平台的官方客户端。相关平台名称、商标和图标归各自权利人所有，第三方素材不因本项目源代码使用 GPL 而自动获得 GPL 授权。

## 开源协议

本项目代码使用 **[GNU General Public License v3.0](LICENSE)** 开源。使用、修改及再分发时请遵守对应许可证条款。

欢迎通过 [Issues](https://github.com/O96u/ParcelHelper/issues) 提交问题与建议。

---
<div align="center"><sub>ParcelHelper · Made with SwiftUI for iOS</sub></div>
