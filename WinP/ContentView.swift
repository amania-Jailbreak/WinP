//
//  ContentView.swift
//  WinP
//
//  Created by amania on 2026/03/18.
//

import SwiftUI
import AppKit

private let ptrFlagsMove: UInt16 = 0x0800
private let ptrFlagsDown: UInt16 = 0x8000
private let ptrFlagsButton1: UInt16 = 0x1000
private let ptrFlagsButton2: UInt16 = 0x2000
private let ptrFlagsButton3: UInt16 = 0x4000
private let ptrFlagsWheel: UInt16 = 0x0200
private let ptrFlagsWheelNegative: UInt16 = 0x0100

struct ContentView: View {
    @EnvironmentObject private var client: RDPClientService
    @Environment(\.openWindow) private var openWindow

    @AppStorage("connection.host") private var host = ""
    @AppStorage("connection.username") private var username = ""
    @AppStorage("connection.password") private var password = ""
    @AppStorage("connection.domain") private var domain = ""
    @AppStorage("connection.autoReconnect") private var autoReconnect = true
    @AppStorage("connection.width") private var width = "1920"
    @AppStorage("connection.height") private var height = "1080"
    @AppStorage("connection.fullScreen") private var fullScreen = false
    @AppStorage("connection.agentHost") private var agentHost = "127.0.0.1"
    @AppStorage("connection.agentPort") private var agentPort = "50051"
    @AppStorage("connection.agentToken") private var agentToken = ""
    @AppStorage("connection.agentTLS") private var agentTLS = true
    @AppStorage("connection.agentCACertPath") private var agentCACertPath = ""
    @State private var selectedWindowId: UInt32?
    @State private var controlX = ""
    @State private var controlY = ""
    @State private var controlW = ""
    @State private var controlH = ""
    @State private var inlineZoomScale = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WinP RDP Client")
                    .font(.title2)
                    .fontWeight(.semibold)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Host (example: 192.168.1.10)", text: $host)
                            .textFieldStyle(.roundedBorder)

                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)

                        TextField("Domain (optional)", text: $domain)
                            .textFieldStyle(.roundedBorder)

                        Toggle("Auto reconnect", isOn: $autoReconnect)

                        Toggle("Full screen (解像度指定を無視)", isOn: $fullScreen)

                        HStack {
                            TextField("Width", text: $width)
                                .textFieldStyle(.roundedBorder)
                            Text("x")
                            TextField("Height", text: $height)
                                .textFieldStyle(.roundedBorder)
                        }
                        .disabled(fullScreen)

                        Text(fullScreen ? "フルスクリーン時は接続先ディスプレイ解像度を使用" : "この解像度で接続します")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()
                        Text("Agent")
                            .font(.headline)
                        TextField("Agent Host", text: $agentHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Agent Port", text: $agentPort)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Agent Token", text: $agentToken)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Agent TLS", isOn: $agentTLS)
                        TextField("Agent CA Cert Path (optional)", text: $agentCACertPath)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button("Connect") {
                        client.connect(
                            host: host,
                            username: username,
                            password: password,
                            domain: domain.isEmpty ? nil : domain,
                            autoReconnect: autoReconnect,
                            fullScreen: fullScreen,
                            width: Int(width),
                            height: Int(height),
                            agentHost: agentHost,
                            agentPort: Int(agentPort) ?? 0,
                            agentToken: agentToken,
                            agentTLS: agentTLS,
                            agentCACertPath: agentCACertPath.isEmpty ? nil : agentCACertPath
                        )
                    }
                    .disabled(client.isRunning)

                    Button("Disconnect") {
                        client.disconnect()
                    }
                    .disabled(!client.isRunning)

                    Button("Open Remote Window") {
                        openWindow(id: "remote-screen")
                    }

                    Button("Apply Resolution") {
                        client.applyResolution(width: Int(width), height: Int(height))
                    }
                    .disabled(!client.isRunning || fullScreen)
                }

                Text(client.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(client.isError ? .red : .secondary)

                GroupBox("Remote Screen") {
                    VStack(alignment: .leading, spacing: 8) {
                        ZoomControls(zoomScale: $inlineZoomScale)
                            .onChange(of: inlineZoomScale) { _, newScale in
                                client.setResolutionScale(newScale)
                            }

                        ZoomableRemoteCanvas(
                            client: client,
                            frameImage: client.frameImage,
                            emptyText: "接続後に画面が表示されます"
                        )
                        .frame(minHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                GroupBox("Agent Windows") {
                    VStack(alignment: .leading, spacing: 8) {
                        if client.agentWindows.isEmpty {
                            Text("Agent stream待機中または対象ウィンドウなし")
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(client.agentWindows) { win in
                                        Button {
                                            selectedWindowId = win.windowId
                                            controlX = String(win.x)
                                            controlY = String(win.y)
                                            controlW = String(win.width)
                                            controlH = String(win.height)
                                        } label: {
                                            HStack {
                                                Text(String(format: "0x%08X", win.windowId))
                                                    .font(.system(size: 12, design: .monospaced))
                                                Text(win.title.isEmpty ? "(untitled)" : win.title)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text("\(win.x),\(win.y) \(win.width)x\(win.height)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                        }

                        if let selectedWindowId {
                            HStack {
                                Button("Focus") { client.agentFocus(windowId: selectedWindowId) }
                                Button("Close") { client.agentClose(windowId: selectedWindowId) }
                                Spacer()
                            }
                            HStack {
                                TextField("X", text: $controlX).textFieldStyle(.roundedBorder)
                                TextField("Y", text: $controlY).textFieldStyle(.roundedBorder)
                                TextField("W", text: $controlW).textFieldStyle(.roundedBorder)
                                TextField("H", text: $controlH).textFieldStyle(.roundedBorder)
                                Button("Move/Resize") {
                                    client.agentMoveResize(
                                        windowId: selectedWindowId,
                                        x: Int(controlX) ?? 0,
                                        y: Int(controlY) ?? 0,
                                        width: max(1, Int(controlW) ?? 1),
                                        height: max(1, Int(controlH) ?? 1)
                                    )
                                }
                            }
                            if let image = client.croppedImage(for: selectedWindowId) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 180)
                                    .background(Color.black.opacity(0.8))
                            }
                        }
                    }
                }

                GroupBox("Log") {
                    ScrollView {
                        Text(client.outputLog)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 620)
    }
}

struct RemoteScreenView: View {
    @EnvironmentObject private var client: RDPClientService
    @State private var zoomScale = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZoomableRemoteCanvas(
                client: client,
                frameImage: client.frameImage,
                emptyText: "接続後に別ウィンドウで表示されます"
            )
            .onAppear {
                client.syncResolutionToWindowSize(proxy.size)
                client.setResolutionScale(zoomScale)
            }
            .onChange(of: proxy.size) { _, newSize in
                client.syncResolutionToWindowSize(newSize)
            }
            .onChange(of: zoomScale) { _, newScale in
                client.setResolutionScale(newScale)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(client.statusMessage)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            ZoomControls(zoomScale: $zoomScale)
                .padding(12)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

private struct ZoomableRemoteCanvas: View {
    @ObservedObject var client: RDPClientService
    let frameImage: NSImage?
    let emptyText: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)

            if let frameImage {
                GeometryReader { proxy in
                    let rect = fittedRect(container: proxy.size, imageSize: frameImage.size)

                    Image(nsImage: frameImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    RemoteInputCaptureView(
                        currentCursor: client.activeCursor,
                        cursorHidden: client.hideLocalCursor,
                        onMouseMove: { point in
                            if let mapped = mapPoint(point, in: rect, imageSize: frameImage.size) {
                                client.sendMouse(flags: ptrFlagsMove, x: mapped.x, y: mapped.y)
                            }
                        },
                        onMouseButton: { point, button, down in
                            guard let mapped = mapPoint(point, in: rect, imageSize: frameImage.size) else { return }

                            switch button {
                            case 0:
                                let flags = (down ? ptrFlagsDown : 0) | ptrFlagsButton1
                                client.sendMouse(flags: flags, x: mapped.x, y: mapped.y)
                            case 1:
                                let flags = (down ? ptrFlagsDown : 0) | ptrFlagsButton2
                                client.sendMouse(flags: flags, x: mapped.x, y: mapped.y)
                            case 2:
                                let flags = (down ? ptrFlagsDown : 0) | ptrFlagsButton3
                                client.sendMouse(flags: flags, x: mapped.x, y: mapped.y)
                            default:
                                break
                            }
                        },
                        onScroll: { point, deltaY in
                            guard let mapped = mapPoint(point, in: rect, imageSize: frameImage.size),
                                  deltaY != 0 else {
                                return
                            }

                            let magnitude = UInt16(max(1, min(0xFF, Int(abs(deltaY) * 12))))
                            let negative = deltaY < 0 ? ptrFlagsWheelNegative : 0
                            let flags = ptrFlagsWheel | negative | magnitude
                            client.sendMouse(flags: flags, x: mapped.x, y: mapped.y)
                        },
                        onSpecialKey: { keyCode, down in
                            guard let scancode = rdpScancode(for: keyCode) else {
                                return false
                            }
                            client.sendScancodeKey(scancode: scancode, down: down)
                            return true
                        },
                        onUnicodeKey: { code, down in
                            client.sendUnicodeKey(code: code, down: down)
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                Text(emptyText)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func fittedRect(container: CGSize, imageSize: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (container.width - width) * 0.5
        let y = (container.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func mapPoint(_ point: CGPoint, in imageRect: CGRect, imageSize: CGSize) -> (x: Int, y: Int)? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        let clampedX = min(max(point.x, imageRect.minX), imageRect.maxX)
        let clampedY = min(max(point.y, imageRect.minY), imageRect.maxY)
        let normalizedX = (clampedX - imageRect.minX) / imageRect.width
        let normalizedY = (clampedY - imageRect.minY) / imageRect.height
        let topLeftY = 1.0 - normalizedY

        let x = Int(normalizedX * max(1, imageSize.width - 1))
        let y = Int(topLeftY * max(1, imageSize.height - 1))
        return (x: x, y: y)
    }
}

private func makeRdpScancode(_ code: UInt32, extended: Bool = false) -> UInt32 {
    code | (extended ? 0x0100 : 0)
}

private func rdpScancode(for keyCode: UInt16) -> UInt32? {
    switch keyCode {
    case 36: return makeRdpScancode(0x1C)
    case 76: return makeRdpScancode(0x1C, extended: true)
    case 48: return makeRdpScancode(0x0F)
    case 51: return makeRdpScancode(0x0E)
    case 117: return makeRdpScancode(0x53, extended: true)
    case 53: return makeRdpScancode(0x01)
    case 49: return makeRdpScancode(0x39)
    case 122: return makeRdpScancode(0x3B)
    case 120: return makeRdpScancode(0x3C)
    case 99: return makeRdpScancode(0x3D)
    case 118: return makeRdpScancode(0x3E)
    case 96: return makeRdpScancode(0x3F)
    case 97: return makeRdpScancode(0x40)
    case 98: return makeRdpScancode(0x41)
    case 100: return makeRdpScancode(0x42)
    case 101: return makeRdpScancode(0x43)
    case 109: return makeRdpScancode(0x44)
    case 103: return makeRdpScancode(0x57)
    case 111: return makeRdpScancode(0x58)
    case 123: return makeRdpScancode(0x4B, extended: true)
    case 124: return makeRdpScancode(0x4D, extended: true)
    case 125: return makeRdpScancode(0x50, extended: true)
    case 126: return makeRdpScancode(0x48, extended: true)
    case 115: return makeRdpScancode(0x47, extended: true)
    case 119: return makeRdpScancode(0x4F, extended: true)
    case 116: return makeRdpScancode(0x49, extended: true)
    case 121: return makeRdpScancode(0x51, extended: true)
    case 56: return makeRdpScancode(0x2A)
    case 60: return makeRdpScancode(0x36)
    case 59: return makeRdpScancode(0x1D)
    case 62: return makeRdpScancode(0x1D, extended: true)
    case 58: return makeRdpScancode(0x38)
    case 61: return makeRdpScancode(0x38, extended: true)
    case 55: return makeRdpScancode(0x5B, extended: true)
    case 54: return makeRdpScancode(0x5C, extended: true)
    default:
        return nil
    }
}

private struct RemoteInputCaptureView: NSViewRepresentable {
    let currentCursor: NSCursor
    let cursorHidden: Bool
    let onMouseMove: (CGPoint) -> Void
    let onMouseButton: (CGPoint, Int, Bool) -> Void
    let onScroll: (CGPoint, CGFloat) -> Void
    let onSpecialKey: (UInt16, Bool) -> Bool
    let onUnicodeKey: (UInt16, Bool) -> Void

    func makeNSView(context: Context) -> InputCaptureNSView {
        let view = InputCaptureNSView()
        view.currentCursor = currentCursor
        view.cursorHidden = cursorHidden
        view.onMouseMove = onMouseMove
        view.onMouseButton = onMouseButton
        view.onScroll = onScroll
        view.onSpecialKey = onSpecialKey
        view.onUnicodeKey = onUnicodeKey
        return view
    }

    func updateNSView(_ nsView: InputCaptureNSView, context: Context) {
        nsView.currentCursor = currentCursor
        nsView.cursorHidden = cursorHidden
        nsView.onMouseMove = onMouseMove
        nsView.onMouseButton = onMouseButton
        nsView.onScroll = onScroll
        nsView.onSpecialKey = onSpecialKey
        nsView.onUnicodeKey = onUnicodeKey
    }
}

private final class InputCaptureNSView: NSView {
    var currentCursor: NSCursor = .arrow {
        didSet { invalidateCursor() }
    }
    var cursorHidden = false {
        didSet { invalidateCursor() }
    }
    var onMouseMove: ((CGPoint) -> Void)?
    var onMouseButton: ((CGPoint, Int, Bool) -> Void)?
    var onScroll: ((CGPoint, CGFloat) -> Void)?
    var onSpecialKey: ((UInt16, Bool) -> Bool)?
    var onUnicodeKey: ((UInt16, Bool) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private lazy var hiddenCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        invalidateCursor()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorHidden ? hiddenCursor : currentCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        (cursorHidden ? hiddenCursor : currentCursor).set()
    }

    override func mouseMoved(with event: NSEvent) {
        (cursorHidden ? hiddenCursor : currentCursor).set()
        onMouseMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        (cursorHidden ? hiddenCursor : currentCursor).set()
        onMouseMove?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDragged(with event: NSEvent) {
        (cursorHidden ? hiddenCursor : currentCursor).set()
        onMouseMove?(convert(event.locationInWindow, from: nil))
    }

    private func invalidateCursor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseButton?(convert(event.locationInWindow, from: nil), 0, true)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseButton?(convert(event.locationInWindow, from: nil), 0, false)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseButton?(convert(event.locationInWindow, from: nil), 1, true)
    }

    override func rightMouseUp(with event: NSEvent) {
        onMouseButton?(convert(event.locationInWindow, from: nil), 1, false)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.buttonNumber == 2 {
            onMouseButton?(convert(event.locationInWindow, from: nil), 2, true)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onMouseButton?(convert(event.locationInWindow, from: nil), 2, false)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onScroll?(point, event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        if onSpecialKey?(event.keyCode, true) == true {
            return
        }

        for scalar in keyScalars(from: event) {
            onUnicodeKey?(scalar, true)
        }
    }

    override func keyUp(with event: NSEvent) {
        if onSpecialKey?(event.keyCode, false) == true {
            return
        }

        for scalar in keyScalars(from: event) {
            onUnicodeKey?(scalar, false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown: Bool

        switch event.keyCode {
        case 56, 60:
            isDown = modifierFlags.contains(.shift)
        case 59, 62:
            isDown = modifierFlags.contains(.control)
        case 58, 61:
            isDown = modifierFlags.contains(.option)
        case 55, 54:
            isDown = modifierFlags.contains(.command)
        default:
            return
        }

        _ = onSpecialKey?(event.keyCode, isDown)
    }

    private func keyScalars(from event: NSEvent) -> [UInt16] {
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.unicodeScalars.map { UInt16($0.value & 0xFFFF) }
        }

        switch event.keyCode {
        case 36:
            return [13]
        case 48:
            return [9]
        case 51:
            return [8]
        case 117:
            return [127]
        case 53:
            return [27]
        default:
            return []
        }
    }
}

private struct ZoomControls: View {
    @Binding var zoomScale: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("Zoom")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: $zoomScale, in: 0.5...3.0, step: 0.1)
                .frame(width: 140)

            Text("\(zoomScale, specifier: "%.1f")x")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)

            Button("100%") {
                zoomScale = 1.0
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RDPClientService())
}
