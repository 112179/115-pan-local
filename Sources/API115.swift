import Foundation

struct QRToken: Decodable {
    let uid: String
    let time: Int
    let sign: String
    let qrcode: String
}

struct DirectFile: Identifiable, Decodable {
    let id: String
    let name: String
    let isDir: Bool
    let size: Int64
    let pickcode: String
    let icon: String

    var isVideo: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "avi", "mov", "m4v", "ts", "m2ts", "webm", "flv", "wmv",
                "rmvb", "rm", "mpg", "mpeg", "3gp", "m3u8"].contains(ext)
    }
}

struct DirectTask: Identifiable {
    let id: String
    let hash: String
    let name: String
    let percent: Double
    let status: Int
    let size: Int64
    let addTime: Int
}

enum API115Error: LocalizedError {
    case message(String)
    case http(Int)
    case data(String)

    var errorDescription: String? {
        switch self {
        case .message(let text), .data(let text): return text
        case .http(let code): return "服务器返回 HTTP \(code)"
        }
    }
}

/// 115 直连客户端（无自建服务器）
struct API115 {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    static let kEC = "HQMOgKF43O7OzaN33hKNAHMAAAAAAAAAjtndz1WuYe1G6hIaHPyBAAEAAAAMfvVI"

    let cookie: String

    init(cookie: String) {
        // 注意：UID 的后缀（如 `_A1_xxxxxxxx`）是 115 会话标识的一部分，
        // 不能改写，否则整个会话失效（990001）。只有请求体里的 user_id 用数字前缀。
        self.cookie = cookie
    }

    // MARK: - 基础请求

    private func request(_ url: URL,
                         method: String = "GET",
                         body: [UInt8]? = nil,
                         contentType: String = "application/x-www-form-urlencoded",
                         cookie overrideCookie: String? = nil,
                         userAgent: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        let cookieValue = overrideCookie ?? cookie
        if !cookieValue.isEmpty {
            req.setValue(cookieValue, forHTTPHeaderField: "Cookie")
        }
        req.setValue(userAgent ?? API115.userAgent, forHTTPHeaderField: "User-Agent")
        if let scheme = url.scheme, let host = url.host {
            req.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Referer")
        }
        if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw API115Error.data("没有收到服务器响应")
        }
        return (data, http)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw API115Error.data("返回数据格式异常")
        }
        return obj
    }

    private func checkState(_ obj: [String: Any]) throws -> [String: Any] {
        if let state = obj["state"] as? Bool, state == false {
            throw API115Error.message(failureText(obj))
        }
        if let state = obj["state"] as? Int, state == 0 {
            throw API115Error.message(failureText(obj))
        }
        return obj
    }

    private func failureText(_ obj: [String: Any]) -> String {
        if let text = obj["message"] as? String, !text.isEmpty { return text }
        if let text = obj["msg"] as? String, !text.isEmpty { return text }
        if let text = obj["error_msg"] as? String, !text.isEmpty { return text }
        if let text = obj["error"] as? String, !text.isEmpty { return text }
        let errno = (obj["errno"] as? NSNumber)?.intValue ?? 0
        return errno == 0 ? "115 返回失败" : "115 返回失败（errno \(errno)）"
    }

    // MARK: - 扫码登录

    static func qrToken() async throws -> QRToken {
        var comp = URLComponents(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token/")!
        comp.query = nil
        let (data, http) = try await API115(cookie: "").request(comp.url!, userAgent: userAgent)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        let obj = try API115(cookie: "").json(data)
        guard let payload = obj["data"] as? [String: Any],
              let uid = payload["uid"] as? String,
              let time = payload["time"] as? Int,
              let sign = payload["sign"] as? String,
              let qrcode = payload["qrcode"] as? String else {
            throw API115Error.data("二维码数据异常")
        }
        return QRToken(uid: uid, time: time, sign: sign, qrcode: qrcode)
    }

    static func qrStatus(_ token: QRToken) async throws -> Int {
        var comp = URLComponents(string: "https://qrcodeapi.115.com/get/status/")!
        comp.queryItems = [
            URLQueryItem(name: "uid", value: token.uid),
            URLQueryItem(name: "time", value: String(token.time)),
            URLQueryItem(name: "sign", value: token.sign),
        ]
        let (data, _) = try await API115(cookie: "").request(comp.url!, userAgent: userAgent)
        let obj = try API115(cookie: "").json(data)
        guard let payload = obj["data"] as? [String: Any] else { return 0 }
        if let status = payload["status"] as? Int { return status }
        if let status = payload["status"] as? String, let value = Int(status) { return value }
        return 0
    }

    static func qrLogin(uid: String) async throws -> String {
        var comp = URLComponents(string: "https://qrcodeapi.115.com/app/1.0/alipaymini/1.0/login/qrcode/")!
        comp.query = nil
        let body = Array("account=\(uid)".utf8)
        let (data, http) = try await API115(cookie: "").request(comp.url!,
                                                               method: "POST",
                                                               body: body,
                                                               userAgent: userAgent)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        let obj = try API115(cookie: "").json(data)
        guard let payload = obj["data"] as? [String: Any],
              let cookie = payload["cookie"] as? [String: Any] else {
            let message = (obj["message"] as? String) ?? (obj["msg"] as? String) ?? "登录失败"
            throw API115Error.message(message)
        }
        let ordered = ["UID", "CID", "SEID", "KID"]
        var parts: [String] = []
        for key in ordered {
            if let value = cookie[key] as? String { parts.append("\(key)=\(value)") }
        }
        for (key, value) in cookie where !ordered.contains(key) {
            if let text = value as? String { parts.append("\(key)=\(text)") }
        }
        guard !parts.isEmpty else { throw API115Error.data("没有拿到登录 Cookie") }
        return parts.joined(separator: "; ")
    }

    // MARK: - 目录

    /// 115 的 UID 可能是 `<数字>_<会话标识>` 的形式，请求体里要取纯数字前缀
    var userId: String {
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "UID" {
                return pair[1].split(separator: "_").first.map(String.init) ?? pair[1]
            }
        }
        return ""
    }

    func files(cid: String = "0", offset: Int = 0, limit: Int = 100) async throws -> (items: [DirectFile], total: Int) {
        var comp = URLComponents(string: "https://webapi.115.com/files")!
        comp.queryItems = [
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "show_dir", value: "1"),
            URLQueryItem(name: "natsort", value: "1"),
        ]
        let (data, http) = try await request(comp.url!)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        let obj = try checkState(json(data))
        let list = (obj["data"] as? [[String: Any]]) ?? []
        let total = (obj["count"] as? NSNumber)?.intValue ?? list.count
        return (parseFiles(list), total)
    }

    func search(keyword: String, cid: String = "0", offset: Int = 0, limit: Int = 100) async throws -> [DirectFile] {
        var comp = URLComponents(string: "https://webapi.115.com/files/search")!
        comp.queryItems = [
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "search_value", value: keyword),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let (data, http) = try await request(comp.url!)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        let obj = try checkState(json(data))
        let list = (obj["data"] as? [[String: Any]]) ?? []
        return parseFiles(list)
    }

    private func parseFiles(_ list: [[String: Any]]) -> [DirectFile] {
        var items: [DirectFile] = []
        for raw in list {
            let fid = (raw["fid"] as? String) ?? (raw["fid"] as? Int).map(String.init) ?? ""
            let cidValue = (raw["cid"] as? String) ?? (raw["cid"] as? Int).map(String.init) ?? ""
            let id = fid.isEmpty ? cidValue : fid
            let name = (raw["n"] as? String) ?? (raw["name"] as? String) ?? ""
            let sha = (raw["sha"] as? String) ?? ""
            let size = (raw["s"] as? NSNumber)?.int64Value ?? 0
            let pickcode = (raw["pc"] as? String) ?? (raw["pick_code"] as? String) ?? ""
            let icon = (raw["ico"] as? String) ?? ""
            guard !id.isEmpty, !name.isEmpty else { continue }
            items.append(DirectFile(id: id,
                                    name: name,
                                    isDir: sha.isEmpty,
                                    size: size,
                                    pickcode: pickcode,
                                    icon: icon))
        }
        return items
    }

    // MARK: - 离线下载任务

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func tasks(page: Int = 1, stat: Int = 12) async throws -> [DirectTask] {
        var comp = URLComponents(string: "https://clouddownload.115.com/web/")!
        comp.queryItems = [
            URLQueryItem(name: "ac", value: "task_lists"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: "50"),
            URLQueryItem(name: "stat", value: String(stat)),
        ]
        let (data, http) = try await request(comp.url!)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        let obj = try checkState(json(data))

        var list = (obj["data"] as? [[String: Any]]) ?? (obj["tasks"] as? [[String: Any]]) ?? []
        if list.isEmpty, let nested = obj["data"] as? [String: Any] {
            list = (nested["tasks"] as? [[String: Any]]) ?? []
        }

        var result: [DirectTask] = []
        for raw in list {
            let hash = (raw["info_hash"] as? String)
                ?? (raw["infoHash"] as? String)
                ?? (raw["hash"] as? String)
                ?? ""
            let name = (raw["name"] as? String) ?? ""
            let percent = (raw["percentDone"] as? NSNumber)?.doubleValue
                ?? (raw["percent"] as? NSNumber)?.doubleValue
                ?? 0
            let status = (raw["status"] as? NSNumber)?.intValue
                ?? (raw["status"] as? String).flatMap(Int.init)
                ?? 0
            let size = (raw["size"] as? NSNumber)?.int64Value ?? 0
            let addTime = (raw["add_time"] as? NSNumber)?.intValue ?? 0
            guard !hash.isEmpty || !name.isEmpty else { continue }
            result.append(DirectTask(id: hash.isEmpty ? name : hash,
                                     hash: hash,
                                     name: name.isEmpty ? hash : name,
                                     percent: min(max(percent, 0), 100),
                                     status: status,
                                     size: size,
                                     addTime: addTime))
        }
        return result
    }

    func taskAction(hash: String, action: String) async throws {
        let map = ["pause": "pause_task",
                   "resume": "resume_task",
                   "restart": "restart_task",
                   "del": "task_del"]
        guard let ac = map[action] else { return }

        var form = "ac=" + ac
        if !hash.isEmpty { form += "&info_hash=" + formEncode(hash) }
        if action == "del" { form += "&del_source=0" }

        let (data, http) = try await request(URL(string: "https://clouddownload.115.com/web/")!,
                                             method: "POST",
                                             body: Array(form.utf8))
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        _ = try checkState(json(data))
    }

    @discardableResult
    func addTask(url: String, cid: String) async throws -> String {
        // lixianssp 接口要求：data = base64(rsaEncrypt(json))，并用 115 客户端 UA
        let appVer = "36.2.28"
        let payload: [String: Any] = [
            "ac": "add_task_url",
            "url": url,
            "wp_path_id": cid,
            "app_ver": appVer,
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw API115Error.data("构造请求失败")
        }
        let encrypted = Cipher115.rsaEncrypt(Array(payloadData))
        let body = Array(("data=" + formEncode(encrypted)).utf8)
        let clientUA = "Mozilla/5.0 115disk/\(appVer) 115Browser/\(appVer) 115wangpan_android/\(appVer)"

        let (data, http) = try await request(URL(string: "https://clouddownload.115.com/lixianssp/")!,
                                             method: "POST",
                                             body: body,
                                             userAgent: clientUA)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }

        var obj: [String: Any]
        do {
            obj = try json(data)
        } catch {
            throw API115Error.data("新建任务响应异常（HTTP \(http.statusCode)，\(data.count) 字节，开头 \(Array(data.prefix(6)).hex)）")
        }

        if let inner = obj["data"] as? String,
           let decrypted = Cipher115.rsaDecrypt(inner),
           let innerObj = try? json(Data(decrypted)) {
            obj = innerObj
            if let nested = obj["data"] as? [String: Any] {
                obj = nested
            }
        }

        _ = try checkState(obj)
        if let message = obj["message"] as? String, !message.isEmpty { return message }
        if let message = obj["msg"] as? String, !message.isEmpty { return message }
        return "已提交下载"
    }

    // MARK: - 文件管理

    private func postForm(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        let body = params
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
        let (data, http) = try await request(URL(string: url)!,
                                             method: "POST",
                                             body: Array(body.utf8))
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }
        return try checkState(json(data))
    }

    func rename(id: String, name: String) async throws {
        _ = try await postForm("https://webapi.115.com/files/batch_rename",
                               ["files_new_name[\(id)]": name])
    }

    func move(id: String, to cid: String) async throws {
        _ = try await postForm("https://webapi.115.com/files/move",
                               ["fid": id, "pid": cid])
    }

    func delete(id: String) async throws {
        _ = try await postForm("https://webapi.115.com/rb/delete",
                               ["fid": id])
    }

    func mkdir(name: String, pid: String) async throws {
        _ = try await postForm("https://webapi.115.com/files/add",
                               ["cname": name, "pid": pid])
    }

    // MARK: - 直链

    func downloadURL(pickcode: String) async throws -> URL {
        let uid = userId
        guard !uid.isEmpty else { throw API115Error.data("登录态里没有 UID") }

        var payload: [String: Any] = ["pickcode": pickcode]
        if let value = Int(uid) {
            payload["user_id"] = value
        } else {
            payload["user_id"] = uid
        }
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw API115Error.data("构造请求失败")
        }
        let base64 = Cipher115.rsaEncrypt(Array(payloadData))
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
        let inner = "data=" + encoded
        let body = Cipher115.encryptBody(inner)

        var comp = URLComponents(string: "https://proapi.115.com/os_windows/2.0/ufile/downurl")!
        comp.queryItems = [URLQueryItem(name: "k_ec", value: API115.kEC)]
        // 直链会绑定解析时的 UA：这里必须和 VLC 播放时发送的 UA 完全一致
        let (data, http) = try await request(comp.url!,
                                             method: "POST",
                                             body: body,
                                             userAgent: API115.userAgent)
        guard http.statusCode == 200 else { throw API115Error.http(http.statusCode) }

        guard let plain = Cipher115.decryptBody(Array(data)) else {
            throw API115Error.data("直链响应解密失败（HTTP \(http.statusCode)，\(data.count) 字节）")
        }
        let obj: [String: Any]
        do {
            obj = try json(Data(plain))
        } catch {
            throw API115Error.data("直链响应格式异常（HTTP \(http.statusCode)，\(plain.count) 字节，开头 \(Array(plain.prefix(6)).hex)）")
        }
        _ = try checkState(obj)

        guard let encrypted = obj["data"] as? String else {
            throw API115Error.data("没有拿到直链数据")
        }
        guard let innerData = Cipher115.rsaDecrypt(encrypted) else {
            throw API115Error.data("直链数据解密失败（\(encrypted.count) 字符）")
        }

        let innerObj: [String: Any]
        do {
            innerObj = try json(Data(innerData))
        } catch {
            throw API115Error.data("直链数据格式异常（\(innerData.count) 字节，开头 \(Array(innerData.prefix(6)).hex)）")
        }
        guard let first = innerObj.values.first as? [String: Any],
              let urlInfo = first["url"] as? [String: Any],
              let urlString = urlInfo["url"] as? String,
              let url = URL(string: urlString) else {
            throw API115Error.data("直链解析失败")
        }
        return url
    }
}
