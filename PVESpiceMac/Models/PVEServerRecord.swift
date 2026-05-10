import Foundation

/// 持久化元数据（密码存钥匙串，不写入 UserDefaults）。
struct PVEServerRecord: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// 列表中展示的名称（用户自定义）
    var displayName: String
    /// API 根地址，例如 https://pve.lan:8006
    var baseURL: String
    var realm: String
    /// 登录名，不含 @realm（与 Realm 字段组合为 `user@realm`）
    var username: String
    /// 上次验证成功后缓存的 PVE 版本摘要（如 8.2.4）
    var cachedVersion: String?
    /// 上次验证成功后 PVE 返回的完整用户名（如 root@pam）
    var cachedAPIUsername: String?
    /// 为 true 时跳过 HTTPS 证书校验（内网自签名 / CN 与 IP 不一致等）
    var acceptUntrustedTLS: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case realm
        case username
        case cachedVersion
        case cachedAPIUsername
        case acceptUntrustedTLS
    }

    init(
        id: UUID,
        displayName: String,
        baseURL: String,
        realm: String,
        username: String,
        cachedVersion: String?,
        cachedAPIUsername: String?,
        acceptUntrustedTLS: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.realm = realm
        self.username = username
        self.cachedVersion = cachedVersion
        self.cachedAPIUsername = cachedAPIUsername
        self.acceptUntrustedTLS = acceptUntrustedTLS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        realm = try c.decode(String.self, forKey: .realm)
        username = try c.decode(String.self, forKey: .username)
        cachedVersion = try c.decodeIfPresent(String.self, forKey: .cachedVersion)
        cachedAPIUsername = try c.decodeIfPresent(String.self, forKey: .cachedAPIUsername)
        acceptUntrustedTLS = try c.decodeIfPresent(Bool.self, forKey: .acceptUntrustedTLS) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(realm, forKey: .realm)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(cachedVersion, forKey: .cachedVersion)
        try c.encodeIfPresent(cachedAPIUsername, forKey: .cachedAPIUsername)
        try c.encode(acceptUntrustedTLS, forKey: .acceptUntrustedTLS)
    }

    var loginUserAtRealm: String {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.contains("@") { return u }
        let r = realm.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(u)@\(r)"
    }

    var listSubtitle: String {
        let user = loginUserAtRealm
        if let ver = cachedVersion, !ver.isEmpty {
            return "用户 \(user) · 版本 \(ver)"
        }
        return "用户 \(user)"
    }
}
