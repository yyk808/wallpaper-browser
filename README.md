# Wallpaper Browser

一个专注于浏览和下载 Wallpaper Engine 创意工坊视频壁纸的 macOS 应用。

## 功能

- 浏览、搜索、排序 Wallpaper Engine 创意工坊内容
- 只请求并显示 `Video` 类型壁纸
- 按内容分级、分辨率和题材筛选
- 自动检测 Homebrew 或手动安装的 SteamCMD
- 支持 Steam 密码、Steam Guard 和缓存会话登录
- 串行下载，避免多个 SteamCMD 进程互相干扰
- 下载后解析 `project.json`，仅提取主视频文件
- 在应用内管理下载状态，并可在 Finder 中定位文件

## 系统要求

- macOS 14 或更高版本
- Xcode 26 或兼容的 SwiftUI 工具链
- SteamCMD
- 拥有 Wallpaper Engine 的 Steam 账户
- Steam Web API Key

## 使用

1. 使用 Xcode 打开 `wallpaper-browser.xcodeproj` 并运行应用。
2. 在“设置”中填写 [Steam Web API Key](https://steamcommunity.com/dev/apikey)。
3. 安装 SteamCMD，或在应用中选择现有的 `steamcmd`/`steamcmd.sh`。
4. 登录拥有 Wallpaper Engine 的 Steam 账户。
5. 在创意工坊中选择壁纸并下载。

视频默认保存到：

```text
~/Movies/Wallpaper Browser/
```

可在设置中修改保存目录。

## 构建

```bash
xcodebuild \
  -project wallpaper-browser.xcodeproj \
  -scheme wallpaper-browser \
  -configuration Debug \
  build
```

应用需要执行外部 SteamCMD，因此项目未启用 App Sandbox。正式分发时应使用 Developer ID 签名并完成 Apple 公证。
