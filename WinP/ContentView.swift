//
//  ContentView.swift
//  WinP
//
//  Created by amania on 2026/03/18.
//

import SwiftUI

private func transparentizingShortcutBlackBackground(from image: NSImage) -> NSImage {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return image
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixels,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return image
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    for index in stride(from: 0, to: pixels.count, by: 4) {
        let red = pixels[index]
        let green = pixels[index + 1]
        let blue = pixels[index + 2]
        let alpha = pixels[index + 3]

        if alpha > 0 && red < 12 && green < 12 && blue < 12 {
            pixels[index + 3] = 0
        }
    }

    guard let output = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage() else {
        return image
    }

    return NSImage(cgImage: output, size: NSSize(width: width, height: height))
}

private struct RemoteAppShortcut: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var username: String
    var domain: String
    var exePath: String
    var windowTitleHint: String?
    var iconBMPBase64: String?

    var icon: NSImage? {
        guard let iconBMPBase64,
              let data = Data(base64Encoded: iconBMPBase64),
              let image = NSImage(data: data) else {
            return nil
        }
        return transparentizingShortcutBlackBackground(from: image)
    }
}

private struct ShortcutDraft: Identifiable {
    let id = UUID()
    let window: TaskbarWindow
    var name: String
}

struct ContentView: View {
    @EnvironmentObject private var client: RDPClientService

    @AppStorage("connection.host") private var host = ""
    @AppStorage("connection.username") private var username = ""
    @AppStorage("connection.domain") private var domain = ""
    @AppStorage("connection.remoteAppProgram") private var remoteAppProgram = "||cmd"
    @AppStorage("shortcuts.remote_app") private var shortcutsData = "[]"

    @State private var shortcutDraft: ShortcutDraft?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.08, green: 0.09, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.18, green: 0.32, blue: 0.58).opacity(0.28))
                .frame(width: 360, height: 360)
                .blur(radius: 30)
                .offset(x: 260, y: -220)

            Circle()
                .fill(Color(red: 0.12, green: 0.48, blue: 0.45).opacity(0.18))
                .frame(width: 300, height: 300)
                .blur(radius: 36)
                .offset(x: -260, y: 260)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroSection
                    shortcutsCard
                    launcherCard
                    windowsCard
                }
                .padding(24)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 650, height: 720)
        .sheet(item: $shortcutDraft) { draft in
            shortcutSheet(draft: draft)
        }
        .task {
            client.configureAutoSync(host: host, username: username, domain: domain)
        }
        .onChange(of: host) { _, newValue in
            client.configureAutoSync(host: newValue, username: username, domain: domain)
        }
        .onChange(of: username) { _, newValue in
            client.configureAutoSync(host: host, username: newValue, domain: domain)
        }
        .onChange(of: domain) { _, newValue in
            client.configureAutoSync(host: host, username: username, domain: newValue)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WinP(仮のすがた)")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text("RemoteApp Launcher")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
        }
        .padding(.horizontal, 4)
    }

    private var launcherCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connection")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("必要な項目だけ入力して起動します")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.56))
                }
                Spacer()
                statusPill
            }

            VStack(spacing: 12) {
                richField(title: "Host", prompt: "192.168.1.10 または server.example.local", text: $host)
                richField(title: "Username", prompt: "username", text: $username)
                richField(title: "Domain", prompt: "optional", text: $domain)
                richField(title: "RemoteApp Program", prompt: "||cmd", text: $remoteAppProgram)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Presets")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    presetButton(title: "Command Prompt", value: "%windir%\\System32\\cmd.exe")
                    presetButton(title: "PowerShell", value: "%windir%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
                    presetButton(title: "Explorer", value: "%windir%\\explorer.exe")
                }
            }

            HStack(spacing: 12) {
                Button {
                    client.connect(
                        host: host,
                        username: username,
                        domain: domain.isEmpty ? nil : domain,
                        remoteAppProgram: remoteAppProgram.isEmpty ? nil : remoteAppProgram
                    )
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("OPEN")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.28, blue: 0.54),
                                Color(red: 0.16, green: 0.45, blue: 0.70)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .opacity(canOpen ? 1.0 : 0.45)
                .disabled(!canOpen)

                Button {
                    client.loadWindows(host: host)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.stack.fill")
                        Text("WINDOWS")
                            .fontWeight(.semibold)
                    }
                    .frame(width: 156, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .opacity(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1.0)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 30, y: 20)
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("保存したアプリをすぐ起動できます。")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.56))
                }
                Spacer()
            }

            if shortcuts.isEmpty {
                Text("まだショートカットはありません。下の一覧から追加してください。")
                    .foregroundStyle(Color.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(shortcuts) { shortcut in
                        HStack(spacing: 10) {
                            Button {
                                client.connect(
                                    host: shortcut.host,
                                    username: shortcut.username,
                                    domain: shortcut.domain.isEmpty ? nil : shortcut.domain,
                                    remoteAppProgram: shortcut.exePath
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    shortcutIcon(shortcut)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(shortcut.name)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(shortcut.exePath)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.45))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                client.exportShortcutApp(
                                    RemoteAppShortcutExport(
                                        name: shortcut.name,
                                        host: shortcut.host,
                                        username: shortcut.username,
                                        domain: shortcut.domain,
                                        exePath: shortcut.exePath,
                                        titleHint: shortcut.windowTitleHint,
                                        icon: shortcut.icon,
                                        staysOpen: false
                                    )
                                )
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "dock.rectangle")
                                        .font(.system(size: 17, weight: .semibold))
                                    Text("APP")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                }
                                .frame(width: 60, height: 60)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }
                        .contextMenu {
                            Button("実行ファイルの場所を開く") {
                                client.openExecutableDirectory(
                                    host: shortcut.host,
                                    username: shortcut.username,
                                    domain: shortcut.domain.isEmpty ? nil : shortcut.domain,
                                    executablePath: shortcut.exePath
                                )
                            }
                            .disabled(shortcut.exePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Dock用アプリを作成") {
                                client.exportShortcutApp(
                                    RemoteAppShortcutExport(
                                        name: shortcut.name,
                                        host: shortcut.host,
                                        username: shortcut.username,
                                        domain: shortcut.domain,
                                        exePath: shortcut.exePath,
                                        titleHint: shortcut.windowTitleHint,
                                        icon: shortcut.icon,
                                        staysOpen: false
                                    )
                                )
                            }
                            Button("削除", role: .destructive) {
                                removeShortcut(shortcut)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 30, y: 20)
    }

    private var windowsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Taskbar Windows")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Windows API から取得した一覧です。クリックするとアクティブ化します。")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.56))
                }
                Spacer()
                if client.isLoadingWindows {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }

            if client.windows.isEmpty {
                Text("まだ一覧はありません。`WINDOWS` を押して取得してください。")
                    .foregroundStyle(Color.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            } else {
                VStack(spacing: 10) {
                    ForEach(client.windows) { window in
                        Button {
                            client.activateWindow(window)
                        } label: {
                            TaskbarWindowRow(
                                window: window,
                                onAddShortcut: {
                                    guard let exePath = window.exePath, !exePath.isEmpty else { return }
                                    shortcutDraft = ShortcutDraft(window: window, name: window.title)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("実行ファイルの場所を開く") {
                                client.openExecutableDirectory(
                                    host: host,
                                    username: username,
                                    domain: domain.isEmpty ? nil : domain,
                                    executablePath: window.exePath
                                )
                            }
                            .disabled((window.exePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 30, y: 20)
    }

    private var statusPill: some View {
        Text(client.statusMessage)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(client.isError ? Color.red : Color(red: 0.15, green: 0.39, blue: 0.27))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                client.isError
                    ? Color.red.opacity(0.10)
                    : Color.green.opacity(0.12),
                in: Capsule()
            )
    }

    private var canOpen: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shortcuts: [RemoteAppShortcut] {
        guard let data = shortcutsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RemoteAppShortcut].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveShortcuts(_ items: [RemoteAppShortcut]) {
        guard let data = try? JSONEncoder().encode(items),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        shortcutsData = text
    }

    private func removeShortcut(_ shortcut: RemoteAppShortcut) {
        saveShortcuts(shortcuts.filter { $0.id != shortcut.id })
    }

    private func shortcutSheet(draft: ShortcutDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ショートカットを追加")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(draft.window.exePath ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField(
                "表示名",
                text: Binding(
                    get: { shortcutDraft?.name ?? draft.name },
                    set: { newValue in
                        guard var current = shortcutDraft else { return }
                        current.name = newValue
                        shortcutDraft = current
                    }
                )
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("キャンセル") {
                    shortcutDraft = nil
                }
                Button("保存") {
                    guard let current = shortcutDraft,
                          let exePath = current.window.exePath,
                          !exePath.isEmpty else { return }
                    let item = RemoteAppShortcut(
                        id: UUID(),
                        name: current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? current.window.title : current.name,
                        host: host,
                        username: username,
                        domain: domain,
                        exePath: exePath,
                        windowTitleHint: current.window.title,
                        iconBMPBase64: current.window.iconBMPBase64
                    )
                    var items = shortcuts
                    items.append(item)
                    saveShortcuts(items)
                    shortcutDraft = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func richField(title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))

            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .foregroundStyle(.white)
        }
    }

    private func presetButton(title: String, value: String) -> some View {
        Button {
            remoteAppProgram = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(remoteAppProgram == value ? Color(red: 0.17, green: 0.39, blue: 0.67) : Color.white.opacity(0.08))
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func shortcutIcon(_ shortcut: RemoteAppShortcut) -> some View {
        Group {
            if let icon = shortcut.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .frame(width: 34, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}

private struct TaskbarWindowRow: View {
    let window: TaskbarWindow
    let onAddShortcut: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            iconView
            textBlock
            Spacer()
            addButton
            activePill
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(window.active ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(window.active ? 0.18 : 0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var iconView: some View {
        Group {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .frame(width: 38, height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(window.className)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var addButton: some View {
        Button {
            onAddShortcut()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity((window.exePath?.isEmpty == false) ? 1.0 : 0.35)
        .disabled(window.exePath?.isEmpty != false)
    }

    @ViewBuilder
    private var activePill: some View {
        if window.active {
            Text("ACTIVE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white, in: Capsule())
        }
    }
}
