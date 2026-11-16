# 115 直连协议笔记

> 用于 `115-pan-local`（免服务器版）。来源：p115client / p115cipher / AList，仅作个人客户端实现参考。

## 1. 扫码登录

| 步骤 | 请求 |
|---|---|
| 申请二维码 | `GET https://qrcodeapi.115.com/api/1.0/web/1.0/token` → `{data:{uid, time, sign, qrcode}}` |
| 二维码图片 | `GET https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?uid=<uid>`（也可自己把 `qrcode` 内容渲染成二维码） |
| 轮询状态 | `GET https://qrcodeapi.115.com/get/status/?uid=<uid>&time=<time>&sign=<sign>` → `data.status`：0 未扫、1 已扫、2 已确认、3 过期、4 取消、5 失败 |
| 换取 Cookie | `POST https://qrcodeapi.115.com/app/1.0/web/1.0/login/qrcode/`（带 uid）→ `data.cookie` |

拿到的 Cookie 形如 `UID=...; CID=...; SEID=...; KID=...`，之后所有 webapi 请求带这个 Cookie 头即可。

注意事项：

- 风控：同一 IP 频繁登录可能报「IP 登录异常」，尤其 `app=web`；可用 `app=alipaymini`/`os_windows` 等分支降低概率（p115client 有实现）。
- Cookie 有效期较长，但改密码/多地登录会失效，需要重新扫码。

## 2. 目录接口

```
GET https://webapi.115.com/files?aid=1&cid=<cid>&offset=0&limit=1000&show_dir=1&natsort=1
Cookie: UID=...; CID=...; SEID=...; KID=...
```

返回 `data[]`：

- `fid` / `cid`（目录是 `cid`，文件是 `fid`）
- `n` 名称、`s` 大小、`pc` pickcode、`sha`（目录为空）、`ico` 类型

## 3. 直链解析（重点）

网页下载接口 `webapi.115.com/files/download?pickcode=` 对大文件会返回 `50028 文件大小超出限制，请使用115电脑端下载`，必须用客户端接口：

```
POST https://proapi.115.com/2.0/ufile/downurl?app=os_windows&k_ec=<k_ec>
Content-Type: application/x-www-form-urlencoded
Cookie: ...

<AES-128-CBC 加密的 "urlencoded(payload)&">
```

- payload：`pickcode=<pc>&user_id=<uid>`
- 响应：`AES-128-CBC 解密` → `LZ4 解压` → JSON，`data[<fid>].url.url` 即直链

### 固定密钥（来自 p115cipher）

```
AES_KEY = fb1a19d652f5aaf7bc651d0f69bf422f   (16 bytes)
AES_IV  = 69bf422f49960550a0ad44ec3446cb4c   (16 bytes)
k_ec    = HQMOgKF43O7OzaN33hKNAHMAAAAAAAAAjtndz1WuYe1G6hIaHPyBAAEAAAAMfvVI
```

- AES-CBC + PKCS#7 padding，iOS 用 `CCCrypt`（CommonCrypto）即可
- LZ4 不是标准帧格式：每块前 2 字节小端长度，逐块解压（p115cipher `lz4_decompress`），Swift 写一个 block 解码器约 80 行
- 直链的 `f` 参数决定是否要求 UA / Cookie；用同一个 UA 解析与播放最稳

## 4. 播放

- 直链 → VLC（MobileVLCKit）：`VLCMedia(url:)` + `:http-user-agent`
- 或服务端 302 模式（旧仓库做法）

## 参考

- p115client（Python，GPLv3）
- p115cipher（Python，GPLv3）
- AlistGo/alist `drivers/115`
