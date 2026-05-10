import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import CSpiceBridge
import Darwin
import Foundation
import SwiftUI

// MARK: - C 回调（GLib 线程 → 主线程）

private func bridgeCtx(_ raw: UnsafeMutableRawPointer?) -> RemoteSpiceSessionModel? {
    guard let raw else { return nil }
    return Unmanaged<RemoteSpiceSessionModel>.fromOpaque(raw).takeUnretainedValue()
}

private func withOptionalCString(_ s: String?, _ body: (UnsafePointer<CChar>?) -> Bool) -> Bool {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
        return body(nil)
    }
    return t.withCString { body($0) }
}

/// 来宾 FILE_LIST WebDAV 下载 URL 组装；宿主→来宾文件经 Cmd+V：`spice_bridge_set_clipboard_files`（固定 `mac_paste`）+ QGA `guest-exec` xcopy 至公共桌面。
private enum SpiceWebDAVClipboardUtil {
    /// 从系统剪贴板提取本机 `file://` URL（伪装粘贴 / 来宾 FILE_LIST 落盘仍使用）。
    static func extractFileURLsFromPasteboard(_ pb: NSPasteboard) -> [URL] {
        var collected: [URL] = []
        var seenPaths: Set<String> = []

        func addFileURL(_ url: URL) {
            guard url.isFileURL else { return }
            let std = url.standardizedFileURL
            let p = std.path
            guard !p.isEmpty, seenPaths.insert(p).inserted else { return }
            collected.append(std)
        }

        if let objs = pb.readObjects(forClasses: [NSURL.self]) {
            for o in objs {
                if let u = o as? URL {
                    addFileURL(u)
                } else if let nu = o as? NSURL {
                    addFileURL(nu as URL)
                }
            }
        }

        let fileURLType = NSPasteboard.PasteboardType.fileURL
        if let single = pb.string(forType: fileURLType)?.trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
            if let u = URL(string: single) {
                addFileURL(u)
            }
        }
        if let plist = pb.propertyList(forType: fileURLType) {
            if let arr = plist as? [String] {
                for s in arr {
                    if let u = URL(string: s) { addFileURL(u) }
                }
            } else if let one = plist as? String, let u = URL(string: one) {
                addFileURL(u)
            }
        }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let names = pb.propertyList(forType: filenamesType) as? [String] {
            for path in names where !path.isEmpty {
                addFileURL(URL(fileURLWithPath: path))
            }
        }

        return collected
    }

    static func parseSpiceFileListBlob(_ data: Data) -> (mode: String, paths: [String]) {
        let parts: [String] = data.split(separator: 0).compactMap { seg in
            String(bytes: seg, encoding: .utf8)
        }
        guard let mode = parts.first else { return ("", []) }
        let paths = Array(parts.dropFirst()).filter { !$0.isEmpty }
        return (mode, paths)
    }

    static func webdavFileURL(baseString: String, spicePath: String) -> URL? {
        let base = baseString.hasSuffix("/") ? baseString : baseString + "/"
        let trimmed = spicePath.hasPrefix("/") ? String(spicePath.dropFirst()) : spicePath
        let encoded = trimmed.split(separator: "/").map { part -> String in
            String(part).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        }.joined(separator: "/")
        guard !encoded.isEmpty else { return URL(string: base) }
        return URL(string: base + encoded)
    }
}

private let cbState: @convention(c) (UnsafeMutableRawPointer?, SpiceBridgeState) -> Void = { ctx, st in
    guard let m = bridgeCtx(ctx) else { return }
    DispatchQueue.main.async { m.handleBridgeState(st) }
}

private let cbDisplayCreate: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<SpiceBridgeSurface>?) -> Void = { ctx, surf in
    guard let m = bridgeCtx(ctx), let surf else { return }
    let w = Int(surf.pointee.width), h = Int(surf.pointee.height), stride = Int(surf.pointee.stride)
    let fmt = surf.pointee.format
    guard w > 0, h > 0, stride > 0, let src = surf.pointee.data else { return }
    let rowBytes = w * 4
    var buf = Data(count: rowBytes * h)
    buf.withUnsafeMutableBytes { dst in
        guard let dptr = dst.baseAddress else { return }
        for y in 0 ..< h {
            memcpy(dptr.advanced(by: y * rowBytes), src.advanced(by: y * stride), rowBytes)
        }
    }
    DispatchQueue.main.async { m.applyFullFrame(width: w, height: h, format: fmt, pixels: buf) }
}

/// 必须在 GLib 回调内拷贝像素：`data` 在回调返回后即失效。
private func copyDirtyRectPixels(
    src: UnsafePointer<UInt8>,
    stride: Int,
    x: Int,
    y: Int,
    w: Int,
    h: Int
) -> Data {
    var out = Data(count: w * h * 4)
    out.withUnsafeMutableBytes { dstRaw in
        guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
        for row in 0 ..< h {
            let sy = y + row
            memcpy(dst.advanced(by: row * w * 4), src.advanced(by: sy * stride + x * 4), w * 4)
        }
    }
    return out
}

private let cbDisplayInvalidate: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<SpiceBridgeRect>?, UnsafePointer<UInt8>?, Int32) -> Void = { ctx, _, rectPtr, data, stride in
    guard let m = bridgeCtx(ctx), let rectPtr, let data, stride > 0 else { return }
    let r = rectPtr.pointee
    guard r.width > 0, r.height > 0 else { return }
    let x = Int(r.x), y = Int(r.y), w = Int(r.width), h = Int(r.height)
    let packed = copyDirtyRectPixels(src: data, stride: Int(stride), x: x, y: y, w: w, h: h)
    DispatchQueue.main.async {
        m.applyDirtyRectPacked(x: x, y: y, width: w, height: h, pixels: packed)
    }
}

private let cbDisplayDestroy: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ctx, _ in
    guard let m = bridgeCtx(ctx) else { return }
    DispatchQueue.main.async { m.clearDisplay() }
}

private let cbDebug: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, msg in
    guard let m = bridgeCtx(ctx), let msg else { return }
    let s = String(cString: msg)
    DispatchQueue.main.async { m.appendDebugLine(s) }
}

/// 在 GLib 线程上同步光栅化（回调返回后 CVPixelBuffer 可能失效，不能异步再读）。
private enum VideoFrameRasterizer {
    static let ci = CIContext(options: [.useSoftwareRenderer: false])
}

private let cbVideoFrame: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { ctx, buf in
    guard let m = bridgeCtx(ctx), let buf else { return }
    let pb = Unmanaged<CVPixelBuffer>.fromOpaque(buf).takeUnretainedValue()
    let pw = CVPixelBufferGetWidth(pb)
    let ph = CVPixelBufferGetHeight(pb)
    guard pw > 1, ph > 1 else { return }
    var ciImg = CIImage(cvPixelBuffer: pb)
    let ext0 = ciImg.extent
    if ext0.isInfinite || ext0.width < 1 || ext0.height < 1 {
        ciImg = ciImg.cropped(to: CGRect(x: 0, y: 0, width: pw, height: ph))
    }
    let extent = ciImg.extent.integral
    guard extent.width > 1, extent.height > 1,
          let cg = VideoFrameRasterizer.ci.createCGImage(ciImg, from: extent)
    else { return }
    let ns = NSImage(cgImage: cg, size: NSSize(width: extent.width, height: extent.height))
    let sz = NSSize(width: extent.width, height: extent.height)
    DispatchQueue.main.async {
        m.applyVideoFrameImage(ns, size: sz)
    }
}

// MARK: - 剪贴板（C 桥 ↔ NSPasteboard）

private let cbRemoteClipboardUtf8: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, size_t) -> Void = { ctx, utf8, len in
    guard let m = bridgeCtx(ctx), let utf8, len > 0 else { return }
    let data = Data(bytes: utf8, count: Int(len))
    DispatchQueue.main.async { m.applyRemoteClipboardUtf8(data) }
}

/// 由 C 桥 `dispatch_sync` 到主队列调用（见 `spice_bridge.c`）。
private let cbCopyHostClipboardUtf8: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<size_t>?) -> UnsafeMutablePointer<CChar>? = { ctx, outLen in
    guard let ctx, let outLen, let m = bridgeCtx(ctx) else { return nil }
    precondition(Thread.isMainThread, "host clipboard fetch must run on main")
    return m.copyHostClipboardUtf8Malloc(outLen)
}

/// 来宾 VD_AGENT_CLIPBOARD_FILE_LIST（GLib 线程）；在闭包内拷贝字节后切主线程。
private let cbRemoteClipboardFileList: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, size_t) -> Void = { ctx, blob, len in
    guard let m = bridgeCtx(ctx), let blob, len > 0 else { return }
    let data = Data(bytes: blob, count: Int(len))
    DispatchQueue.main.async {
        m.handleGuestRemoteClipboardFileList(data)
    }
}

// MARK: - 会话模型

@MainActor
final class RemoteSpiceSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolving
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var displayImage: NSImage?
    @Published private(set) var debugLog: [String] = []
    @Published var guestSize: CGSize = .zero
    /// QGA 伪装粘贴时的顶栏提示（成功/失败/进度）；置 nil 可隐藏。
    @Published var qgaPasteBanner: String?

    /// AppKit 修饰键走 `flagsChanged`，与 `keyDown` 不同轨；用 HID 状态去抖，避免重复 press/release。
    private var modifierKeyDownSession: [UInt16: Bool] = [:]

    /// 正在把远端**文本**写回系统剪贴板时抑制 `didChange`，避免与 SPICE 重新 grab 形成环路。
    private var suppressPasteboardBridge = false
    /// 正在把来宾 WebDAV 下载结果写回本机剪贴板时抑制处理，避免刚写入的文件再次被发往虚拟机。
    private var isProcessingRemoteFilePaste = false
    private var pasteboardChangeObserver: NSObjectProtocol?
    /// Finder 等场景下 `NSPasteboardChangedNotification` 可能漏发，用 `changeCount` 轮询兜底。
    private var pasteboardPollTimer: Timer?
    private var lastPollPasteboardChangeCount: Int = 0
    /// 已成功向 C 层同步过的 `NSPasteboard.general.changeCount`，避免通知 + 轮询 + 点击等对同一版本重复 Grab。
    private var lastProcessedChangeCount: Int = 0
    /// 来宾剪贴板文件下载落盘路径，会话结束时删除。
    private var guestClipboardDownloadTempFiles: [URL] = []
    /// 取消过期的异步下载（断开连接时递增）。
    private var guestClipboardDownloadGeneration: UInt64 = 0

    private var session: OpaquePointer?
    private var framebuffer: Data = .init()
    private var fbWidth: Int = 0
    private var fbHeight: Int = 0
    /// SPICE `SpiceSurfaceFmt` 数值，如 32 = 32_xRGB，96 = 32_ARGB（见 spice/enums.h）
    private var surfaceFormat: UInt32 = 32
    /// 登录后保留，供 Cmd+V 走 QGA `guest-exec`（与 SPICE WebDAV 会话并行）。
    private var pveAgentSession: ProxmoxClient.Session?
    private var pveAgentNode: String = ""
    private var pveAgentVmid: Int = 0

    func shutdown() {
        removePasteboardClipboardBridge()
        guestClipboardDownloadGeneration += 1
        removeGuestClipboardTempFiles()
        if let s = session {
            spice_bridge_disconnect(s)
            spice_bridge_quit_loop(s)
            spice_bridge_session_free(s)
            session = nil
        }
        phase = .disconnected
        displayImage = nil
        framebuffer.removeAll(keepingCapacity: false)
        guestSize = .zero
        modifierKeyDownSession.removeAll()
        isProcessingRemoteFilePaste = false
        pveAgentSession = nil
        pveAgentNode = ""
        pveAgentVmid = 0
        qgaPasteBanner = nil
    }

    func start(record: PVEServerRecord, password: String, vm: PVEVirtualMachineRow) async {
        phase = .resolving
        debugLog.removeAll()
        qgaPasteBanner = nil
        do {
            let pair = try await ProxmoxClient.loginAndFetchVersion(
                baseURLString: record.baseURL,
                usernameAtRealm: record.loginUserAtRealm,
                password: password,
                acceptUntrustedTLS: record.acceptUntrustedTLS
            )
            pveAgentSession = pair.session
            pveAgentNode = vm.node
            pveAgentVmid = vm.vmid
            let spice = try await ProxmoxClient.fetchSpiceProxy(
                session: pair.session,
                node: vm.node,
                vmid: vm.vmid
            )
            let nodeAddrs = (try? await ProxmoxClient.fetchClusterNodeAddressMap(session: pair.session)) ?? [:]
            let directHost = ProxmoxClient.resolveSpiceHost(
                spiceHost: spice.ticketHost,
                apiBaseURL: pair.session.baseURL,
                vmNode: vm.node,
                nodeAddresses: nodeAddrs
            )
            let connectHost = spice.connectHost(resolvedDirectHost: directHost)

            phase = .connecting
            try await openBridge(info: spice, connectHost: connectHost)
        } catch {
            pveAgentSession = nil
            pveAgentNode = ""
            pveAgentVmid = 0
            phase = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func openBridge(info: ProxmoxClient.SpiceProxyInfo, connectHost: String) async throws {
        var cbs = SpiceBridgeCallbacks()
        memset(&cbs, 0, MemoryLayout<SpiceBridgeCallbacks>.size)
        cbs.context = Unmanaged.passUnretained(self).toOpaque()
        cbs.on_state_changed = cbState
        cbs.on_display_create = cbDisplayCreate
        cbs.on_display_invalidate = cbDisplayInvalidate
        cbs.on_display_destroy = cbDisplayDestroy
        cbs.on_debug = cbDebug
        cbs.on_video_frame = cbVideoFrame
        cbs.on_remote_clipboard_utf8 = cbRemoteClipboardUtf8
        cbs.copy_host_clipboard_utf8 = cbCopyHostClipboardUtf8
        cbs.on_remote_clipboard_file_list = cbRemoteClipboardFileList

        guard let s = spice_bridge_session_new(&cbs) else {
            throw ProxmoxClient.APIError.proxmoxError("无法创建 SPICE 会话")
        }
        session = s
        spice_bridge_run_loop(s)

        let tls = info.tlsPort
        let plain = info.port
        let tlsParam = tls > 0 ? Int32(tls) : Int32(0)
        let plainParam = Int32(plain > 0 ? plain : 0)
        let ok = connectHost.withCString { hptr in
            info.password.withCString { pptr in
                withOptionalCString(info.caPem) { caPtr in
                    withOptionalCString(info.hostSubject) { subjPtr in
                        withOptionalCString(info.httpProxy) { proxPtr in
                            spice_bridge_connect(s, hptr, plainParam, tlsParam, pptr, caPtr, subjPtr, proxPtr)
                        }
                    }
                }
            }
        }
        if !ok {
            spice_bridge_session_free(s)
            session = nil
            throw ProxmoxClient.APIError.proxmoxError("SPICE 连接失败（请确认虚拟机已开机且控制台未被占用）")
        }
        phase = .connected
        installPasteboardClipboardBridge()
    }

    fileprivate func handleBridgeState(_ st: SpiceBridgeState) {
        switch st {
        case SPICE_BRIDGE_STATE_CONNECTED:
            phase = .connected
        case SPICE_BRIDGE_STATE_DISCONNECTED:
            if case .failed = phase { break }
            phase = .disconnected
        case SPICE_BRIDGE_STATE_ERROR:
            if case .connected = phase { phase = .failed("SPICE 会话错误") }
        default:
            break
        }
    }

    fileprivate func applyFullFrame(width: Int, height: Int, format: UInt32, pixels: Data) {
        surfaceFormat = format
        fbWidth = width
        fbHeight = height
        framebuffer = pixels
        guestSize = CGSize(width: width, height: height)
        refreshNSImage()
    }

    fileprivate func applyDirtyRectPacked(x: Int, y: Int, width: Int, height: Int, pixels: Data) {
        guard fbWidth > 0, fbHeight > 0, !framebuffer.isEmpty else { return }
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return }
        let rowBytes = fbWidth * 4
        let destX = max(0, x)
        let destY = max(0, y)
        let srcXSkip = max(0, destX - x)
        let srcYSkip = max(0, destY - y)
        let copyW = min(width - srcXSkip, fbWidth - destX)
        let copyH = min(height - srcYSkip, fbHeight - destY)
        guard copyW > 0, copyH > 0 else { return }
        framebuffer.withUnsafeMutableBytes { dstRaw in
            guard let base = dstRaw.baseAddress else { return }
            pixels.withUnsafeBytes { srcRaw in
                guard let sbase = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0 ..< copyH {
                    let dstRow = base.advanced(by: (destY + row) * rowBytes + destX * 4)
                    let srcRow = sbase.advanced(by: (srcYSkip + row) * width * 4 + srcXSkip * 4)
                    memcpy(dstRow, srcRow, copyW * 4)
                }
            }
        }
        refreshNSImage()
    }

    fileprivate func clearDisplay() {
        framebuffer.removeAll(keepingCapacity: false)
        fbWidth = 0
        fbHeight = 0
        surfaceFormat = 32
        displayImage = nil
        guestSize = .zero
    }

    fileprivate func applyVideoFrameImage(_ image: NSImage, size: CGSize) {
        displayImage = image
        guestSize = size
    }

    private func refreshNSImage() {
        guard fbWidth > 0, fbHeight > 0, framebuffer.count >= fbWidth * fbHeight * 4 else { return }
        // 16bpp 等暂不支持（需单独展开）
        guard surfaceFormat == 32 || surfaceFormat == 96 else {
            appendDebugLine("SPICE 像素格式 \(surfaceFormat) 暂仅支持 32_xRGB/32_ARGB 类 32bpp")
            return
        }
        // 与 PrXpice Metal `.bgra8Unorm` 一致：主表面为小端 B,G,R,X；X 常为 0，若按带 alpha 解释会误合成（偏红）。
        var pixels = framebuffer
        if surfaceFormat == 32 {
            pixels.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                let n = fbWidth * fbHeight
                for i in 0 ..< n { base[i] |= 0xFF00_0000 }
            }
        }
        let bitmapInfo = Self.cgBitmapInfo(forSpiceFormat: surfaceFormat)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let prov = CGDataProvider(data: pixels as CFData),
              let cg = CGImage(
                  width: fbWidth,
                  height: fbHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: fbWidth * 4,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: prov,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return }
        displayImage = NSImage(cgImage: cg, size: NSSize(width: fbWidth, height: fbHeight))
    }

    /// SPICE 32_xRGB：与 PrXpice 相同按 **BGRA 小端** 解释；96 为 ARGB。
    private nonisolated static func cgBitmapInfo(forSpiceFormat fmt: UInt32) -> UInt32 {
        switch fmt {
        case 96: // SPICE_SURFACE_FMT_32_ARGB
            return CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        default: // SPICE_SURFACE_FMT_32_xRGB
            return CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        }
    }

    fileprivate func appendDebugLine(_ s: String) {
        debugLog.append(s)
        if debugLog.count > 200 { debugLog.removeFirst(debugLog.count - 200) }
    }

    // MARK: 剪贴板（主线程）

    private func installPasteboardClipboardBridge() {
        guard session != nil, pasteboardChangeObserver == nil else { return }
        lastPollPasteboardChangeCount = NSPasteboard.general.changeCount
        // Cocoa 文档中的名称是 `NSPasteboardChangedNotification`（不是 DidChange）。
        pasteboardChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSPasteboardChangedNotification"),
            object: NSPasteboard.general,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLocalPasteboardDidChangeForSpice(source: "notification")
            }
        }
        pasteboardPollTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboardChangeCountIfNeeded()
            }
        }
        if let t = pasteboardPollTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func removePasteboardClipboardBridge() {
        pasteboardPollTimer?.invalidate()
        pasteboardPollTimer = nil
        if let o = pasteboardChangeObserver {
            NotificationCenter.default.removeObserver(o)
            pasteboardChangeObserver = nil
        }
        lastProcessedChangeCount = 0
        lastPollPasteboardChangeCount = 0
    }

    private func pollPasteboardChangeCountIfNeeded() {
        guard session != nil, pasteboardChangeObserver != nil else { return }
        let cc = NSPasteboard.general.changeCount
        guard cc != lastPollPasteboardChangeCount else { return }
        handleLocalPasteboardDidChangeForSpice(source: "changeCount-poll")
    }

    /// 用户回到远程画面时主动声明本机剪贴板（例如先在外部 App 复制，再点进 SPICE 后粘贴）。
    func syncHostClipboardOfferToGuestNow() {
        handleLocalPasteboardDidChangeForSpice(source: "syncHostClipboardOfferToGuestNow")
    }

    /// 与 `copyHostClipboardUtf8Malloc` 一致：仅识别可编码为 UTF-8 的**纯文本**板类型。
    private func hostPasteboardHasReadablePlainText(_ pb: NSPasteboard) -> Bool {
        let s = pb.string(forType: .string)
            ?? pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
            ?? pb.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        return !(s?.isEmpty ?? true)
    }

    private func logPasteboardSnapshotForDiagnostics(pasteboard pb: NSPasteboard, changeCount cc: Int, source: String) {
        let types = pb.types ?? []
        let typeStrings = types.map { $0.rawValue }.joined(separator: ", ")
        let line = "剪贴板[\(source)] changeCount=\(cc) 文本同步 types=\(types.count) → [\(typeStrings)]"
        print("[PVESpice] \(line)")
        appendDebugLine(line)
        if suppressPasteboardBridge {
            let w = "剪贴板[\(source)]：suppressPasteboardBridge=true，本次不向 SPICE 同步"
            print("[PVESpice] \(w)")
            appendDebugLine(w)
        }
        if isProcessingRemoteFilePaste {
            let w = "剪贴板[\(source)]：isProcessingRemoteFilePaste=true（来宾文件刚写入本机剪贴板防抖中），跳过宿主文件/文本转发以免环路"
            print("[PVESpice] \(w)")
            appendDebugLine(w)
        }
    }

    private func handleLocalPasteboardDidChangeForSpice(source: String) {
        guard let s = session else {
            print("[PVESpice] 剪贴板[\(source)]：无 session，忽略")
            return
        }
        guard case .connected = phase else {
            print("[PVESpice] 剪贴板[\(source)]：phase≠connected，忽略")
            return
        }

        let pb = NSPasteboard.general
        let cc = pb.changeCount

        if cc == lastProcessedChangeCount {
            lastPollPasteboardChangeCount = cc
            return
        }
        lastPollPasteboardChangeCount = cc

        logPasteboardSnapshotForDiagnostics(pasteboard: pb, changeCount: cc, source: source)

        if suppressPasteboardBridge { return }
        if isProcessingRemoteFilePaste { return }

        let hasText = hostPasteboardHasReadablePlainText(pb)
        if hasText {
            appendDebugLine("剪贴板：文本 → spice_bridge_clipboard_host_pasteboard_changed")
            spice_bridge_clipboard_host_pasteboard_changed(s)
        }

        lastProcessedChangeCount = cc
    }

    /// 剪贴板类型是否含文件声明（`public.file-url`）；有文件时由 Cmd+V 走 WebDAV + QGA，此处不参与轮询。
    private func pasteboardDeclaresFileURLs(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        if types.contains(.fileURL) { return true }
        if types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) { return true }
        return false
    }

    /// 远程画面为第一响应者且用户按 Cmd+V：若剪贴板含本机文件则经 QGA 异步上传至来宾公共桌面，并消费该键等价事件。
    func consumeDisguisedPasteKeyEquivalentIfNeeded(_ event: NSEvent) -> Bool {
        guard case .connected = phase else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift)
        else { return false }

        let ch = event.charactersIgnoringModifiers ?? ""
        guard ch == "v" || ch == "V" else { return false }

        guard pasteboardDeclaresFileURLs(NSPasteboard.general) else { return false }

        let urls = SpiceWebDAVClipboardUtil.extractFileURLsFromPasteboard(NSPasteboard.general)
        guard !urls.isEmpty else { return false }

        guard let apiSession = pveAgentSession, !pveAgentNode.isEmpty else {
            appendDebugLine("伪装粘贴：无 PVE API 会话（请先成功连接），无法走 QGA")
            return false
        }
        guard pveAgentVmid > 0 else {
            appendDebugLine("伪装粘贴：vmid 无效，无法走 QGA")
            return false
        }

        let node = pveAgentNode
        let vmid = pveAgentVmid
        let n = urls.count
        appendDebugLine("伪装粘贴：Cmd+V → WebDAV mac_paste + QGA robocopy（\(n) 个文件）→ \(GuestFileManager.windowsPublicDesktopBase)")
        qgaPasteBanner = "正在将文件提取到虚拟机桌面…"

        Task { [weak self] in
            guard let self else { return }
            Task { [apiSession, node, vmid] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let probe = await GuestFileManager.fireSilentPublicDesktopDirListingProbe(
                    session: apiSession,
                    node: node,
                    vmid: vmid
                )
                await MainActor.run { [weak self] in
                    if let probe {
                        self?.appendDebugLine("静默验证：dir /b 已派发（\(probe)）")
                    } else {
                        self?.appendDebugLine("静默验证：dir /b 未确认派发（忽略）")
                    }
                }
            }
            do {
                await MainActor.run { [weak self] in
                    self?.pushHostClipboardFilesToWebDAVForGuest(urls)
                }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let outcome = try await GuestFileManager.startRobocopyMacPasteWebdavToGuestPublicDesktop(
                    session: apiSession,
                    node: node,
                    vmid: vmid
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    switch outcome {
                    case let .launched(pid):
                        self.appendDebugLine("伪装粘贴：robocopy 已发射（pid=\(pid)）")
                    case .assumedLaunchedDespiteTransportTimeout:
                        self.appendDebugLine("伪装粘贴：robocopy 发射层超时，按后台处理中对待")
                    }
                    self.qgaPasteBanner = "文件处理中…"
                }
                try await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { [weak self] in
                    self?.qgaPasteBanner = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if ProxmoxClient.errorSuggestsGuestExecLikelyDispatched(error) {
                        self.appendDebugLine("伪装粘贴：超时类错误，视为后台处理中 — \(error)")
                        self.qgaPasteBanner = "文件处理中…"
                    } else {
                        let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        self.qgaPasteBanner = "粘贴失败：\(msg)"
                        self.appendDebugLine("伪装粘贴：WebDAV/robocopy 失败 — \(msg)")
                    }
                }
                if ProxmoxClient.errorSuggestsGuestExecLikelyDispatched(error) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await MainActor.run { [weak self] in
                        self?.qgaPasteBanner = nil
                    }
                }
            }
        }
        return true
    }

    /// 将本机路径提交给 C 桥，映射到 WebDAV 固定目录 `/.spice-clipboard/mac_paste/`（在默认 GLib 主上下文上异步完成）。
    private func pushHostClipboardFilesToWebDAVForGuest(_ urls: [URL]) {
        guard let s = session, !urls.isEmpty else { return }
        let cStrings: [UnsafeMutablePointer<CChar>] = urls.map { url in
            url.path.withCString { strdup($0)! }
        }
        defer {
            for p in cStrings {
                free(p)
            }
        }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        argv.withUnsafeBufferPointer { bp in
            spice_bridge_set_clipboard_files(s, bp.baseAddress, Int32(cStrings.count))
        }
    }

    fileprivate func handleGuestRemoteClipboardFileList(_ data: Data) {
        guard let s = session, case .connected = phase else { return }
        let (mode, paths) = SpiceWebDAVClipboardUtil.parseSpiceFileListBlob(data)
        appendDebugLine("FILE_LIST 来宾：\(data.count) 字节，mode=\(mode)，路径 \(paths.count) 条")
        guard !paths.isEmpty else { return }

        removeGuestClipboardTempFiles()

        guard let basePtr = spice_bridge_get_webdav_base_url_malloc(s) else {
            appendDebugLine("FILE_LIST：无法取得 WebDAV 基址（通道未就绪？）")
            return
        }
        let baseStr = String(cString: basePtr)
        free(basePtr)
        appendDebugLine("FILE_LIST：WebDAV 基址 \(baseStr)")

        let gen = guestClipboardDownloadGeneration
        Task.detached { [baseStr, paths, gen] in
            var locals: [URL] = []
            var errs: [String] = []
            for rel in paths {
                guard let srcURL = SpiceWebDAVClipboardUtil.webdavFileURL(baseString: baseStr, spicePath: rel) else {
                    errs.append("无效 URL: \(rel)")
                    continue
                }
                do {
                    let (tmp, response) = try await URLSession.shared.download(from: srcURL)
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        errs.append("\(rel) HTTP \(http.statusCode)")
                        try? FileManager.default.removeItem(at: tmp)
                        continue
                    }
                    let baseName = (rel as NSString).lastPathComponent
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pvespice-guest-cb-\(UUID().uuidString)-\(baseName)")
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    locals.append(dest)
                } catch {
                    errs.append("\(rel): \(error.localizedDescription)")
                }
            }
            let errsCopy = errs
            let localsCopy = locals
            await MainActor.run { [weak self] in
                guard let self else { return }
                for e in errsCopy { self.appendDebugLine("FILE_LIST GET \(e)") }
                guard self.guestClipboardDownloadGeneration == gen else {
                    for u in localsCopy { try? FileManager.default.removeItem(at: u) }
                    self.appendDebugLine("FILE_LIST：会话代数已变，丢弃本次下载结果")
                    return
                }
                self.finishGuestFileListDownloadToPasteboard(localURLs: localsCopy)
            }
        }
    }

    private func finishGuestFileListDownloadToPasteboard(localURLs: [URL]) {
        guard !localURLs.isEmpty else {
            appendDebugLine("FILE_LIST：无成功下载的文件")
            return
        }
        guestClipboardDownloadTempFiles.append(contentsOf: localURLs)
        appendDebugLine("FILE_LIST：\(localURLs.count) 个文件已落盘，写入系统剪贴板")
        isProcessingRemoteFilePaste = true
        let pb = NSPasteboard.general
        pb.clearContents()
        let ns = localURLs.map { $0 as NSURL }
        if pb.writeObjects(ns) {
            appendDebugLine("剪贴板：writeObjects 成功（\(ns.count)）")
        } else {
            appendDebugLine("剪贴板：writeObjects 失败")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isProcessingRemoteFilePaste = false
            self?.appendDebugLine("剪贴板：来宾文件写入防抖结束（isProcessingRemoteFilePaste=false）")
        }
    }

    private func removeGuestClipboardTempFiles() {
        let fm = FileManager.default
        for u in guestClipboardDownloadTempFiles {
            do {
                try fm.removeItem(at: u)
            } catch {
                appendDebugLine("清理来宾剪贴板临时文件失败：\(u.lastPathComponent) \(error.localizedDescription)")
            }
        }
        guestClipboardDownloadTempFiles.removeAll()
    }

    fileprivate func applyRemoteClipboardUtf8(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            appendDebugLine("远端剪贴板 UTF-8 解码失败（\(data.count) 字节）")
            return
        }
        suppressPasteboardBridge = true
        defer { suppressPasteboardBridge = false }
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setString(text, forType: .string) {
            appendDebugLine("无法将远端文本写入系统剪贴板")
        }
    }

    /// 由 C 桥在主线程同步调用；返回 `malloc` 内存，桥接层 `free` 释放。
    nonisolated fileprivate func copyHostClipboardUtf8Malloc(_ outLen: UnsafeMutablePointer<size_t>) -> UnsafeMutablePointer<CChar>? {
        precondition(Thread.isMainThread, "host clipboard fetch must run on main")
        let pb = NSPasteboard.general
        let str = pb.string(forType: .string)
            ?? pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
            ?? pb.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        guard let str, !str.isEmpty else {
            outLen.pointee = 0
            return nil
        }
        let utf8 = Array(str.utf8)
        outLen.pointee = utf8.count
        guard let raw = malloc(utf8.count) else { return nil }
        _ = utf8.withUnsafeBufferPointer { src in
            memcpy(raw, src.baseAddress!, utf8.count)
        }
        return raw.assumingMemoryBound(to: CChar.self)
    }

    // MARK: 输入（主线程）

    func sendMouseAt(viewPoint: CGPoint, viewSize: CGSize, buttonMask: UInt32) {
        guard let s = session,
              guestSize.width > 0, guestSize.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return }
        let (gx, gy) = Self.viewPointToGuestPixel(
            viewPoint: viewPoint,
            viewSize: viewSize,
            guestSize: guestSize
        )
        spice_bridge_mouse_position(s, gx, gy, 0, buttonMask)
    }

    /// `NSImageView` 等比缩放居中时存在 letterbox；与 PrXpice「先算显示区域再映射」一致，避免光标偏移。
    private static func viewPointToGuestPixel(
        viewPoint: CGPoint,
        viewSize: CGSize,
        guestSize: CGSize
    ) -> (Int32, Int32) {
        let gw = guestSize.width
        let gh = guestSize.height
        let scale = min(viewSize.width / gw, viewSize.height / gh)
        let drawW = gw * scale
        let drawH = gh * scale
        let ox = (viewSize.width - drawW) / 2
        let oy = (viewSize.height - drawH) / 2
        let lx = min(max(viewPoint.x - ox, 0), drawW - 0.0001)
        let ly = min(max(viewPoint.y - oy, 0), drawH - 0.0001)
        let gx = Int32(lx / scale)
        let gy = Int32(ly / scale)
        let maxX = max(0, Int32(gw) - 1)
        let maxY = max(0, Int32(gh) - 1)
        return (min(max(gx, 0), maxX), min(max(gy, 0), maxY))
    }

    func sendMouseButton(button: UInt32, pressed: Bool, buttonMask: UInt32) {
        guard let s = session else { return }
        if pressed {
            spice_bridge_mouse_button_press(s, button, buttonMask)
        } else {
            spice_bridge_mouse_button_release(s, button, buttonMask)
        }
    }

    func sendScroll(deltaY: CGFloat, buttonMask: UInt32) {
        guard let s = session else { return }
        let steps = min(32, max(1, Int(abs(deltaY) / 8)))
        let up = UInt32(SPICE_BRIDGE_MOUSE_BUTTON_UP.rawValue)
        let dn = UInt32(SPICE_BRIDGE_MOUSE_BUTTON_DOWN.rawValue)
        let btn: UInt32 = deltaY > 0 ? dn : up
        for _ in 0 ..< steps {
            spice_bridge_mouse_button_press(s, btn, buttonMask)
            spice_bridge_mouse_button_release(s, btn, buttonMask)
        }
    }

    func sendKeyDown(_ event: NSEvent) {
        guard let s = session else { return }
        // 修饰键由 `flagsChanged` + HID 状态驱动，避免与 `keyDown` 双发。
        if SpiceKeyTranslation.isModifierKeyCode(event.keyCode) { return }
        if let make = SpiceKeyTranslation.scancodeMake(for: event) {
            spice_bridge_key_press(s, make)
        }
    }

    func sendKeyUp(_ event: NSEvent) {
        guard let s = session else { return }
        if SpiceKeyTranslation.isModifierKeyCode(event.keyCode) { return }
        if let make = SpiceKeyTranslation.scancodeMake(for: event) {
            // spice_inputs_key_release 内部会对 XT make 码加 break 位；此处须与 press 传同一 make（见 spice-glib）。
            spice_bridge_key_release(s, make)
        }
    }

    /// Shift / Control / Option / Command 在 macOS 上通常只产生 `flagsChanged`，不产生 `keyDown`/`keyUp`。
    func sendFlagsChanged(_ event: NSEvent) {
        guard let s = session else { return }
        let kc = event.keyCode
        guard SpiceKeyTranslation.isModifierKeyCode(kc) else { return }
        guard let xt = SpiceKeyTranslation.scancodeMake(for: event) else { return }

        let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kc))
        let was = modifierKeyDownSession[kc, default: false]
        if down == was { return }
        modifierKeyDownSession[kc] = down
        if down {
            spice_bridge_key_press(s, xt)
        } else {
            spice_bridge_key_release(s, xt)
        }
    }
}

// MARK: - Carbon 虚拟键码 → SPICE XT / E0 扩展（与 PrXpice ScancodeMap 同源语义）

private enum SpiceKeyTranslation {
    /// E0 前缀键：传 `0x100 | 第二字节`（spice-glib 约定）。
    private static func e0(_ b: UInt32) -> UInt32 { 0x100 | b }

    /// 仅这些虚拟键码在 `flagsChanged` 中按 HID 状态同步（与 PrXpice 修饰键语义一致）。
    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E:
            return true
        default:
            return false
        }
    }

    static func scancodeMake(for event: NSEvent) -> UInt32? {
        let kc = event.keyCode
        if let xt = keyCodeToXT[kc] { return xt }
        return characterFallback(event)
    }

    private static func characterFallback(_ event: NSEvent) -> UInt32? {
        // 优先 `characters`：含 Shift 产生的 `!`、`:` 等；`charactersIgnoringModifiers` 常仍是基准键面字符。
        let ch = (event.characters ?? event.charactersIgnoringModifiers)?.first
        guard let ch else { return nil }
        let c = String(ch)
        switch c.lowercased() {
        case "a": return 0x1e
        case "b": return 0x30
        case "c": return 0x2e
        case "d": return 0x20
        case "e": return 0x12
        case "f": return 0x21
        case "g": return 0x22
        case "h": return 0x23
        case "i": return 0x17
        case "j": return 0x24
        case "k": return 0x25
        case "l": return 0x26
        case "m": return 0x32
        case "n": return 0x31
        case "o": return 0x18
        case "p": return 0x19
        case "q": return 0x10
        case "r": return 0x13
        case "s": return 0x1f
        case "t": return 0x14
        case "u": return 0x16
        case "v": return 0x2f
        case "w": return 0x11
        case "x": return 0x2d
        case "y": return 0x15
        case "z": return 0x2c
        default: break
        }
        switch c {
        case "0": return 0x0b
        case "1": return 0x02
        case "2": return 0x03
        case "3": return 0x04
        case "4": return 0x05
        case "5": return 0x06
        case "6": return 0x07
        case "7": return 0x08
        case "8": return 0x09
        case "9": return 0x0a
        case " ", "\u{00a0}": return 0x39
        case "\r", "\n": return 0x1c
        case "\t": return 0x0f
        case "-", "–", "—": return 0x0c
        case "=", "≠": return 0x0d
        case "[", "{": return 0x1a
        case "]", "}": return 0x1b
        case "\\", "|": return 0x2b
        case ";", ":": return 0x27
        case "'", "\"": return 0x28
        case "`", "~": return 0x29
        case ",", "<": return 0x33
        case ".", ">": return 0x34
        case "/", "?": return 0x35
        default: return nil
        }
    }

    /// `NSEvent.keyCode`（Carbon `kVK_*`）→ SPICE 传入 `spice_inputs_key_press` 的 XT 值。
    private static let keyCodeToXT: [UInt16: UInt32] = {
        var m: [UInt16: UInt32] = [:]
        let e0 = Self.e0(_:)
        // ANSI 字母行（与 Events.h 一致）
        m[0x00] = 0x1e; m[0x01] = 0x1f; m[0x02] = 0x20; m[0x03] = 0x21
        m[0x04] = 0x23; m[0x05] = 0x22; m[0x06] = 0x2c; m[0x07] = 0x2d
        m[0x08] = 0x2e; m[0x09] = 0x2f; m[0x0B] = 0x30
        m[0x0C] = 0x10; m[0x0D] = 0x11; m[0x0E] = 0x12; m[0x0F] = 0x13
        m[0x10] = 0x15; m[0x11] = 0x14
        // 数字行
        m[0x12] = 0x02; m[0x13] = 0x03; m[0x14] = 0x04; m[0x15] = 0x05
        m[0x16] = 0x07; m[0x17] = 0x06; m[0x18] = 0x0d; m[0x19] = 0x0a
        m[0x1A] = 0x08; m[0x1B] = 0x0c; m[0x1C] = 0x09; m[0x1D] = 0x0b
        m[0x1E] = 0x1b; m[0x1F] = 0x18; m[0x20] = 0x16; m[0x21] = 0x1a
        m[0x22] = 0x17; m[0x23] = 0x19
        m[0x25] = 0x26; m[0x26] = 0x24; m[0x27] = 0x28; m[0x28] = 0x25
        m[0x29] = 0x27; m[0x2A] = 0x2b; m[0x2B] = 0x33; m[0x2C] = 0x35
        m[0x2D] = 0x31; m[0x2E] = 0x32; m[0x2F] = 0x34
        m[0x32] = 0x29
        // 主区控制
        m[0x24] = 0x1c; m[0x30] = 0x0f; m[0x31] = 0x39; m[0x33] = 0x0e
        m[0x35] = 0x01
        m[0x37] = e0(0x5b); m[0x36] = e0(0x5c) // Command → Win（常见远程习惯）
        m[0x38] = 0x2a; m[0x39] = 0x3a; m[0x3A] = 0x38; m[0x3B] = 0x1d
        m[0x3C] = 0x36; m[0x3D] = e0(0x38); m[0x3E] = e0(0x1d)
        // 导航 / 方向（E0）
        m[0x73] = e0(0x47); m[0x77] = e0(0x4f); m[0x74] = e0(0x49); m[0x79] = e0(0x51)
        m[0x75] = e0(0x53)
        m[0x7B] = e0(0x4b); m[0x7C] = e0(0x4d); m[0x7D] = e0(0x50); m[0x7E] = e0(0x48)
        // F1–F12
        m[0x7A] = 0x3b; m[0x78] = 0x3c; m[0x63] = 0x3d; m[0x76] = 0x3e
        m[0x60] = 0x3f; m[0x61] = 0x40; m[0x62] = 0x41; m[0x64] = 0x42
        m[0x65] = 0x43; m[0x6D] = 0x44; m[0x67] = 0x57; m[0x6F] = 0x58
        // 小键盘
        m[0x52] = 0x52; m[0x53] = 0x4f; m[0x54] = 0x50; m[0x55] = 0x51
        m[0x56] = 0x4b; m[0x57] = 0x4c; m[0x58] = 0x4d; m[0x59] = 0x47
        m[0x5B] = 0x48; m[0x5C] = 0x49
        m[0x41] = 0x53; m[0x43] = 0x37; m[0x45] = 0x4e; m[0x47] = 0x45
        m[0x4B] = e0(0x35); m[0x4C] = e0(0x1c); m[0x4E] = 0x4a
        return m
    }()
}

// MARK: - 交互视图

final class SpiceHostView: NSView {
    weak var model: RemoteSpiceSessionModel?
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.isOpaque = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let model else {
            return super.performKeyEquivalent(with: event)
        }
        if model.consumeDisguisedPasteKeyEquivalentIfNeeded(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: false)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: true)
    }

    override func mouseDown(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: false)
        if event.clickCount == 1 {
            window?.makeFirstResponder(self)
            // 本机剪贴板可能已在外部更新但未收到通知；点击远程区域时重新向 SPICE 声明。
            model?.syncHostClipboardOfferToGuestNow()
        }
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: false)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouse(event: event, includeDrag: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let mask = Self.buttonMaskFromEvent(event)
        model.sendScroll(deltaY: event.scrollingDeltaY, buttonMask: mask)
    }

    override func keyDown(with event: NSEvent) {
        model?.sendKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        model?.sendKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        model?.sendFlagsChanged(event)
    }

    func syncImage(_ image: NSImage?) {
        imageView.image = image
    }

    private func forwardMouse(event: NSEvent, includeDrag: Bool) {
        guard let model else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let mask = Self.buttonMaskFromEvent(event)
        model.sendMouseAt(viewPoint: loc, viewSize: bounds.size, buttonMask: mask)
    }

    private static func buttonMaskFromEvent(_ event: NSEvent) -> UInt32 {
        var m: UInt32 = 0
        let p = NSEvent.pressedMouseButtons
        if p & 1 != 0 { m |= UInt32(SPICE_BRIDGE_MOUSE_BUTTON_LEFT.rawValue) }
        if p & 2 != 0 { m |= UInt32(SPICE_BRIDGE_MOUSE_BUTTON_RIGHT.rawValue) }
        if p & 4 != 0 { m |= UInt32(SPICE_BRIDGE_MOUSE_BUTTON_MIDDLE.rawValue) }
        return m
    }
}

struct SpiceSessionSurfaceView: NSViewRepresentable {
    @ObservedObject var model: RemoteSpiceSessionModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> SpiceHostView {
        let v = SpiceHostView()
        v.model = model
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ nsView: SpiceHostView, context: Context) {
        nsView.model = model
        nsView.syncImage(model.displayImage)
    }

    final class Coordinator {
        let model: RemoteSpiceSessionModel
        weak var view: SpiceHostView?
        init(model: RemoteSpiceSessionModel) { self.model = model }
    }
}
