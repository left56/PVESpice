import Foundation

/// Proxmox VE HTTP API（ticket 登录 + 版本 + 集群资源 + 单机 config）。
enum ProxmoxClient {
    struct Session: Sendable {
        let baseURL: URL
        let ticket: String
        let csrfToken: String
        let apiUsername: String
        /// 与建立会话时一致；后续请求须使用同一套 TLS 策略。
        let acceptUntrustedTLS: Bool
    }

    struct VersionInfo: Sendable {
        let version: String
        let release: String
        let repoid: String

        var displayString: String {
            if !release.isEmpty { return release }
            if !version.isEmpty { return version }
            return repoid
        }
    }

    enum APIError: LocalizedError {
        case invalidBaseURL
        case httpStatus(Int, String?)
        case proxmoxError(String)
        case decodingFailed
        case missingData

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "API 基址无效"
            case let .httpStatus(code, body):
                let tail = body.map { ": \($0)" } ?? ""
                return "HTTP \(code)\(tail)"
            case let .proxmoxError(msg):
                return msg
            case .decodingFailed:
                return "响应解析失败"
            case .missingData:
                return "服务器未返回 data 字段"
            }
        }
    }

    /// 使用用户名密码换取 ticket，并拉取 `/version`。
    static func loginAndFetchVersion(
        baseURLString: String,
        usernameAtRealm: String,
        password: String,
        acceptUntrustedTLS: Bool
    ) async throws -> (session: Session, version: VersionInfo) {
        let base = try normalizedBaseURL(baseURLString)
        let session = try await login(
            baseURL: base,
            username: usernameAtRealm,
            password: password,
            acceptUntrustedTLS: acceptUntrustedTLS
        )
        let version = try await fetchVersion(session: session)
        return (session, version)
    }

    /// SPICE 连接参数（来自 `POST .../spiceproxy` 的 `data`）。
    struct SpiceProxyInfo: Sendable {
        /// API 返回的原始 `host`（常为 `pvespiceproxy:…`）。
        let ticketHost: String
        var port: Int
        var tlsPort: Int
        let password: String
        /// 如 `http://192.168.3.211:3128`：须先连该 HTTP 代理，再对 `ticketHost:tlsPort` 发 CONNECT（与 virt-viewer 一致）。
        let httpProxy: String?
        /// PEM，可选；JSON 里常为字面 `\n` 或真实换行，`normalizeSpicePem` 会处理。
        let caPem: String?
        /// 对应 .vv 的 `host-subject`，可选。
        let hostSubject: String?

        /// 传给 `spice_bridge_connect` 的 `host`：有 HTTP 代理时必须仍为票据里的虚拟 host；无代理时用直连解析结果。
        func connectHost(resolvedDirectHost: String) -> String {
            let p = (httpProxy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { return ticketHost }
            return resolvedDirectHost
        }
    }

    /// 获取当前 VM 的 SPICE 代理票据（虚拟机需处于运行状态）。
    static func fetchSpiceProxy(session: Session, node: String, vmid: Int) async throws -> SpiceProxyInfo {
        let encNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let path = "/api2/json/nodes/\(encNode)/qemu/\(vmid)/spiceproxy"
        // 与 PrXpice 相同：POST `proxy=<当前 API 主机>`，让 PVE 在响应里把 HTTP 代理写成客户端能解析的地址；
        // 否则常见为 `http://节点短名.local:3128`，在本机 DNS/mDNS 下会 `resolve failed`。
        let data: Data
        if let apiHost = session.baseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines), !apiHost.isEmpty {
            let form = "proxy=\(apiHost)"
            data = try await postUrlEncoded(session: session, path: path, form: form)
        } else {
            data = try await postEmpty(session: session, path: path)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let d = root["data"] as? [String: Any] else {
            throw APIError.missingData
        }
        guard let host = d["host"] as? String, !host.isEmpty else {
            throw APIError.proxmoxError("spiceproxy 响应缺少 host")
        }
        guard let pw = d["password"] as? String ?? d["ticket"] as? String, !pw.isEmpty else {
            throw APIError.proxmoxError("spiceproxy 响应缺少 password/ticket")
        }
        let port = parseInt(d["port"]) ?? 0
        let tlsPort = parseInt(d["tls-port"]) ?? parseInt(d["tls_port"]) ?? 0
        if port == 0 && tlsPort == 0 {
            throw APIError.proxmoxError("spiceproxy 未返回可用端口")
        }
        let proxy = stringField(d, "proxy")
        let caRaw = stringField(d, "ca")
        let hostSubj = stringField(d, "host-subject") ?? stringField(d, "host_subject")
        return SpiceProxyInfo(
            ticketHost: host,
            port: port,
            tlsPort: tlsPort,
            password: pw,
            httpProxy: proxy,
            caPem: caRaw.map { normalizeSpicePem($0) },
            hostSubject: hostSubj
        )
    }

    // MARK: - QEMU Guest Agent（HTTP API）

    /// 通过 PVE `POST .../agent/file-write` 将字节写入来宾路径（`content` 为 Base64 时须 `encode: false`）。
    static func guestAgentFileWrite(
        session: Session,
        node: String,
        vmid: Int,
        guestPath: String,
        data: Data
    ) async throws {
        let encNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let path = "/api2/json/nodes/\(encNode)/qemu/\(vmid)/agent/file-write"
        let payload: [String: Any] = [
            "file": guestPath,
            "content": data.base64EncodedString(),
            "encode": false
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let dataResp = try await postJSON(session: session, path: path, body: body)
        guard let root = try? JSONSerialization.jsonObject(with: dataResp) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
    }

    /// `guest-exec` 仅确认「已发出」时的结果：拿到 pid，或因 PVE/HTTP 超时判定为来宾侧可能已收到指令。
    enum GuestAgentExecDispatchOutcome: Sendable, CustomStringConvertible {
        case launched(pid: Int)
        /// 常见为 PVE `got timeout` 或 URLSession 超时：不轮询 `exec-status`，假定复制已在来宾后台进行。
        case assumedLaunchedDespiteTransportTimeout

        var description: String {
            switch self {
            case let .launched(pid):
                return "launched(pid: \(pid))"
            case .assumedLaunchedDespiteTransportTimeout:
                return "assumedLaunchedDespiteTransportTimeout"
            }
        }
    }

    /// PVE / 代理层在来宾命令已派发后仍常返回超时类错误；此类错误**不代表**复制失败，不应向用户报错。
    static func errorSuggestsGuestExecLikelyDispatched(_ error: Error) -> Bool {
        if let urlErr = error as? URLError {
            if urlErr.code == .timedOut { return true }
            let ns = urlErr.localizedDescription.lowercased()
            if ns.contains("got timeout") || ns.contains("timed out") { return true }
        }
        if let apiErr = error as? APIError {
            switch apiErr {
            case let .httpStatus(code, body):
                let b = (body ?? "").lowercased()
                if b.contains("got timeout") { return true }
                if (code == 500 || code == 504), b.contains("timeout") { return true }
            case let .proxmoxError(msg):
                let m = msg.lowercased()
                if m.contains("got timeout") { return true }
            default:
                break
            }
        }
        let flat = String(describing: error).lowercased()
        if flat.contains("got timeout") { return true }
        return false
    }

    /// `POST .../agent/exec` 返回的 pid；`command` 为可执行文件及其参数（PVE 8+ 要求数组形式）。
    static func guestAgentExec(
        session: Session,
        node: String,
        vmid: Int,
        command: [String],
        requestTimeout: TimeInterval? = nil
    ) async throws -> Int {
        guard !command.isEmpty else {
            throw APIError.proxmoxError("guest exec：command 不能为空")
        }
        let encNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let path = "/api2/json/nodes/\(encNode)/qemu/\(vmid)/agent/exec"
        let payload: [String: Any] = ["command": command]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let dataResp = try await postJSON(session: session, path: path, body: body, requestTimeout: requestTimeout)
        guard let root = try? JSONSerialization.jsonObject(with: dataResp) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let d = root["data"] as? [String: Any],
              let pid = parseInt(d["pid"]), pid > 0
        else {
            throw APIError.proxmoxError("guest exec 响应缺少 pid")
        }
        return pid
    }

    /// 发射 `guest-exec` 后不调用 `exec-status`。超时类响应视为「已启动」。
    static func guestAgentExecDispatchFireAndForget(
        session: Session,
        node: String,
        vmid: Int,
        command: [String],
        requestTimeout: TimeInterval = 45
    ) async throws -> GuestAgentExecDispatchOutcome {
        do {
            let pid = try await guestAgentExec(session: session, node: node, vmid: vmid, command: command, requestTimeout: requestTimeout)
            return .launched(pid: pid)
        } catch {
            if errorSuggestsGuestExecLikelyDispatched(error) {
                return .assumedLaunchedDespiteTransportTimeout
            }
            throw error
        }
    }

    struct GuestAgentExecStatus: Sendable {
        let exited: Bool
        let exitcode: Int?
        let signal: Int?
        let outData: String?
        let errData: String?
    }

    static func guestAgentExecStatus(
        session: Session,
        node: String,
        vmid: Int,
        pid: Int
    ) async throws -> GuestAgentExecStatus {
        let encNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let path = "/api2/json/nodes/\(encNode)/qemu/\(vmid)/agent/exec-status?pid=\(pid)"
        let dataResp = try await getJSON(session: session, path: path)
        guard let root = try? JSONSerialization.jsonObject(with: dataResp) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let d = root["data"] as? [String: Any] else {
            throw APIError.missingData
        }
        let exited = d["exited"] as? Bool ?? false
        let exitcode = parseInt(d["exitcode"])
        let signal = parseInt(d["signal"])
        let outData = d["out-data"] as? String
        let errData = d["err-data"] as? String
        return GuestAgentExecStatus(
            exited: exited,
            exitcode: exitcode,
            signal: signal,
            outData: outData,
            errData: errData
        )
    }

    private static func stringField(_ d: [String: Any], _ key: String) -> String? {
        guard let s = d[key] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 将 JSON 里可能写成字面 `\n` 的 PEM 转成真实换行（若已是多行则基本无影响）。
    private static func normalizeSpicePem(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// 从 `GET /cluster/status` 解析各节点 `name` → `ip`（SPICE 端口开在运行 QEMU 的节点上，未必与 API 入口 IP 相同）。
    static func fetchClusterNodeAddressMap(session: Session) async throws -> [String: String] {
        let data = try await getJSON(session: session, path: "/api2/json/cluster/status")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let arr = root["data"] as? [[String: Any]] else {
            throw APIError.missingData
        }
        var out: [String: String] = [:]
        for item in arr {
            guard (item["type"] as? String)?.lowercased() == "node" else { continue }
            let nameRaw = (item["name"] as? String) ?? (item["node"] as? String)
            let name = nameRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let ipRaw: String?
            if let s = item["ip"] as? String {
                ipRaw = s
            } else if let n = item["ip"] as? Int {
                ipRaw = String(n)
            } else {
                ipRaw = nil
            }
            let ip = ipRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !ip.isEmpty else { continue }
            out[name] = ip
        }
        return out
    }

    /// 将 spiceproxy 里的 `host` 换成本机可 TCP 连接的目标。
    ///
    /// PVE 在经 Web 代理的会话里常返回 `pvespiceproxy:…` 这类**虚拟主机名**（给浏览器/websocket 路由用），
    /// 系统 DNS 无法解析；原生 SPICE 必须连**运行该 VM 的节点**上的 `tls-port`/`port`。
    /// `localhost` / `127.0.0.1` 同理。
    ///
    /// 若提供了 `nodeAddresses`（见 `fetchClusterNodeAddressMap`），在以上「需替换」的情形下**优先**用当前 VM 所在节点的 `ip`，
    /// 避免集群里 API 填的是 VIP/入口机而 SPICE 实际监听在另一台物理节点上（否则易出现 `ECONNREFUSED`）。
    static func resolveSpiceHost(
        spiceHost: String,
        apiBaseURL: URL,
        vmNode: String,
        nodeAddresses: [String: String]
    ) -> String {
        let trimmed = spiceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = trimmed.lowercased()
        let apiHost = apiBaseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needReplace = h.isEmpty || h == "localhost" || h == "127.0.0.1" || h.hasPrefix("pvespiceproxy")
        if needReplace {
            let nodeKey = vmNode.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mapped = lookupNodeAddress(node: nodeKey, in: nodeAddresses), !mapped.isEmpty {
                return mapped
            }
            if !apiHost.isEmpty { return apiHost }
        }
        return trimmed
    }

    private static func lookupNodeAddress(node: String, in map: [String: String]) -> String? {
        guard !node.isEmpty else { return nil }
        if let v = map[node], !v.isEmpty { return v }
        let lower = node.lowercased()
        for (k, v) in map where k.lowercased() == lower && !v.isEmpty {
            return v
        }
        return nil
    }

    /// 列出配置了 SPICE 相关显示（当前以 QXL 为准）的 QEMU 虚拟机。
    static func listSpiceQemuVMs(session: Session) async throws -> [PVEVirtualMachineRow] {
        let resources = try await fetchClusterResources(session: session, type: "vm")
        let qemuRows = resources.compactMap { ClusterResourceRow(json: $0) }.filter { $0.type == "qemu" }

        return try await withThrowingTaskGroup(of: PVEVirtualMachineRow?.self) { group in
            for row in qemuRows {
                group.addTask {
                    let config = try await fetchQemuConfig(session: session, node: row.node, vmid: row.vmid)
                    guard Self.isSpiceGraphics(config: config) else { return nil }
                    return PVEVirtualMachineRow(
                        vmid: row.vmid,
                        name: row.name,
                        node: row.node,
                        powerStatus: row.status
                    )
                }
            }
            var out: [PVEVirtualMachineRow] = []
            for try await item in group {
                if let item { out.append(item) }
            }
            out.sort { $0.vmid < $1.vmid }
            return out
        }
    }

    // MARK: - Internals

    private struct ClusterResourceRow {
        let type: String
        let vmid: Int
        let name: String
        let node: String
        let status: String

        init?(json: [String: Any]) {
            guard let type = json["type"] as? String else { return nil }
            guard let vmid = json["vmid"] as? Int ?? (json["vmid"] as? String).flatMap({ Int($0) }) else { return nil }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "VM \(vmid)"
            guard let node = json["node"] as? String else { return nil }
            let status = (json["status"] as? String) ?? "unknown"
            self.type = type
            self.vmid = vmid
            self.name = name
            self.node = node
            self.status = status
        }
    }

    /// PVE 中 SPICE 控制台通常与 QXL 显示绑定；其余显示类型暂不列入。
    static func isSpiceGraphics(config: [String: String]) -> Bool {
        guard let vga = config["vga"]?.lowercased() else { return false }
        if vga == "qxl" { return true }
        if vga.contains("qxl") { return true }
        return false
    }

    private static func normalizedBaseURL(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.invalidBaseURL
        }
        return url
    }

    private static func login(
        baseURL: URL,
        username: String,
        password: String,
        acceptUntrustedTLS: Bool
    ) async throws -> Session {
        let path = "/api2/json/access/ticket"
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidBaseURL }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        guard let form = body.percentEncodedQuery else { throw APIError.invalidBaseURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.utf8)

        let urlSession = ProxmoxURLSessionFactory.session(acceptUntrustedCertificate: acceptUntrustedTLS)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfHTTPError(resp, data: data)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(Self.normalizeAuthError(err))
        }
        guard let d = root["data"] as? [String: Any] else {
            throw APIError.missingData
        }
        guard let ticket = d["ticket"] as? String,
              let csrf = d["CSRFPreventionToken"] as? String,
              let apiUser = d["username"] as? String
        else {
            throw APIError.proxmoxError("登录响应缺少 ticket（若已开启双因素认证，当前版本尚未支持 TFA）")
        }
        return Session(
            baseURL: baseURL,
            ticket: ticket,
            csrfToken: csrf,
            apiUsername: apiUser,
            acceptUntrustedTLS: acceptUntrustedTLS
        )
    }

    private static func normalizeAuthError(_ s: String) -> String {
        let t = s.lowercased()
        if t.contains("two factor") || t.contains("2fa") || t.contains("otp") || t.contains("tfa") {
            return "该账户启用了双因素认证，当前客户端尚未支持 TFA，请改用 API Token 或稍后版本。"
        }
        return s
    }

    private static func fetchVersion(session: Session) async throws -> VersionInfo {
        let data = try await getJSON(session: session, path: "/api2/json/version")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any]
        else { throw APIError.decodingFailed }
        let version = d["version"] as? String ?? ""
        let release = d["release"] as? String ?? ""
        let repoid = d["repoid"] as? String ?? ""
        if version.isEmpty && release.isEmpty && repoid.isEmpty { throw APIError.missingData }
        return VersionInfo(version: version, release: release, repoid: repoid)
    }

    private static func fetchClusterResources(session: Session, type: String) async throws -> [[String: Any]] {
        let path = "/api2/json/cluster/resources?type=\(type)"
        let data = try await getJSON(session: session, path: path)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let arr = root["data"] as? [[String: Any]] else {
            throw APIError.missingData
        }
        return arr
    }

    private static func fetchQemuConfig(session: Session, node: String, vmid: Int) async throws -> [String: String] {
        let encNode = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        let path = "/api2/json/nodes/\(encNode)/qemu/\(vmid)/config"
        let data = try await getJSON(session: session, path: path)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed
        }
        if let err = proxmoxError(from: root) {
            throw APIError.proxmoxError(err)
        }
        guard let raw = root["data"] as? [String: Any] else {
            throw APIError.missingData
        }
        var out: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String {
                out[k] = s
            } else if let n = v as? Int {
                out[k] = String(n)
            } else if let d = v as? Double {
                out[k] = String(d)
            } else if v is NSNull {
                continue
            } else if let o = v as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: o),
                      let json = String(data: data, encoding: .utf8) {
                out[k] = json
            }
        }
        return out
    }

    private static func postEmpty(session: Session, path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: session.baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("PVEAuthCookie=\(session.ticket)", forHTTPHeaderField: "Cookie")
        req.setValue(session.csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
        req.httpBody = Data()
        let urlSession = ProxmoxURLSessionFactory.session(acceptUntrustedCertificate: session.acceptUntrustedTLS)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfHTTPError(resp, data: data)
        return data
    }

    private static func postJSON(session: Session, path: String, body: Data, requestTimeout: TimeInterval? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: session.baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("PVEAuthCookie=\(session.ticket)", forHTTPHeaderField: "Cookie")
        req.setValue(session.csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
        req.httpBody = body
        if let t = requestTimeout {
            req.timeoutInterval = t
        }
        let urlSession = ProxmoxURLSessionFactory.session(acceptUntrustedCertificate: session.acceptUntrustedTLS)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfHTTPError(resp, data: data)
        return data
    }

    private static func postUrlEncoded(session: Session, path: String, form: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: session.baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("PVEAuthCookie=\(session.ticket)", forHTTPHeaderField: "Cookie")
        req.setValue(session.csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
        req.httpBody = Data(form.utf8)
        let urlSession = ProxmoxURLSessionFactory.session(acceptUntrustedCertificate: session.acceptUntrustedTLS)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfHTTPError(resp, data: data)
        return data
    }

    private static func parseInt(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func getJSON(session: Session, path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: session.baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("PVEAuthCookie=\(session.ticket)", forHTTPHeaderField: "Cookie")
        req.setValue(session.csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
        let urlSession = ProxmoxURLSessionFactory.session(acceptUntrustedCertificate: session.acceptUntrustedTLS)
        let (data, resp) = try await urlSession.data(for: req)
        try throwIfHTTPError(resp, data: data)
        return data
    }

    private static func throwIfHTTPError(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200 ..< 300).contains(http.statusCode) else { return }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = proxmoxError(from: root) {
            throw APIError.proxmoxError(msg)
        }
        let body = String(data: data, encoding: .utf8)
        throw APIError.httpStatus(http.statusCode, body)
    }

    private static func proxmoxError(from root: [String: Any]) -> String? {
        if let errors = root["errors"] as? String, !errors.isEmpty {
            return errors.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            let parts = errors.compactMap { any -> String? in
                if let s = any as? String { return s }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return nil
    }
}
