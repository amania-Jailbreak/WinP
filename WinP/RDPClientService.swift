import Foundation
import AppKit
import Combine

private struct RDPConnectionProfile {
    let host: String
    let username: String
    let domain: String?
    let remoteAppProgram: String?
    let remoteAppCommandLine: String?
}

struct RemoteAppShortcutExport {
    let name: String
    let host: String
    let username: String
    let domain: String
    let exePath: String
    let titleHint: String?
    let icon: NSImage?
    let staysOpen: Bool
}

struct TaskbarWindow: Identifiable, Equatable {
    let hwnd: UInt64
    let title: String
    let className: String
    let exePath: String?
    let pid: UInt32
    let visible: Bool
    let minimized: Bool
    let active: Bool
    let taskbar: Bool
    let icon: NSImage?
    let iconBMPBase64: String?

    var id: UInt64 { hwnd }
}

private struct WindowsAPIResponse: Decodable {
    let windows: [WindowsAPIWindow]
}

private struct WindowsAPIWindow: Decodable {
    let hwnd: UInt64
    let title: String
    let className: String
    let exePath: String?
    let pid: UInt32
    let visible: Bool
    let minimized: Bool
    let active: Bool
    let taskbar: Bool
    let iconBmpBase64: String?

    enum CodingKeys: String, CodingKey {
        case hwnd
        case title
        case className = "class_name"
        case exePath = "exe_path"
        case pid
        case visible
        case minimized
        case active
        case taskbar
        case iconBmpBase64 = "icon_bmp_base64"
    }
}

private struct ActivateResponse: Decodable {
    let ok: Bool?
    let message: String?
    let hwnd: UInt64?
}

private struct WebSocketEnvelope: Decodable {
    let action: String
    let ok: Bool?
    let message: String?
    let error: String?
    let hwnd: UInt64?
    let windows: [WindowsAPIWindow]?
}

private let remoteAppProgramCanonical = "%windir%\\System32\\cmd.exe"
private let remoteAppProgramLegacy = "C:\\Windows\\System32\\cmd.exe"
private let remoteAppProgramAlias = "||cmd"
private let remoteAppWorkDirCanonical = "%windir%\\system32"

private func canonicalRemoteAppProgram(_ value: String?) -> String {
    guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawValue.isEmpty else {
        return remoteAppProgramAlias
    }
    if rawValue.caseInsensitiveCompare(remoteAppProgramAlias) == .orderedSame {
        return remoteAppProgramAlias
    }
    if rawValue.caseInsensitiveCompare(remoteAppProgramLegacy) == .orderedSame {
        return remoteAppProgramAlias
    }
    if rawValue.caseInsensitiveCompare(remoteAppProgramCanonical) == .orderedSame {
        return remoteAppProgramAlias
    }
    return rawValue
}

private func rdpUsername(username: String, domain: String?) -> String {
    guard let domain, !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return username
    }
    return "\(domain)\\\(username)"
}

private func escapedRdpValue(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
}

private func javaScriptStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
}

@MainActor
final class RDPClientService: ObservableObject {
    @Published var statusMessage = "接続情報を入力してください"
    @Published var outputLog: String = ""
    @Published var isError = false
    @Published var windows: [TaskbarWindow] = []
    @Published var isLoadingWindows = false
    @Published var apiBaseURL: String = ""

    private let webSocketSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketHost: String?
    private var windowsRefreshTask: Task<Void, Never>?
    private var autoSyncHost = ""
    private var autoSyncUsername = ""
    private var autoSyncDomain = ""
    private var liveWindowFingerprints: [UInt64: String] = [:]
    private var liveWindowBundleURLs: [UInt64: URL] = [:]

    func connect(host: String, username: String, domain: String?, remoteAppProgram: String?) {
        let profile = RDPConnectionProfile(
            host: host,
            username: username,
            domain: domain,
            remoteAppProgram: remoteAppProgram,
            remoteAppCommandLine: nil
        )
        launchExternalRemoteApp(with: profile)
    }

    func openExecutableDirectory(host: String, username: String, domain: String?, executablePath: String?) {
        guard let executablePath,
              !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let directory = windowsParentDirectory(for: executablePath)
        let profile = RDPConnectionProfile(
            host: host,
            username: username,
            domain: domain,
            remoteAppProgram: "%windir%\\explorer.exe",
            remoteAppCommandLine: directory
        )
        launchExternalRemoteApp(with: profile)
    }

    func configureAutoSync(host: String, username: String, domain: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        autoSyncHost = trimmedHost
        autoSyncUsername = trimmedUser
        autoSyncDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            return
        }

        appendLog("Live sync: configure host=\(trimmedHost) user=\(trimmedUser)\n")
        loadWindows(host: trimmedHost)
    }

    func exportShortcutApp(_ shortcut: RemoteAppShortcutExport) {
        do {
            let bundleURL = try writeShortcutApp(shortcut, directory: shortcutAppsDirectory(), revealInFinder: true)
            isError = false
            statusMessage = "Dock 用アプリを出力しました"
            appendLog("Shortcut export: bundle=\(bundleURL.path)\n")
        } catch {
            setError("Dock 用アプリ生成失敗: \(error.localizedDescription)")
        }
    }

    private func writeShortcutApp(
        _ shortcut: RemoteAppShortcutExport,
        directory: URL,
        revealInFinder: Bool
    ) throws -> URL {
        let trimmedHost = shortcut.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = shortcut.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExe = shortcut.exePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty, !trimmedExe.isEmpty else {
            throw NSError(
                domain: "WinP.Shortcut",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ショートカット情報が不足しています"]
            )
        }

        let bundleName = sanitizedBundleName(from: shortcut.name)
        let bundleURL = directory.appendingPathComponent("\(bundleName).app", isDirectory: true)
        let scriptSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WinP", isDirectory: true)
            .appendingPathComponent("ShortcutSources", isDirectory: true)
            .appendingPathComponent("\(bundleName).jxa", isDirectory: false)

        let profile = RDPConnectionProfile(
            host: trimmedHost,
            username: trimmedUser,
            domain: shortcut.domain.isEmpty ? nil : shortcut.domain,
            remoteAppProgram: trimmedExe,
            remoteAppCommandLine: nil
        )
        let rdpContents = rdpFileContents(for: profile)
        let script = shortcutAppletScript(
            host: trimmedHost,
            exePath: trimmedExe,
            titleHint: shortcut.titleHint,
            rdpContents: rdpContents,
            slug: sanitizedScriptSlug(from: shortcut.name),
            staysOpen: shortcut.staysOpen
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scriptSourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        terminateRunningApp(at: bundleURL)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
        try script.write(to: scriptSourceURL, atomically: true, encoding: .utf8)

        var osacompileArguments = ["-l", "JavaScript"]
        if shortcut.staysOpen {
            osacompileArguments.append("-s")
        }
        osacompileArguments.append(contentsOf: ["-o", bundleURL.path, scriptSourceURL.path])

        let output = try runProcess(
            launchPath: "/usr/bin/osacompile",
            arguments: osacompileArguments
        )

        if let icon = shortcut.icon {
            _ = NSWorkspace.shared.setIcon(icon, forFile: bundleURL.path, options: [])
        }
        if revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
        if !output.isEmpty {
            appendLog("Shortcut export: osacompile=\(output)\n")
        }
        return bundleURL
    }

    private func launchExternalRemoteApp(with profile: RDPConnectionProfile) {
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Hostを入力してください")
            return
        }
        guard !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Usernameを入力してください")
            return
        }

        apiBaseURL = "http://\(profile.host):8000"
        connectWebSocketIfNeeded(host: profile.host)

        let lines = rdpFileContents(for: profile)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WinP", isDirectory: true)
            .appendingPathComponent("RemoteApps", isDirectory: true)
        let sanitizedHost = profile.host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileURL = directory.appendingPathComponent("\(sanitizedHost)-remoteapp.rdp")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try lines.joined(separator: "\r\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            setError("ファイル生成失敗: \(error.localizedDescription)")
            appendLog("RemoteApp external launch: failed to write rdp file \(fileURL.path) error=\(error)\n")
            return
        }

        appendLog("RemoteApp external launch: rdp file=\(fileURL.path)\n")
        fputs("[WinP] RemoteApp external launch: rdp file=\(fileURL.path)\n", stderr)

        if NSWorkspace.shared.open(fileURL) {
            isError = false
            statusMessage = "RDPファイルを作成して既定アプリで開きました"
            appendLog("RemoteApp external launch: opened \(fileURL.path)\n")
            loadWindows(host: profile.host)
        } else {
            setError("RDPファイルを開けませんでした")
            appendLog("RemoteApp external launch: failed to open \(fileURL.path)\n")
        }
    }

    private func rdpFileContents(for profile: RDPConnectionProfile) -> [String] {
        let remoteAppProgram = canonicalRemoteAppProgram(profile.remoteAppProgram)
        let username = rdpUsername(username: profile.username, domain: profile.domain)
        let commandLine = escapedRdpValue(profile.remoteAppCommandLine ?? "")
        return [
            "full address:s:\(escapedRdpValue(profile.host))",
            "username:s:\(escapedRdpValue(username))",
            "screen mode id:i:1",
            "remoteapplicationmode:i:1",
            "remoteapplicationprogram:s:\(escapedRdpValue(remoteAppProgram))",
            "remoteapplicationname:s:WinP RemoteApp",
            "remoteapplicationcmdline:s:\(commandLine)",
            "alternate shell:s:",
            "shell working directory:s:\(escapedRdpValue(remoteAppWorkDirCanonical))",
            "prompt for credentials:i:1",
            "authentication level:i:0",
            "negotiate security layer:i:1",
            "audiomode:i:2",
            "redirectclipboard:i:1",
            "drivestoredirect:s:",
            ""
        ]
    }

    private func shortcutAppletScript(
        host: String,
        exePath: String,
        titleHint: String?,
        rdpContents: [String],
        slug: String,
        staysOpen: Bool
    ) -> String {
        let payload = rdpContents.joined(separator: "\r\n")
        let titleLiteral = titleHint.map(javaScriptStringLiteral) ?? "null"
        return """
        ObjC.import('AppKit');

        var app = Application.currentApplication();
        app.includeStandardAdditions = true;

        var config = {
            host: \(javaScriptStringLiteral(host)),
            exePath: \(javaScriptStringLiteral(exePath)),
            titleHint: \(titleLiteral),
            rdpContents: \(javaScriptStringLiteral(payload)),
            slug: \(javaScriptStringLiteral(slug)),
            staysOpen: \(staysOpen ? "true" : "false")
        };
        var apiBase = "http://" + config.host + ":8000";
        var lastLaunchAt = 0;
        var targetHwnd = null;
        var lastActiveHwnd = null;

        function shellQuote(value) {
            return "'" + String(value).replace(/'/g, "'\\''") + "'";
        }

        function normalize(value) {
            return String(value || "").toLowerCase();
        }

        function fetchWindows() {
            try {
                var command = "/usr/bin/curl -sf --max-time 2 " + shellQuote(apiBase + "/windows?taskbar_only=true&include_exe=true");
                var raw = app.doShellScript(command);
                var decoded = JSON.parse(raw);
                return decoded.windows || [];
            } catch (error) {
                return [];
            }
        }

        function preferredWindow() {
            var matching = fetchWindows().filter(function (item) {
                return normalize(item.exe_path) === normalize(config.exePath);
            });

            if (matching.length === 0) {
                return null;
            }

            var activeMatches = matching.filter(function (item) { return !!item.active; });
            if (activeMatches.length > 0) {
                lastActiveHwnd = activeMatches[0].hwnd;
            }

            if (lastActiveHwnd !== null) {
                var lastActiveMatches = matching.filter(function (item) {
                    return Number(item.hwnd) === Number(lastActiveHwnd);
                });
                if (lastActiveMatches.length > 0) {
                    return lastActiveMatches[0];
                }
            }

            if (config.titleHint) {
                var exactTitle = matching.filter(function (item) {
                    return normalize(item.title) === normalize(config.titleHint);
                });
                if (exactTitle.length > 0) {
                    var activeExact = exactTitle.filter(function (item) { return !!item.active; });
                    if (activeExact.length > 0) {
                        lastActiveHwnd = activeExact[0].hwnd;
                    }
                    return activeExact[0] || exactTitle[0];
                }
            }

            return activeMatches[0] || matching[0];
        }

        function targetWindow() {
            var windows = fetchWindows();

            if (targetHwnd !== null) {
                var exact = windows.filter(function (item) {
                    return Number(item.hwnd) === Number(targetHwnd);
                });
                if (exact.length > 0) {
                    return exact[0];
                }
            }

            var preferred = preferredWindow();
            if (preferred) {
                targetHwnd = preferred.hwnd;
                return preferred;
            }

            return null;
        }

        function activateWindow(hwnd) {
            var payload = JSON.stringify({ hwnd: hwnd });
            var command = "/usr/bin/curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' -d "
                + shellQuote(payload) + " " + shellQuote(apiBase + "/activate");
            app.doShellScript(command);
        }

        function requestRemoteExit() {
            var payload = JSON.stringify({ delay_ms: 300 });
            var command = "/usr/bin/curl -sf --max-time 2 -X POST -H 'Content-Type: application/json' -d "
                + shellQuote(payload) + " " + shellQuote(apiBase + "/exit");
            try {
                app.doShellScript(command);
            } catch (error) {
            }
        }

        function launchRemoteApp() {
            var tmpRoot = "/private/tmp/WinP";
            app.doShellScript("/bin/mkdir -p " + shellQuote(tmpRoot));
            var tmpBase = app.doShellScript("/usr/bin/mktemp " + shellQuote(tmpRoot + "/" + config.slug + ".XXXXXX"));
            var rdpFile = tmpBase + ".rdp";
            var command = "/bin/cat > " + shellQuote(rdpFile) + " <<'RDP'\\n" + config.rdpContents + "\\nRDP\\n"
                + "/usr/bin/open " + shellQuote(rdpFile);
            app.doShellScript(command);
            lastLaunchAt = Date.now();
        }

        function ensureWindow(shouldActivate) {
            var existing = targetWindow();
            if (existing) {
                targetHwnd = existing.hwnd;
                if (shouldActivate) {
                    activateWindow(existing.hwnd);
                }
                return true;
            }
            launchRemoteApp();
            return false;
        }

        function run() {
            ensureWindow(false);
            if (!config.staysOpen) {
                $.NSApplication.sharedApplication.terminate(null);
            }
        }

        function reopen() {
            ensureWindow(true);
        }

        function idle() {
            var existing = targetWindow();
            if (existing) {
                return 0.5;
            }
            if (lastLaunchAt > 0 && (Date.now() - lastLaunchAt) < 15000) {
                var lateWindow = targetWindow();
                if (lateWindow) {
                    targetHwnd = lateWindow.hwnd;
                    return 0.5;
                }
                return 0.5;
            }
            $.NSApplication.sharedApplication.terminate(null);
            return 0;
        }

        function quit() {
            if (config.staysOpen) {
                requestRemoteExit();
            }
        }
        """
    }

    private func sanitizedBundleName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "WinP Shortcut" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = fallback.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "WinP Shortcut" : cleaned
    }

    private func sanitizedScriptSlug(from value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "shortcut" : result.lowercased()
    }

    private func windowsParentDirectory(for executablePath: String) -> String {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSeparator = trimmed.lastIndex(where: { $0 == "\\" || $0 == "/" }) else {
            return trimmed
        }
        return String(trimmed[..<lastSeparator])
    }

    private func shortcutAppsDirectory() -> URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent("WinP Shortcuts", isDirectory: true)
    }

    private func liveWindowAppsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("WinP Live Windows", isDirectory: true)
    }

    private func liveWindowBundleName(for window: TaskbarWindow) -> String {
        let base = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ((window.exePath as NSString?)?.lastPathComponent ?? "Window")
            : window.title
        return "\(base) [\(window.hwnd)]"
    }

    private func syncLiveWindowApps() {
        guard !autoSyncHost.isEmpty else {
            return
        }

        let currentWindows = windows.filter { window in
            guard let exePath = window.exePath, !exePath.isEmpty else {
                return false
            }
            if window.title.localizedCaseInsensitiveContains("RemoteApp Maker") {
                return false
            }
            return window.visible && !window.minimized
        }
        let liveDirectory = liveWindowAppsDirectory()

        do {
            try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        } catch {
            appendLog("Live sync: directory error \(error.localizedDescription)\n")
            return
        }

        let currentIDs = Set(currentWindows.map(\.hwnd))

        for window in currentWindows {
            let fingerprint = [
                window.title,
                window.exePath ?? "",
                window.iconBMPBase64 ?? ""
            ].joined(separator: "|")

            let desiredBundleURL = liveDirectory.appendingPathComponent("\(liveWindowBundleName(for: window)).app", isDirectory: true)

            if liveWindowFingerprints[window.hwnd] == fingerprint,
               liveWindowBundleURLs[window.hwnd] == desiredBundleURL {
                continue
            }

            let shortcut = RemoteAppShortcutExport(
                name: liveWindowBundleName(for: window),
                host: autoSyncHost,
                username: autoSyncUsername,
                domain: autoSyncDomain,
                exePath: window.exePath ?? "",
                titleHint: window.title,
                icon: window.icon,
                staysOpen: true
            )

            do {
                if let existingURL = liveWindowBundleURLs[window.hwnd],
                   existingURL != desiredBundleURL {
                    terminateRunningApp(at: existingURL)
                    if FileManager.default.fileExists(atPath: existingURL.path) {
                        try? FileManager.default.removeItem(at: existingURL)
                    }
                }

                let bundleURL = try writeShortcutApp(shortcut, directory: liveDirectory, revealInFinder: false)
                liveWindowFingerprints[window.hwnd] = fingerprint
                liveWindowBundleURLs[window.hwnd] = bundleURL
                if !isLiveWindowAppRunning(bundleURL) {
                    openLiveWindowApp(bundleURL)
                }
            } catch {
                appendLog("Live sync: hwnd=\(window.hwnd) error=\(error.localizedDescription)\n")
            }
        }

        let staleIDs = Set(liveWindowFingerprints.keys).subtracting(currentIDs)
        for hwnd in staleIDs {
            liveWindowFingerprints.removeValue(forKey: hwnd)
            liveWindowBundleURLs.removeValue(forKey: hwnd)
        }
    }

    private func openLiveWindowApp(_ bundleURL: URL) {
        Task { @MainActor in
            do {
                _ = try runProcess(
                    launchPath: "/usr/bin/open",
                    arguments: ["-g", bundleURL.path]
                )
                appendLog("Live sync: opened \(bundleURL.lastPathComponent)\n")
            } catch {
                appendLog("Live sync: open failed \(bundleURL.lastPathComponent) error=\(error.localizedDescription)\n")
            }
        }
    }

    private func isLiveWindowAppRunning(_ bundleURL: URL) -> Bool {
        let targetURL = bundleURL.standardizedFileURL
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleURL?.standardizedFileURL == targetURL
        }
    }

    private func terminateRunningApp(at bundleURL: URL) {
        let targetURL = bundleURL.standardizedFileURL
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleURL?.standardizedFileURL == targetURL
        }

        for app in runningApps {
            _ = app.forceTerminate()
        }

        if !runningApps.isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func runProcess(launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let combined = [stdoutData, stderrData]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WinP.Process",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: combined.isEmpty ? "\(launchPath) failed" : combined
                ]
            )
        }

        return combined
    }

    func loadWindows(host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            setError("Hostを入力してください")
            return
        }

        isLoadingWindows = true
        apiBaseURL = "http://\(trimmedHost):8000"
        statusMessage = "タスクバー一覧を取得中..."

        connectWebSocketIfNeeded(host: trimmedHost)
        if sendWebSocket([
            "action": "list_windows",
            "taskbar_only": true,
            "include_icon": true,
            "include_exe": true
        ]) {
            return
        }

        Task {
            do {
                let url = URL(string: "\(apiBaseURL)/windows?taskbar_only=true&include_icon=true&include_exe=true")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                let decoded = try JSONDecoder().decode(WindowsAPIResponse.self, from: data)
                let mapped = decoded.windows.map { item in
                    TaskbarWindow(
                        hwnd: item.hwnd,
                        title: item.title.isEmpty ? "(untitled)" : item.title,
                        className: item.className,
                        exePath: item.exePath,
                        pid: item.pid,
                        visible: item.visible,
                        minimized: item.minimized,
                        active: item.active,
                        taskbar: item.taskbar,
                        icon: decodeIcon(from: item.iconBmpBase64),
                        iconBMPBase64: item.iconBmpBase64
                    )
                }

                windows = mapped.sorted { lhs, rhs in
                    if lhs.active != rhs.active { return lhs.active && !rhs.active }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                isLoadingWindows = false
                isError = false
                statusMessage = "タスクバー一覧を取得しました"
                appendLog("Windows API: loaded \(windows.count) taskbar windows from \(apiBaseURL)\n")
            } catch {
                isLoadingWindows = false
                setError("ウィンドウ一覧取得失敗: \(error.localizedDescription)")
            }
        }
    }

    func activateWindow(_ window: TaskbarWindow) {
        guard !apiBaseURL.isEmpty else {
            setError("先にウィンドウ一覧を取得してください")
            return
        }

        statusMessage = "ウィンドウをアクティブ化中..."
        if sendWebSocket([
            "action": "activate",
            "hwnd": window.hwnd
        ]) {
            return
        }

        guard let url = URL(string: "\(apiBaseURL)/activate") else {
            setError("先にウィンドウ一覧を取得してください")
            return
        }

        Task {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["hwnd": window.hwnd])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "WinP.WindowsAPI", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: body.isEmpty ? "status \(http.statusCode)" : body
                    ])
                }

                _ = try? JSONDecoder().decode(ActivateResponse.self, from: data)
                statusMessage = "ウィンドウをアクティブ化しました"
                isError = false
                appendLog("Windows API: activated hwnd=\(window.hwnd)\n")
                loadWindows(host: apiBaseURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: ":8000", with: ""))
            } catch {
                setError("アクティブ化失敗: \(error.localizedDescription)")
            }
        }
    }

    private func connectWebSocketIfNeeded(host: String) {
        if webSocketHost == host, webSocketTask != nil {
            return
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketHost = host

        guard let url = URL(string: "ws://\(host):8000/ws") else {
            return
        }

        let task = webSocketSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        receiveWebSocketMessages()
        startWindowsRefreshLoop()
        appendLog("Windows API WebSocket: connected ws://\(host):8000/ws\n")
    }

    private func receiveWebSocketMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleWebSocketText(text)
                    case .data(let data):
                        self.handleWebSocketData(data)
                    @unknown default:
                        break
                    }
                    self.receiveWebSocketMessages()
                case .failure(let error):
                    self.appendLog("Windows API WebSocket: receive failed \(error.localizedDescription)\n")
                    self.webSocketTask = nil
                    self.stopWindowsRefreshLoop()
                }
            }
        }
    }

    private func handleWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        handleWebSocketData(data)
    }

    private func handleWebSocketData(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(WebSocketEnvelope.self, from: data) else {
            appendLog("Windows API WebSocket: invalid payload\n")
            return
        }

        switch envelope.action {
        case "list_windows":
            if envelope.ok == true, let windowsPayload = envelope.windows {
                applyWindowsPayload(windowsPayload)
                isLoadingWindows = false
                isError = false
                statusMessage = "タスクバー一覧を取得しました"
                appendLog("Windows API WebSocket: loaded \(windows.count) taskbar windows\n")
            } else {
                isLoadingWindows = false
                setError("ウィンドウ一覧取得失敗: \(envelope.error ?? envelope.message ?? "unknown")")
            }
        case "activate":
            if envelope.ok == true {
                statusMessage = "ウィンドウをアクティブ化しました"
                isError = false
                appendLog("Windows API WebSocket: activated hwnd=\(envelope.hwnd ?? 0)\n")
                if let host = webSocketHost {
                    loadWindows(host: host)
                }
            } else {
                setError("アクティブ化失敗: \(envelope.error ?? envelope.message ?? "unknown")")
            }
        case "pong":
            break
        default:
            appendLog("Windows API WebSocket: unhandled action \(envelope.action)\n")
        }
    }

    private func sendWebSocket(_ payload: [String: Any]) -> Bool {
        guard let webSocketTask else { return false }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }

        webSocketTask.send(.string(text)) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.appendLog("Windows API WebSocket: send failed \(error.localizedDescription)\n")
                    self.webSocketTask = nil
                }
            }
        }
        return true
    }

    private func startWindowsRefreshLoop() {
        windowsRefreshTask?.cancel()
        windowsRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                await MainActor.run {
                    guard self.webSocketTask != nil, self.webSocketHost != nil else { return }
                    _ = self.sendWebSocket([
                        "action": "list_windows",
                        "taskbar_only": true,
                        "include_icon": true,
                        "include_exe": true
                    ])
                }
            }
        }
    }

    private func stopWindowsRefreshLoop() {
        windowsRefreshTask?.cancel()
        windowsRefreshTask = nil
    }

    private func applyWindowsPayload(_ payload: [WindowsAPIWindow]) {
        let mapped = payload.map { item in
            TaskbarWindow(
                hwnd: item.hwnd,
                title: item.title.isEmpty ? "(untitled)" : item.title,
                className: item.className,
                exePath: item.exePath,
                pid: item.pid,
                visible: item.visible,
                minimized: item.minimized,
                active: item.active,
                taskbar: item.taskbar,
                icon: decodeIcon(from: item.iconBmpBase64),
                iconBMPBase64: item.iconBmpBase64
            )
        }

        windows = mapped.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active && !rhs.active }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        syncLiveWindowApps()
    }

    private func decodeIcon(from base64: String?) -> NSImage? {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else {
            return nil
        }
        return transparentizingBlackBackground(from: image)
    }

    private func transparentizingBlackBackground(from image: NSImage) -> NSImage {
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

    private func appendLog(_ text: String) {
        outputLog.append(text)
    }

    private func setError(_ message: String) {
        isError = true
        statusMessage = message
        appendLog("Error: \(message)\n")
    }
}
