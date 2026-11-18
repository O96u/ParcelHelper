# 包裹助手 · 第三方签名兼容说明

从移除桌面小组件的版本开始，工程只保留 **ActivityKit 锁屏实时活动 / 灵动岛**，不再注册普通桌面 Widget。

## 签名结构

- 主 App：`com.muxui.ParcelHelper`
- 实时活动扩展：`com.muxui.ParcelHelper.widget`（Bundle ID 保持兼容，不再提供桌面小组件）
- 两个 entitlements 文件均不再请求 `com.apple.security.application-groups`
- 仍需对主 App 和扩展分别签名，且描述文件要允许对应 Bundle ID
- 实时活动必须由 iOS 及所用签名方式允许；不是远程推送权限的替代物

## 数据存储

包裹数据存于主 App 的 Documents 目录，ActivityKit 直接把有限的状态信息
传给扩展。因此不再要求两个沙盒读取同一个 App Group 容器。已有用户的本地数据格式保持不变。

iOS 可能限制实时活动的持续时间和刷新频率；后台不保证定时刷新。打开主 App，
或在设置 → 实时活动中点「立即更新灵动岛」，即可请求更新状态。

如果之前已经在桌面添加过旧版小组件，升级后请手动移除该旧小组件，
避免 iOS 保留失效的旧视图。
