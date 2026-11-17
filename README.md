# 115 云下载 · Local（免服务器版）

在 iPhone 上扫码登录 115，**直连 115 服务器**浏览网盘、解析直链并播放，不需要任何后端服务器。

> 最新版本：**v1.6** —— [下载 Release](https://github.com/112179/115-pan-local/releases/latest)

## 功能

- **扫码登录**：App 内调用 `qrcodeapi.115.com`，Cookie 存 Keychain
- **云盘浏览**：目录分页、搜索、筛选、文件管理（重命名 / 移动 / 删除 / 新建文件夹）
- **直链播放**：App 内完成 AES-128-CBC + RSA + LZ4 解析，不经过第三方
- **播放器（v1.6 起换用 AetherEngine）**
  - FFmpeg 解封装 + VideoToolbox 硬解 + AVPlayer 出画，Apple 不支持的编码走 dav1d / libavcodec
  - HDR10 / HDR10+ / HLG / 杜比视界走原生通路
  - SRT / ASS / PGS 字幕自绘（描边、颜色、ASS 定位）
  - 手势：单击显隐、双击快进/暂停、横向拖动进度、长按倍速
  - 进度条带缓冲区间、拖动跟手不回弹、实时网速、分段加载动画
  - 音轨 / 字幕切换、倍速（0.5×–2×）、断点续播、横竖屏
- **云下载任务**：列表 / 暂停 / 继续 / 重下 / 删除 / 新建 magnet

## 系统要求

- iOS 18.0+（AetherEngine 的硬性要求）

## 安装

Release 里是**未签名 IPA**，需要自行签名：

- Windows：Sideloadly + 免费 Apple ID（7 天有效）
- 或者 AltStore / SideStore / 自签工具

```bash
shasum -a 256 Pan115Local-1.6-unsigned.ipa
```

## 构建

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述，CI 在 GitHub Actions 上跑：

```bash
xcodegen generate
xcodebuild -project Pan115Local.xcodeproj -scheme Pan115Local \
  -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

- Runner：`xcode-27`（AetherEngine 需要 Xcode 27）
- 依赖：`AetherEngine 7.68+`、`BigInt`（SPM）
- 产物：未签名 IPA（约 9.5 MB）

## 与 `115-pan-ios` 的关系

| | 115-pan-ios | 本仓库（Local） |
|---|---|---|
| 架构 | 薄客户端 + 自建 FastAPI | 纯客户端 |
| 登录 | 服务端持有 Cookie（也支持 App 内扫码） | App 内扫码，Cookie 存 Keychain |
| 直链 | 服务端 `p115client` 解析 | App 内直接解析 |
| 依赖 | 需要一台服务器 | 无 |

## 技术要点

见 [docs/115-protocol.md](docs/115-protocol.md)：115 的直链接口使用**固定密钥 AES-128-CBC + LZ4**，不需要 ECC/RSA，Swift 用 CommonCrypto 即可实现；扫码登录走公开的 `qrcodeapi`。

## 免责声明

个人自用工具。接口来自 115 网页/客户端协议，可能随官方更新失效；请仅用于访问自己的账号与文件，不要用于分发或商业用途。
