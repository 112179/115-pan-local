import Foundation
import Security

enum Keychain {
    private static let service = "com.minis.pan115local"

    static func save(_ value: String, key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var cookie: String

    init() {
        let saved = Keychain.read("cookie115") ?? ""
        // `_A1_` 是 web 分支的会话，直链接口会返回 errno 99；
        // 需要重新用 alipaymini 分支扫码（`UID=…_R2_…`）。
        if saved.contains("UID="), saved.contains("_A1_") {
            cookie = ""
            Keychain.delete("cookie115")
            UserDefaults.standard.set(true, forKey: "needsReloginHint")
        } else {
            cookie = saved
        }
    }

    var isLoggedIn: Bool { !cookie.isEmpty }

    var api: API115 { API115(cookie: cookie) }

    var accountName: String {
        let uid = api.userId
        return uid.isEmpty ? "已登录" : "UID \(uid)"
    }

    /// 只用于诊断，不泄露具体值
    var cookieKeys: String {
        cookie.split(separator: ";").compactMap { piece in
            piece.split(separator: "=", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }.joined(separator: ",")
    }

    var uidSuffix: String {
        for piece in cookie.split(separator: ";") {
            let text = piece.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("UID="), let underscore = text.firstIndex(of: "_") {
                return String(text[underscore...])
            }
        }
        return "无"
    }

    func save(cookie: String) {
        self.cookie = cookie
        Keychain.save(cookie, key: "cookie115")
    }

    func logout() {
        cookie = ""
        Keychain.delete("cookie115")
    }
}
