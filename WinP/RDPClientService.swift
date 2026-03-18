import Foundation

@MainActor
final class RDPClientService: ObservableObject {
    @Published var statusMessage: String = "接続情報を入力してください"
    @Published var outputLog: String = ""
    @Published var isRunning = false
    @Published var isError = false

    private var process: Process?

    func connect(
        host: String,
        username: String,
        password: String,
        domain: String?,
        fullScreen: Bool,
        width: Int?,
        height: Int?
    ) {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Hostを入力してください")
            return
        }

        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setError("Usernameを入力してください")
            return
        }

        guard !password.isEmpty else {
            setError("Passwordを入力してください")
            return
        }

        let freeRDPPath = "/usr/local/bin/xfreerdp"
        guard FileManager.default.isExecutableFile(atPath: freeRDPPath) else {
            setError("xfreerdp が見つかりません: \(freeRDPPath)")
            return
        }

        disconnect()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: freeRDPPath)
        proc.arguments = makeArguments(
            host: host,
            username: username,
            password: password,
            domain: domain,
            fullScreen: fullScreen,
            width: width,
            height: height
        )

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
                self?.statusMessage = "切断されました (exit: \(terminated.terminationStatus))"
                self?.isError = terminated.terminationStatus != 0
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            isError = false
            statusMessage = "接続中..."
            appendLog("Started: \(freeRDPPath) \(proc.arguments?.joined(separator: " ") ?? "")\n")
        } catch {
            setError("起動失敗: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        guard let process else { return }
        process.terminate()
        self.process = nil
        isRunning = false
        statusMessage = "切断しました"
        isError = false
    }

    private func makeArguments(
        host: String,
        username: String,
        password: String,
        domain: String?,
        fullScreen: Bool,
        width: Int?,
        height: Int?
    ) -> [String] {
        var args: [String] = [
            "/v:\(host)",
            "/u:\(username)",
            "/p:\(password)",
            "/cert:ignore"
        ]

        if let domain, !domain.isEmpty {
            args.append("/d:\(domain)")
        }

        if fullScreen {
            args.append("/f")
        } else if let width, let height, width > 0, height > 0 {
            args.append("/size:\(width)x\(height)")
        }

        return args
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
