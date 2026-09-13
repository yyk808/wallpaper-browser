# Wallpaper Browser

一个用于浏览 Wallpaper Engine 创意工坊壁纸并提取下载视频壁纸的 macOS 应用。

## 功能

- 浏览、搜索、排序 Wallpaper Engine 创意工坊内容
- 点击详情中的作者查看其作品、头像与 Steam 主页，支持最新发布／最高评分排序
- 搜索框粘贴作品 ID、作品／合集／作者链接后按回车直接打开
- 浏览合集、查看收录某张壁纸的合集，分批加载成员并勾选视频加入下载队列
- 收藏常用合集与作者并从侧边栏快速打开，收藏信息会在本地持久保存
- 详情独立加载全文、发布时间、更新时间、浏览与收藏人数，支持附加图片及外部视频预览
- 点击详情标签继续浏览，支持最近更新、最多好评、尚未评分等排序；搜索保留所选排序
- 浏览、作者与合集支持所有壁纸类型；过滤器可选 Scene／Video／Web／Application，浏览页自动保存已应用的筛选条件
- 目前仅视频作品支持提取下载，其他类型可查看详情及 Steam 页面
- 按内容分级、分辨率和题材筛选，支持包含或排除特定题材
- 浏览位置按筛选、排序和搜索条件分别缓存；近期热门、最新发布、最近更新和未评分重新进入时从首屏加载，详情返回保留位置
- 点击右下角条目计数可按序号跳转；`scripts/check-browse-jump.sh` 验证跳转、位置恢复与分页边界
- 自动检测 Homebrew 或手动安装的 SteamCMD
- 支持 Steam 密码、Steam Guard 和缓存会话登录
- 串行下载，避免多个 SteamCMD 进程互相干扰
- 实时显示 SteamCMD 下载进度、阶段和下载速度
- 下载完成后只以可用视频文件为成功标准；`project.json` 缺失或损坏时会自动查找主要视频，预览图等附属文件出错不影响提取
- 保留 Steam 创意工坊源文件以避免缓存清单失效；检测到确切的缺失源文件记录时会备份并修复缓存状态，然后自动重试一次
- 下载列表可从标题、详情按钮或右键菜单打开壁纸详情，并支持多选、空格快速查看、移到废纸篓及在 Finder 中定位文件
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

## 接口验证

```bash
./scripts/check-workshop-api.sh
# 可选：使用钥匙串中现有的 Steam Web API Key 进行只读联网验证
./scripts/check-workshop-api.sh --live
```

离线检查覆盖链接解析、旧下载元数据兼容、收藏持久化、视频优先提取、创意工坊缓存恢复、详情与预览解析、合集顺序、过滤后分页和错误处理。
联网检查覆盖搜索、作者作品／资料、作品详情、反查合集和批量读取合集成员，不执行下载或 Steam 账号写操作。

## 许可证

本项目采用 [GNU Affero General Public License v3.0](LICENSE)，对应 SPDX 标识为 `AGPL-3.0-only`。

本项目是非官方工具，与 Valve、Steam 或 Wallpaper Engine 的开发商无隶属或认可关系。Steam、Wallpaper Engine 及相关商标归各自权利人所有。用户应遵守 Steam 订户协议和创意工坊内容的相关许可条款。
