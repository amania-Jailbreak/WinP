import Foundation
import Dispatch
import Combine
import AppKit
import CoreGraphics

private struct AgentConnectionProfile {
    let host: String
    let port: Int
    let token: String
    let tls: Bool
    let caCertPath: String?
}

private struct RDPConnectionProfile {
    let host: String
    let username: String
    let password: String
    let domain: String?
    let autoReconnect: Bool
    let fullScreen: Bool
    let width: Int?
    let height: Int?
    let agent: AgentConnectionProfile
}

struct AgentWindow: Codable, Identifiable, Equatable {
    let windowId: UInt32
    var title: String
    var pid: UInt32
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var visible: Bool
    var minimized: Bool
    var maximized: Bool
    var zOrder: Int
    var monitorId: Int
    var timestamp: Int64

    var id: UInt32 { windowId }

    enum CodingKeys: String, CodingKey {
        case windowId = "window_id"
        case title
        case pid
        case x
        case y
        case width
        case height
        case visible
        case minimized
        case maximized
        case zOrder = "z_order"
        case monitorId = "monitor_id"
        case timestamp
    }
}

private struct AgentStreamEvent: Decodable {
    let event: String
    let window: AgentWindow?
    let windowId: UInt32?

    enum CodingKeys: String, CodingKey {
        case event
        case window
        case windowId = "window_id"
    }
}

@MainActor
private final class AgentWindowCropManager {
    private var windows: [UInt32: AgentWindow] = [:]
    private var desktopImage: NSImage?
    private var cropped: [UInt32: NSImage] = [:]

    func replaceWindows(_ list: [AgentWindow]) {
        windows = Dictionary(uniqueKeysWithValues: list.map { ($0.windowId, $0) })
        recropAll()
    }

    func updateDesktopImage(_ image: NSImage?) {
        desktopImage = image
        recropAll()
    }

    func image(for windowId: UInt32) -> NSImage? {
        cropped[windowId]
    }

    private func recropAll() {
        cropped.removeAll(keepingCapacity: true)
        guard let desktopImage, let cg = desktopImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let imageWidth = CGFloat(cg.width)
        let imageHeight = CGFloat(cg.height)

        for window in windows.values {
            let cropX = max(0, min(imageWidth - 1, CGFloat(window.x)))
            let cropY = max(0, min(imageHeight - 1, imageHeight - CGFloat(window.y) - CGFloat(window.height)))
            let cropWidth = max(1, min(CGFloat(window.width), imageWidth - cropX))
            let cropHeight = max(1, min(CGFloat(window.height), imageHeight - cropY))
            let rect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight).integral
            guard let croppedCg = cg.cropping(to: rect) else { continue }
            cropped[window.windowId] = NSImage(cgImage: croppedCg, size: NSSize(width: rect.width, height: rect.height))
        }
    }
}

private final class AgentBridgeStream {
    private var process: Process?
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let onEvent: @MainActor (AgentStreamEvent) -> Void
    private let onExit: @MainActor (Int32) -> Void

    init(onEvent: @escaping @MainActor (AgentStreamEvent) -> Void,
         onExit: @escaping @MainActor (Int32) -> Void) {
        self.onEvent = onEvent
        self.onExit = onExit
    }

    func start(profile: AgentConnectionProfile) {
        stop()

        let script = AgentBridgeCommand.scriptPath()
        let python = AgentBridgeCommand.pythonCommand()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = [python, script, "--host", profile.host, "--port", String(profile.port), "--token", profile.token]
        if profile.tls { args.append("--tls") }
        if let ca = profile.caCertPath, !ca.isEmpty {
            args.append(contentsOf: ["--ca-cert", ca])
        }
        args.append("stream")
        p.arguments = args

        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = stdout
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task { @MainActor in
                self.onExit(proc.terminationStatus)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            if data.isEmpty { return }
            self.consume(data: data)
        }

        do {
            try p.run()
            process = p
        } catch {
            Task { @MainActor in
                self.onExit(127)
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func consume(data: Data) {
        buffer.append(data)
        while true {
            guard let idx = buffer.firstIndex(of: 0x0A) else { break }
            let line = buffer.prefix(upTo: idx)
            buffer.removeSubrange(...idx)
            guard !line.isEmpty else { continue }
            guard let event = try? decoder.decode(AgentStreamEvent.self, from: Data(line)) else { continue }
            Task { @MainActor in
                self.onEvent(event)
            }
        }
    }
}

private enum AgentBridgeCommand {
    static func pythonCommand() -> String {
        if let explicit = ProcessInfo.processInfo.environment["WINP_AGENT_PYTHON"], !explicit.isEmpty {
            return explicit
        }
        return "python3"
    }

    static func scriptPath() -> String {
        if let explicit = ProcessInfo.processInfo.environment["WINP_AGENT_BRIDGE"], !explicit.isEmpty {
            return explicit
        }
        return "\(FileManager.default.currentDirectoryPath)/agent/windows/client_bridge.py"
    }

    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [pythonCommand(), scriptPath()] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, text)
        } catch {
            return (127, "failed to run python bridge: \(error)")
        }
    }
}

@MainActor
final class RDPClientService: ObservableObject {
    @Published var statusMessage: String = "接続情報を入力してください"
    @Published var outputLog: String = ""
    @Published var isRunning = false
    @Published var isError = false
    @Published var frameImage: NSImage?
    @Published var activeCursor: NSCursor = .arrow
    @Published var hideLocalCursor = false
    @Published var agentWindows: [AgentWindow] = []

    private var isFullScreenSession = false
    private var isNativeConnected = false
    private var resizeDebounceWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var lastRequestedResolution: CGSize = .zero
    private var manualDisconnectRequested = false
    private var reconnectAttempt = 0
    private var pendingReconnect = false
    private var lastConnectionProfile: RDPConnectionProfile?
    private var latestWindowSize: CGSize = .zero
    private var resolutionScale: Double = 1.0
    private let cropManager = AgentWindowCropManager()
    private lazy var bridgeStream: AgentBridgeStream = AgentBridgeStream(onEvent: { [weak self] event in
        self?.handleAgentEvent(event)
    }, onExit: { [weak self] code in
        self?.appendLog("Agent stream exited code=\(code)\n")
    })

    init() {
        let version = String(cString: winp_freerdp_version_string())
        statusMessage = "FreeRDPライブラリ: \(version)"
    }

    func connect(
        host: String,
        username: String,
        password: String,
        domain: String?,
        autoReconnect: Bool,
        fullScreen: Bool,
        width: Int?,
        height: Int?,
        agentHost: String,
        agentPort: Int,
        agentToken: String,
        agentTLS: Bool,
        agentCACertPath: String?
    ) {
        manualDisconnectRequested = false
        reconnectAttempt = 0
        pendingReconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        let profile = RDPConnectionProfile(
            host: host,
            username: username,
            password: password,
            domain: domain,
            autoReconnect: autoReconnect,
            fullScreen: fullScreen,
            width: width,
            height: height,
            agent: AgentConnectionProfile(
                host: agentHost,
                port: agentPort,
                token: agentToken,
                tls: agentTLS,
                caCertPath: agentCACertPath
            )
        )
        lastConnectionProfile = profile
        startSession(with: profile, isReconnect: false)
    }

    private func startSession(with profile: RDPConnectionProfile, isReconnect: Bool) {
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Hostを入力してください")
            return
        }
        guard !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Usernameを入力してください")
            return
        }
        guard !profile.password.isEmpty else {
            setError("Passwordを入力してください")
            return
        }
        guard !profile.agent.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Agent Hostを入力してください")
            return
        }
        guard profile.agent.port > 0 else {
            setError("Agent Portを入力してください")
            return
        }
        guard !profile.agent.token.isEmpty else {
            setError("Agent Tokenを入力してください")
            return
        }

        isRunning = true
        isFullScreenSession = profile.fullScreen
        isNativeConnected = false
        isError = false
        statusMessage = isReconnect ? "再接続中..." : "RDPセッション開始中..."
        appendLog("Start session: host=\(profile.host), user=\(profile.username), fullscreen=\(profile.fullScreen), size=\(profile.width ?? 0)x\(profile.height ?? 0), reconnect=\(isReconnect)\n")

        let hostValue = profile.host
        let usernameValue = profile.username
        let passwordValue = profile.password
        let domainValue = profile.domain
        let widthValue = profile.width ?? 1920
        let heightValue = profile.height ?? 1080
        let fullScreenValue = profile.fullScreen ? 1 : 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorBuffer = [CChar](repeating: 0, count: 1024)
            guard let self else { return }
            let userData = Unmanaged.passUnretained(self).toOpaque()

            let result = hostValue.withCString { hostCString in
                usernameValue.withCString { userCString in
                    passwordValue.withCString { passwordCString in
                        let callStartSession: (UnsafePointer<CChar>?) -> Int32 = { domainCString in
                            winp_freerdp_start_session(
                                hostCString,
                                userCString,
                                passwordCString,
                                domainCString,
                                Int32(widthValue),
                                Int32(heightValue),
                                Int32(fullScreenValue),
                                winpFrameCallback,
                                winpCursorCallback,
                                winpStatusCallback,
                                userData,
                                &errorBuffer,
                                errorBuffer.count
                            )
                        }

                        if let domainValue {
                            return domainValue.withCString(callStartSession)
                        }
                        return callStartSession(nil)
                    }
                }
            }

            let errorText = String(cString: errorBuffer)
            DispatchQueue.main.async {
                self.isRunning = false
                if result == 0 {
                    self.isError = false
                    self.statusMessage = "セッション開始要求を送信しました"
                    self.isRunning = true
                    self.isFullScreenSession = profile.fullScreen
                    self.isNativeConnected = false
                    self.lastRequestedResolution = .zero
                    self.pendingReconnect = false
                    self.appendLog("FreeRDP session start: success\n")
                    self.startAgentStreaming(profile.agent)
                } else {
                    self.isError = true
                    self.isFullScreenSession = false
                    self.isNativeConnected = false
                    self.statusMessage = "接続失敗: \(errorText.isEmpty ? "unknown" : errorText)"
                    self.appendLog("FreeRDP session start: failed code=\(result), error=\(errorText)\n")
                    if !self.manualDisconnectRequested, profile.autoReconnect {
                        self.scheduleReconnect(reason: "start-failed")
                    }
                }
            }
        }
    }

    func disconnect() {
        manualDisconnectRequested = true
        reconnectAttempt = 0
        pendingReconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        resizeDebounceWorkItem?.cancel()
        resizeDebounceWorkItem = nil
        bridgeStream.stop()
        winp_freerdp_stop_session()
        isRunning = false
        isFullScreenSession = false
        isNativeConnected = false
        lastRequestedResolution = .zero
        statusMessage = "切断しました"
        isError = false
        hideLocalCursor = false
        activeCursor = .arrow
        agentWindows = []
    }

    private func scheduleReconnect(reason: String) {
        guard !manualDisconnectRequested else { return }
        guard let lastConnectionProfile else { return }
        guard lastConnectionProfile.autoReconnect else { return }
        guard !pendingReconnect else { return }

        pendingReconnect = true
        reconnectAttempt += 1
        let delaySeconds = 0.1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnect = false
            self.performReconnectAttempt()
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = workItem

        statusMessage = "接続断: 自動再接続を \(String(format: "%.1f", delaySeconds)) 秒後に実行"
        appendLog("Auto reconnect scheduled: attempt=\(reconnectAttempt), in=\(String(format: "%.1f", delaySeconds))s, reason=\(reason)\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
    }

    private func performReconnectAttempt() {
        guard !manualDisconnectRequested else { return }
        guard let profile = lastConnectionProfile else { return }
        var reconnectProfile = profile
        if !reconnectProfile.fullScreen, latestWindowSize.width >= 200, latestWindowSize.height >= 200 {
            reconnectProfile = RDPConnectionProfile(
                host: reconnectProfile.host,
                username: reconnectProfile.username,
                password: reconnectProfile.password,
                domain: reconnectProfile.domain,
                autoReconnect: reconnectProfile.autoReconnect,
                fullScreen: reconnectProfile.fullScreen,
                width: Int(max(200, floor(latestWindowSize.width / resolutionScale))),
                height: Int(max(200, floor(latestWindowSize.height / resolutionScale))),
                agent: reconnectProfile.agent
            )
        }
        startSession(with: reconnectProfile, isReconnect: true)
    }

    func syncResolutionToWindowSize(_ size: CGSize) {
        latestWindowSize = size
        guard isRunning, isNativeConnected, !isFullScreenSession else { return }

        let target = CGSize(
            width: max(200, floor(size.width / resolutionScale)),
            height: max(200, floor(size.height / resolutionScale))
        )
        let deltaW = abs(target.width - lastRequestedResolution.width)
        let deltaH = abs(target.height - lastRequestedResolution.height)
        if deltaW < 8, deltaH < 8 { return }

        lastRequestedResolution = target
        resizeDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyResolution(width: Int(target.width), height: Int(target.height))
        }
        resizeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func setResolutionScale(_ scale: Double) {
        let clamped = min(max(scale, 0.5), 3.0)
        guard abs(clamped - resolutionScale) > 0.0001 else { return }
        resolutionScale = clamped
        appendLog("Resolution scale set: \(String(format: "%.1f", clamped))x\n")
        if latestWindowSize.width > 1, latestWindowSize.height > 1 {
            syncResolutionToWindowSize(latestWindowSize)
        }
    }

    func applyResolution(width: Int?, height: Int?) {
        guard isRunning else { setError("接続中のみ解像度変更できます"); return }
        guard isNativeConnected else { setError("接続確立後に解像度変更できます"); return }
        guard !isFullScreenSession else { setError("フルスクリーン接続中は解像度変更できません"); return }
        guard let width, let height, width >= 200, height >= 200 else {
            setError("有効な解像度を入力してください (最小 200x200)")
            return
        }

        appendLog("Apply resolution request: \(width)x\(height)\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let result = winp_freerdp_update_resolution(Int32(width), Int32(height), &errorBuffer, errorBuffer.count)
            let errorText = String(cString: errorBuffer)
            DispatchQueue.main.async {
                guard let self else { return }
                if result == 0 {
                    self.isError = false
                    self.statusMessage = "解像度変更要求を送信しました: \(width)x\(height)"
                    self.appendLog("Dynamic resolution update: queued\n")
                } else {
                    self.isError = true
                    self.statusMessage = "解像度変更失敗: \(errorText.isEmpty ? "unknown" : errorText)"
                    self.appendLog("Dynamic resolution update: failed code=\(result), error=\(errorText)\n")
                }
            }
        }
    }

    func sendMouse(flags: UInt16, x: Int, y: Int) {
        guard isRunning, isNativeConnected else { return }
        let clampedX = UInt16(max(0, min(65535, x)))
        let clampedY = UInt16(max(0, min(65535, y)))
        DispatchQueue.global(qos: .userInitiated).async {
            var errorBuffer = [CChar](repeating: 0, count: 256)
            _ = winp_freerdp_send_mouse_event(flags, clampedX, clampedY, &errorBuffer, errorBuffer.count)
        }
    }

    func sendUnicodeKey(code: UInt16, down: Bool) {
        guard isRunning, isNativeConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var errorBuffer = [CChar](repeating: 0, count: 256)
            _ = winp_freerdp_send_unicode_key(down ? 1 : 0, code, &errorBuffer, errorBuffer.count)
        }
    }

    func sendScancodeKey(scancode: UInt32, down: Bool) {
        guard isRunning, isNativeConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var errorBuffer = [CChar](repeating: 0, count: 256)
            _ = winp_freerdp_send_scancode_key(down ? 1 : 0, scancode, &errorBuffer, errorBuffer.count)
        }
    }

    func agentFocus(windowId: UInt32) {
        runAgentControl(["focus", "--window-id", String(windowId)])
    }

    func agentClose(windowId: UInt32) {
        runAgentControl(["close", "--window-id", String(windowId)])
    }

    func agentMoveResize(windowId: UInt32, x: Int, y: Int, width: Int, height: Int) {
        runAgentControl([
            "move-resize",
            "--window-id", String(windowId),
            "--x", String(x),
            "--y", String(y),
            "--width", String(width),
            "--height", String(height)
        ])
    }

    func croppedImage(for windowId: UInt32) -> NSImage? {
        cropManager.image(for: windowId)
    }

    func handleStatusFromNative(_ message: String) {
        appendLog("[native] \(message)\n")
        switch message {
        case "connected":
            statusMessage = "接続中"
            isRunning = true
            isNativeConnected = true
            reconnectAttempt = 0
            pendingReconnect = false
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            isError = false
        case "disconnected":
            statusMessage = "切断されました"
            isRunning = false
            isNativeConnected = false
            resizeDebounceWorkItem?.cancel()
            resizeDebounceWorkItem = nil
            bridgeStream.stop()
            if !manualDisconnectRequested, (lastConnectionProfile?.autoReconnect == true) {
                scheduleReconnect(reason: "native-disconnected")
            }
        default:
            break
        }
    }

    func handleCursorFromNative(kind: Int32, data: Data?, width: Int32, height: Int32, hotspotX: Int32, hotspotY: Int32) {
        switch kind {
        case 2:
            hideLocalCursor = true
        case 1:
            hideLocalCursor = false
            activeCursor = .arrow
        default:
            guard let data, width > 0, height > 0 else { return }
            guard let provider = CGDataProvider(data: data as CFData) else { return }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )
            guard let cgImage = CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: Int(width), height: Int(height)))
            let cursor = NSCursor(
                image: image,
                hotSpot: NSPoint(x: max(0, Int(hotspotX)), y: max(0, Int(hotspotY)))
            )
            hideLocalCursor = false
            activeCursor = cursor
        }
    }

    func handleFrameFromNative(_ data: UnsafePointer<UInt8>, width: Int32, height: Int32, stride: Int32) {
        let w = Int(width)
        let h = Int(height)
        let rowBytes = Int(stride)
        guard w > 0, h > 0, rowBytes >= (w * 4) else { return }

        let count = rowBytes * h
        let bufferData = Data(bytes: data, count: count)
        guard let provider = CGDataProvider(data: bufferData as CFData) else { return }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        guard let cgImage = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        frameImage = image
        cropManager.updateDesktopImage(image)
    }

    private func startAgentStreaming(_ profile: AgentConnectionProfile) {
        let args = bridgeBaseArgs(profile) + ["health"]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let service = self else { return }
            let res = AgentBridgeCommand.run(args)
            Task { @MainActor in
                if res.code == 0 {
                    service.appendLog("Agent health: ok\n")
                } else {
                    service.appendLog("Agent health failed: \(res.stdout)\n")
                    service.statusMessage = "Agent接続失敗（RDPは継続）"
                    service.isError = true
                }
                service.bridgeStream.start(profile: profile)
            }
        }
    }

    private func runAgentControl(_ opArgs: [String]) {
        guard let profile = lastConnectionProfile?.agent else { return }
        let args = bridgeBaseArgs(profile) + opArgs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let service = self else { return }
            let res = AgentBridgeCommand.run(args)
            Task { @MainActor in
                service.appendLog("Agent op \(opArgs.first ?? "?"): code=\(res.code) output=\(res.stdout)\n")
                if res.code != 0 {
                    service.statusMessage = "Agent制御失敗: \(opArgs.first ?? "?")"
                    service.isError = true
                }
            }
        }
    }

    private func bridgeBaseArgs(_ profile: AgentConnectionProfile) -> [String] {
        var args = [
            "--host", profile.host,
            "--port", String(profile.port),
            "--token", profile.token
        ]
        if profile.tls { args.append("--tls") }
        if let ca = profile.caCertPath, !ca.isEmpty {
            args.append(contentsOf: ["--ca-cert", ca])
        }
        return args
    }

    private func handleAgentEvent(_ event: AgentStreamEvent) {
        switch event.event {
        case "upsert":
            guard let window = event.window else { return }
            appendLog("Agent stream upsert: id=\(String(format: "0x%08X", window.windowId)) title=\(window.title)\n")
            var map = Dictionary(uniqueKeysWithValues: agentWindows.map { ($0.windowId, $0) })
            map[window.windowId] = window
            agentWindows = map.values.sorted { $0.zOrder > $1.zOrder }
            cropManager.replaceWindows(agentWindows)
        case "remove":
            guard let id = event.windowId else { return }
            appendLog("Agent stream remove: id=\(String(format: "0x%08X", id))\n")
            agentWindows.removeAll { $0.windowId == id }
            cropManager.replaceWindows(agentWindows)
        default:
            appendLog("Agent stream event: \(event.event)\n")
            break
        }
    }

    private func appendLog(_ text: String) {
        outputLog += text
        if outputLog.count > 40_000 {
            outputLog = String(outputLog.suffix(30_000))
        }
    }

    private func setError(_ message: String) {
        statusMessage = message
        isError = true
    }
}

private let winpFrameCallback: @convention(c) (UnsafePointer<UInt8>?, Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Void = {
    data, width, height, stride, userData in
    guard let data, let userData else { return }
    let service = Unmanaged<RDPClientService>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        service.handleFrameFromNative(data, width: width, height: height, stride: stride)
    }
}

private let winpStatusCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
    status, userData in
    guard let status, let userData else { return }
    let service = Unmanaged<RDPClientService>.fromOpaque(userData).takeUnretainedValue()
    let text = String(cString: status)
    DispatchQueue.main.async {
        service.handleStatusFromNative(text)
    }
}

private let winpCursorCallback: @convention(c) (Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Void = {
    kind, data, width, height, hotspotX, hotspotY, userData in
    guard let userData else { return }
    let service = Unmanaged<RDPClientService>.fromOpaque(userData).takeUnretainedValue()
    let payload: Data?
    if let data, width > 0, height > 0 {
        let count = Int(width) * Int(height) * 4
        payload = Data(bytes: data, count: count)
    } else {
        payload = nil
    }
    DispatchQueue.main.async {
        service.handleCursorFromNative(
            kind: kind,
            data: payload,
            width: width,
            height: height,
            hotspotX: hotspotX,
            hotspotY: hotspotY
        )
    }
}
