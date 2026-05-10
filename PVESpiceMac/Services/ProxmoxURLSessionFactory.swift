import Foundation

/// 接受服务端 TLS 证书（自签名、主机名与访问地址不一致等），仅应在用户明确勾选且主机可信时使用。
final class ProxmoxUntrustedTLSDelegate: NSObject, URLSessionDelegate {
    static let shared = ProxmoxUntrustedTLSDelegate()

    private override init() {
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

enum ProxmoxURLSessionFactory {
    /// 与系统默认校验一致（不信任无效证书）。
    private static let permissive: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: ProxmoxUntrustedTLSDelegate.shared,
            delegateQueue: nil
        )
    }()

    static func session(acceptUntrustedCertificate: Bool) -> URLSession {
        acceptUntrustedCertificate ? permissive : .shared
    }
}
