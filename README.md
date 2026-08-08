# Wallpaper Browser

一个专注于浏览和下载 Wallpaper Engine 创意工坊视频壁纸的 macOS 应用。

## 功能

- 浏览、搜索、排序 Wallpaper Engine 创意工坊内容
- 只请求并显示 `Video` 类型壁纸
- 按内容分级、分辨率和题材筛选，支持包含或排除特定题材
- 自动检测 Homebrew 或手动安装的 SteamCMD
- 支持 Steam 密码、Steam Guard 和缓存会话登录
- 串行下载，避免多个 SteamCMD 进程互相干扰
- 实时显示 SteamCMD 下载进度、阶段和下载速度
- 下载后解析 `project.json`，仅提取主视频文件
- 下载列表支持多选、空格快速查看、移到废纸篓，并可在 Finder 中定位文件
- 封面使用可配置上限的磁盘缓存，设置中可查看容量并手动清空
- 下载作品 ID 独立保存在应用元数据中，不随封面缓存清理

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

Steam Web API Key 保存在 macOS 钥匙串中。Steam 密码和 Steam Guard 验证码仅通过标准输入传递给 SteamCMD，应用不会保存这些登录凭据。

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

### 构建未签名发布包

开源项目可以先发布未签名的 Universal zip，不需要 Apple Developer 证书：

```bash
./scripts/build-unsigned.sh
```

产物会写入 `dist/WallpaperBrowser-<版本>-universal-unsigned.zip`。用户解压后第一次启动时，需要在 Finder 中右键应用并选择“打开”，再确认打开；也可以在终端移除下载隔离标记：

```bash
xattr -dr com.apple.quarantine "/Applications/wallpaper-browser.app"
```

未签名包适合 GitHub Release 测试分发，但不会通过 macOS Gatekeeper 的开发者验证。

## 许可证

本项目采用 [GNU Affero General Public License v3.0](LICENSE)，对应 SPDX 标识为 `AGPL-3.0-only`。

本项目是非官方工具，与 Valve、Steam 或 Wallpaper Engine 的开发商无隶属或认可关系。Steam、Wallpaper Engine 及相关商标归各自权利人所有。用户应遵守 Steam 订户协议和创意工坊内容的相关许可条款。
