import Foundation

/// 经 PVE HTTP API + QEMU Guest Agent 控制来宾（`guest-exec` / `file-write` 等）。
enum GuestFileManager {
    /// 公共桌面：各用户可见，规避 OneDrive 重定向与非 ASCII 路径问题。
    static let windowsPublicDesktopBase = "C:\\Users\\Public\\Desktop\\"

    /// WebDAV 已挂好 `mac_paste` 后，由来宾内 **robocopy** 复制到公共桌面；**不**轮询 `exec-status`（避免假性超时）。
    /// robocopy 退出码语义特殊，不在此等待进程结束，故不按退出码判成败。
    static func startRobocopyMacPasteWebdavToGuestPublicDesktop(
        session: ProxmoxClient.Session,
        node: String,
        vmid: Int
    ) async throws -> ProxmoxClient.GuestAgentExecDispatchOutcome {
        let command: [String] = [
            "cmd.exe",
            "/c",
            "robocopy",
            "Z:\\.spice-clipboard\\mac_paste\\",
            windowsPublicDesktopBase,
            "/E",
            "/MT:8",
            "/R:1",
            "/W:1",
            "/IS",
            "/IT"
        ]
        return try await ProxmoxClient.guestAgentExecDispatchFireAndForget(
            session: session,
            node: node,
            vmid: vmid,
            command: command,
            requestTimeout: 45
        )
    }

    /// 约 5s 后由 QGA 触发一次极轻量的 `dir /b`（同样 fire-and-forget），仅作日志参考，不解析输出。
    static func fireSilentPublicDesktopDirListingProbe(
        session: ProxmoxClient.Session,
        node: String,
        vmid: Int
    ) async -> ProxmoxClient.GuestAgentExecDispatchOutcome? {
        let command: [String] = [
            "cmd.exe",
            "/c",
            "dir",
            "/b",
            windowsPublicDesktopBase
        ]
        return try? await ProxmoxClient.guestAgentExecDispatchFireAndForget(
            session: session,
            node: node,
            vmid: vmid,
            command: command,
            requestTimeout: 25
        )
    }

    /// `progress`：`(当前序号 1-based, 总数, 正在上传的短文件名)`，在任意线程调用；由调用方切主线程更新 UI。
    static func uploadLocalFilesToGuestPublicDesktop(
        session: ProxmoxClient.Session,
        node: String,
        vmid: Int,
        localFileURLs: [URL],
        progress: (@Sendable (_ index: Int, _ total: Int, _ fileLabel: String) -> Void)?
    ) async throws {
        let total = localFileURLs.count
        guard total > 0 else { return }

        for (offset, url) in localFileURLs.enumerated() {
            let idx = offset + 1
            let rawName = url.lastPathComponent
            let safe = sanitizeWindowsFileName(rawName)
            let guestPath = windowsPublicDesktopBase + (safe.isEmpty ? "pasted-file-\(idx)" : safe)
            progress?(idx, total, safe.isEmpty ? "pasted-file-\(idx)" : safe)
            let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
            try await ProxmoxClient.guestAgentFileWrite(
                session: session,
                node: node,
                vmid: vmid,
                guestPath: guestPath,
                data: bytes
            )
        }
    }

    private static func sanitizeWindowsFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(trimmed.count)
        for ch in trimmed {
            switch ch {
            case "\\", "/", ":", "*", "?", "\"", "<", ">", "|":
                out.append("_")
            default:
                out.append(ch)
            }
        }
        return out
    }
}
