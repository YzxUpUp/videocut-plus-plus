import Foundation

struct FrameSample {
    let seconds: Double
    let url: URL
}

struct MaskSeed: Codable {
    let seconds: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct WatermarkReport: Decodable {
    struct Interval: Decodable, Identifiable {
        let start: Double
        let end: Double
        var id: Double { start }
    }
    let detected: Int
    let repairedFrames: Int
    let uncertain: [Interval]
}

enum Media {
    static func download(_ link: URL, directory: URL, cookies: URL? = nil,
                         progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let ffmpeg = Tools.executable("ffmpeg") else { throw AppError("下载合并需要 FFmpeg。") }
        var options = [
            "--ignore-config", "--no-playlist", "--newline", "--progress", "--retries", "3",
            "--socket-timeout", "20", "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "-f", "bv*[vcodec^=avc1][format_note!*=?watermarked]+ba/b[vcodec^=avc1][format_note!*=?watermarked]/bv*[format_note!*=?watermarked]+ba/b[format_note!*=?watermarked]/bv*+ba/b", "--merge-output-format", "mp4",
            "--windows-filenames", "-o", "source.%(ext)s", "--print", "after_move:VIDEOCUT_FILE:%(filepath)s"
        ]
        if let deno = Tools.executable("deno") {
            options += ["--js-runtimes", "deno:\(deno.path)"]
        } else if let node = Tools.executable("node") {
            options += ["--js-runtimes", "node:\(node.path)"]
        }
        let cookieCopy = directory.appendingPathComponent(".douyin-\(UUID().uuidString).cookies")
        defer { try? Tools.files.removeItem(at: cookieCopy) }
        if let cookies {
            let input = try String(contentsOf: cookies, encoding: .utf8)
            let rows = input.split(whereSeparator: \.isNewline).filter { row in
                let domain = row.components(separatedBy: "\t").first ?? ""
                let name = domain.replacingOccurrences(of: "#HttpOnly_", with: "").lowercased()
                return name == "douyin.com" || name.hasSuffix(".douyin.com")
            }
            guard !rows.isEmpty else { throw AppError("所选文件未包含抖音的 Netscape Cookie。") }
            let data = Data(("# Netscape HTTP Cookie File\n" + rows.joined(separator: "\n") + "\n").utf8)
            guard data.count < 256_000,
                  Tools.files.createFile(atPath: cookieCopy.path, contents: data,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw AppError("无法准备抖音 Cookie。")
            }
            options += ["--cookies", cookieCopy.path]
        }
        let output = try await Tools.run("yt-dlp", options + ["--", link.absoluteString], in: directory) { line in
            guard line.hasPrefix("[download]") || line.hasPrefix("[Merger]") else { return }
            progress(line)
        }
        let prefix = "VIDEOCUT_FILE:"
        guard let entry = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw AppError("平台返回了结果，下载器未返回视频文件。")
        }
        let path = String(entry.dropFirst(prefix.count))
        let candidate = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              Tools.files.isReadableFile(atPath: candidate.path) else {
            throw AppError("无法读取下载的视频。")
        }
        return candidate
    }

    static func probe(_ source: URL, in directory: URL) async throws -> MediaInfo {
        struct Probe: Decodable {
            struct Stream: Decodable {
                let codec_type: String
                let avg_frame_rate: String?
                let duration: String?
                let disposition: [String: Int]?
            }
            struct Format: Decodable { let duration: String? }
            let streams: [Stream]
            let format: Format
        }
        let json = try await Tools.run("ffprobe", [
            "-v", "error", "-show_entries",
            "stream=codec_type,avg_frame_rate,duration:stream_disposition=attached_pic:format=duration",
            "-of", "json", source.path
        ], in: directory)
        let metadata = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        guard let video = metadata.streams.first(where: {
            $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1
        }), let length = (video.duration.flatMap(Double.init) ?? metadata.format.duration.flatMap(Double.init)),
            length.isFinite, length > 0 else { throw AppError("文件没有可识别的视频轨或时长。") }
        let rate = (video.avg_frame_rate ?? "").split(separator: "/").compactMap { Double($0) }
        let fps = rate.count == 2 && rate[0] > 0 && rate[1] > 0 ? rate[0] / rate[1] : 30
        return MediaInfo(duration: length, hasAudio: metadata.streams.contains { $0.codec_type == "audio" }, fps: fps)
    }

    static func preparePlayable(_ source: URL, in directory: URL) async throws -> URL {
        let result = directory.appendingPathComponent("preview-\(UUID().uuidString).mp4")
        _ = try await Tools.run("ffmpeg", base + [
            "-i", source.path, "-map", "0:V:0", "-map", "0:a:0?",
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-crf", "17", "-preset", "veryfast",
            "-pix_fmt", "yuv420p", "-fps_mode", "passthrough", "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", result.path
        ], in: directory)
        return result
    }

    private static let base = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]

    static func samples(_ source: URL, in directory: URL) async throws -> [FrameSample] {
        let frames = directory.appendingPathComponent("samples", isDirectory: true)
        if Tools.files.fileExists(atPath: frames.path) { try Tools.files.removeItem(at: frames) }
        try Tools.files.createDirectory(at: frames, withIntermediateDirectories: true)
        let output = try await Tools.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "info", "-nostats", "-y", "-i", source.path,
            "-map", "0:V:0", "-vf",
            "select='isnan(prev_selected_t)+gte(t-prev_selected_t,2)',scale=420:420:force_original_aspect_ratio=decrease,showinfo",
            "-an", "-fps_mode", "passthrough", "-q:v", "4", frames.appendingPathComponent("%06d.jpg").path
        ], in: directory)
        return times(output).enumerated().map {
            FrameSample(seconds: $1, url: frames.appendingPathComponent(String(format: "%06d.jpg", $0 + 1)))
        }
    }

    static func scenes(_ source: URL, in directory: URL) async throws -> [Double] {
        let output = try await Tools.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "info", "-nostats", "-i", source.path,
            "-map", "0:V:0", "-vf", "scale=320:320:force_original_aspect_ratio=decrease,select='gt(scene,0.30)',showinfo",
            "-an", "-fps_mode", "passthrough", "-f", "null", "-"
        ], in: directory)
        return times(output)
    }

    private static func times(_ ffmpegLog: String) -> [Double] {
        ffmpegLog.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains("showinfo"), let range = line.range(of: "pts_time:") else { return nil }
            return line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.flatMap { Double($0) }
        }
    }

    static func captions(_ source: URL, info: MediaInfo, in directory: URL) async throws -> [Caption] {
        guard info.hasAudio else { return [] }
        guard Tools.files.isReadableFile(atPath: Tools.model.path) else {
            throw AppError("缺少 Whisper 转写模型，请在设置里安装依赖。")
        }
        let audio = directory.appendingPathComponent("speech.wav")
        let transcript = directory.appendingPathComponent("speech")
        let json = transcript.appendingPathExtension("json")
        defer {
            try? Tools.files.removeItem(at: audio)
            try? Tools.files.removeItem(at: json)
        }
        _ = try await Tools.run("ffmpeg", base + [
            "-i", source.path, "-map", "0:a:0", "-vn", "-af", "aresample=16000:async=1:first_pts=0",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path
        ], in: directory)
        _ = try await Tools.run("whisper-cli", [
            "-m", Tools.model.path, "-f", audio.path, "-l", "auto", "-oj", "-of", transcript.path
        ], in: directory)
        struct Transcript: Decodable {
            struct Entry: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Entry]
        }
        let data = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: json))
        return data.transcription.compactMap {
            let content = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, $0.offsets.to > $0.offsets.from else { return nil }
            return Caption(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000, text: content)
        }
    }

    static func watermark(_ source: URL, directory: URL, seeds: [MaskSeed],
                          progress: @escaping @Sendable (String) -> Void) async throws -> (URL?, WatermarkReport) {
        guard Tools.files.isExecutableFile(atPath: Tools.python.path) else {
            throw AppError("缺少水印组件，请在设置里安装依赖。")
        }
        let id = UUID().uuidString
        let work = directory.appendingPathComponent(".watermark-\(id)", isDirectory: true)
        try Tools.files.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? Tools.files.removeItem(at: work) }
        let draft = work.appendingPathComponent("repaired.mp4")
        let reportURL = work.appendingPathComponent("report.json")
        let seedURL = work.appendingPathComponent("seeds.json")
        try JSONEncoder().encode(seeds).write(to: seedURL)
        _ = try await Tools.run(Tools.python, [
            Tools.script.path, source.path, draft.path, reportURL.path, seedURL.path,
            Tools.executable("ffmpeg")?.path ?? "ffmpeg"
        ], in: work) { line in
            if line.hasPrefix("PROGRESS ") { progress(String(line.dropFirst(9))) }
        }
        let report = try JSONDecoder().decode(WatermarkReport.self, from: Data(contentsOf: reportURL))
        guard report.repairedFrames > 0 else { return (nil, report) }
        try Task.checkCancellation()
        let video = directory.appendingPathComponent("repair-\(id).mp4")
        try Tools.files.moveItem(at: draft, to: video)
        return (video, report)
    }

    static func export(_ source: URL, info: MediaInfo, cuts: [Cut], destination: URL, title: String,
                       progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let times = cuts.map(\.seconds).sorted()
        if zip([0] + times, times + [info.duration]).contains(where: { $1 - $0 < max(1 / info.fps, 0.05) }) {
            throw AppError("切点太靠近其他切点或视频边缘，请先调整。")
        }
        let draft = destination.appendingPathComponent(".videocut-\(UUID().uuidString)", isDirectory: true)
        try Tools.files.createDirectory(at: draft, withIntermediateDirectories: false)
        defer { try? Tools.files.removeItem(at: draft) }
        var options = base + [
            "-progress", "pipe:1", "-i", source.path, "-map", "0:V:0", "-map", "0:a:0?",
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-fps_mode", "passthrough",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
            "-bf", "0", "-c:a", "aac", "-b:a", "192k"
        ]
        if times.isEmpty {
            options += ["-movflags", "+faststart", draft.appendingPathComponent("01.mp4").path]
        } else {
            let marks = times.map(number).joined(separator: ",")
            options += [
                "-force_key_frames", marks, "-f", "segment", "-segment_times", marks,
                "-segment_time_delta", number(0.5 / info.fps), "-segment_start_number", "1",
                "-reset_timestamps", "1", "-segment_format_options", "movflags=+faststart",
                draft.appendingPathComponent("%02d.mp4").path
            ]
        }
        _ = try await Tools.run("ffmpeg", options, in: draft) { line in
            let prefix = "out_time_us="
            guard line.hasPrefix(prefix), let mic = Double(line.dropFirst(prefix.count)) else { return }
            progress("\(Int(min(99, max(0, mic / 1_000_000 / info.duration * 100))))%")
        }
        let clips = try Tools.files.contentsOfDirectory(at: draft, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }
        guard clips.count == times.count + 1 else {
            throw AppError("导出片段数量与切点不一致，请调整靠近结尾的切点后重试。")
        }
        try Task.checkCancellation()
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let name = String((cleaned.isEmpty ? "视频" : cleaned).prefix(65)) + " - 分段"
        var result = destination.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while Tools.files.fileExists(atPath: result.path) {
            result = destination.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try Tools.files.moveItem(at: draft, to: result)
        return result
    }
}
