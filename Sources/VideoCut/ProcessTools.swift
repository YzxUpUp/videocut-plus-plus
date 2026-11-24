import Foundation
import Darwin

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Tools {
    static let files = FileManager.default
    static let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VideoCut++", isDirectory: true)
    static let model = support.appendingPathComponent("Models/ggml-base.bin")
    static let python = support.appendingPathComponent("venv/bin/python")
    static let script = Bundle.main.url(forResource: "watermark", withExtension: "py")
        ?? URL(fileURLWithPath: "Tools/watermark.py").standardizedFileURL
    static let setup = Bundle.main.url(forResource: "setup", withExtension: "sh")
        ?? URL(fileURLWithPath: "Tools/setup.sh").standardizedFileURL
    static let searchPath = [
        "/opt/homebrew/bin", "/opt/homebrew/opt/node@24/bin",
        "/usr/local/bin", "/usr/bin", "/bin"
    ]

    static func executable(_ name: String) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { files.isExecutableFile(atPath: $0.path) }
    }

    static var missing: [String] {
        var items = ["yt-dlp", "ffmpeg", "ffprobe", "whisper-cli", "deno"]
            .filter { executable($0) == nil }
        if !files.isReadableFile(atPath: model.path) { items.append("Whisper 中文转写模型") }
        if !files.isExecutableFile(atPath: python.path)
            || !files.isReadableFile(atPath: support.appendingPathComponent("venv/.watermark-ready").path) {
            items.append("OpenCV / Vision 水印组件")
        }
        return items
    }

    static func run(_ name: String, _ arguments: [String], in directory: URL,
                    progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let url = executable(name) else { throw AppError("缺少 \(name)，请在设置里安装依赖。") }
        return try await run(url, arguments, in: directory, progress: progress)
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL,
                    progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        let log = directory.appendingPathComponent(".process-\(UUID().uuidString).log")
        guard files.createFile(atPath: log.path, contents: nil) else {
            throw AppError("无法写入工作目录。")
        }
        defer { try? files.removeItem(at: log) }
        let writer = try FileHandle(forWritingTo: log)
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? writer.close(); try? reader.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = writer
        process.standardError = writer
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try process.run()
        var pending = Data()
        do {
            while process.isRunning {
                if let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<end], as: UTF8.self)
                        progress?(line)
                        pending.removeSubrange(...end)
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning {
                let pid = process.processIdentifier
                let target = getpgid(pid) == pid ? -pid : pid
                kill(target, SIGTERM)
                for _ in 0..<8 where process.isRunning {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                }
                if process.isRunning { kill(target, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        try Task.checkCancellation()
        try reader.seek(toOffset: 0)
        let output = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let lines = output.split(whereSeparator: \.isNewline)
            let diagnostics = lines.filter { $0.contains("ERROR") || $0.contains("Error") }
            let tail = (diagnostics.isEmpty ? lines : diagnostics).suffix(4).joined(separator: "\n")
            throw AppError(tail.isEmpty ? "处理程序退出（\(process.terminationStatus)）。" : tail)
        }
        return output
    }
}
