# 115 云下载 · Local（免服务器版）

目标：像其他播放器一样，**App 内扫码登录 115，直连 115 服务器浏览和播放**，不需要 VPS / 后端。

状态：🚧 协议验证完成，开始实现。

## 与 `115-pan-ios` 的关系

| | 115-pan-ios | 本仓库（Local） |
|---|---|---|
| 架构 | 薄客户端 + 自建 FastAPI | 纯客户端 |
| 登录 | 服务端持有 Cookie（也支持 App 内扫码） | App 内扫码，Cookie 存 Keychain |
| 直链 | 服务端 `p115client` 解析 | App 内直接解析 |
| 依赖 | 需要一台服务器 | 无 |

## 计划

- [ ] App 内扫码登录（`qrcodeapi.115.com`，Cookie 存 Keychain）
- [ ] 直连列目录（`webapi.115.com/files`）
- [ ] 直链解析（`proapi.115.com/2.0/ufile/downurl?app=os_windows`，AES-128-CBC + LZ4）
- [ ] 原生浏览 + VLC 播放（复用 Pan115 的播放器、手势、设置）
- [ ] 离线下载任务列表（可选）

## 命名

- 显示名：`115 云下载 Local`
- Bundle：`com.minis.pan115local`
- 工程名：`Pan115Local`

## 技术要点

见 [docs/115-protocol.md](docs/115-protocol.md)：115 的直链接口使用**固定密钥 AES-128-CBC + LZ4**，不需要 ECC/RSA，Swift 用 CommonCrypto 即可实现；扫码登录走公开的 qrcodeapi。

> 注意：这是个人自用工具，接口来自 115 网页/客户端协议，可能随官方更新失效。
