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

struct WatermarkReport: Codable {
    struct Interval: Codable, Identifiable {
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

    static func collectionClips(in folder: URL) throws -> [URL] {
        let files = try Tools.files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: .skipsHiddenFiles)
        let clips = try files.filter {
            guard $0.pathExtension.lowercased() == "mp4" else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.lastPathComponent < $1.lastPathComponent : order == .orderedAscending
        }
        guard !clips.isEmpty else { throw AppError("这个文件夹中没有可导入的 MP4。请选择包含分段文件的文件夹。") }
        return clips
    }

    struct Collection {
        let source: URL
        let cuts: [Cut]
        let count: Int
    }

    private struct CollectionProbe: Decodable {
        struct Stream: Decodable, Equatable {
            struct SideData: Decodable, Equatable { let rotation: Int? }
            let codec_name: String?
            let codec_type: String
            let width: Int?
            let height: Int?
            let pix_fmt: String?
            let r_frame_rate: String?
            let sample_aspect_ratio: String?
            let sample_rate: String?
            let channels: Int?
            let channel_layout: String?
            let time_base: String?
            let extradata_hash: String?
            let side_data_list: [SideData]?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]
        let format: Format
    }

    static func importCollection(_ folder: URL, in directory: URL,
                                 progress: @escaping @Sendable (String) -> Void) async throws -> Collection {
        let clips = try collectionClips(in: folder)
        var probes: [CollectionProbe] = []
        var lengths: [Double] = []
        for clip in clips {
            let json = try await Tools.run("ffprobe", [
                "-v", "error", "-show_data_hash", "sha256", "-show_entries",
                "stream=codec_name,codec_type,width,height,pix_fmt,r_frame_rate,sample_aspect_ratio,sample_rate,channels,channel_layout,time_base,extradata_hash:stream_side_data=rotation:format=duration",
                "-of", "json", clip.path
            ], in: directory)
            let probe = try JSONDecoder().decode(CollectionProbe.self, from: Data(json.utf8))
            guard probe.streams.contains(where: { $0.codec_type == "video" }),
                  let length = probe.format.duration.flatMap(Double.init), length.isFinite, length > 0 else {
                throw AppError("\(clip.lastPathComponent) 没有可读取的视频轨或时长。")
            }
            probes.append(probe)
            lengths.append(length)
        }
        let result = directory.appendingPathComponent("collection.mp4")
        guard let firstStreams = probes.first?.streams,
              let firstVideo = firstStreams.first(where: { $0.codec_type == "video" }) else {
            throw AppError("合集没有可读取的视频轨。")
        }
        let audio = probes.map { $0.streams.contains { $0.codec_type == "audio" } }
        let compatible = firstVideo.codec_name == "h264" &&
            firstStreams.filter { $0.codec_type == "video" }.count == 1 &&
            firstStreams.filter { $0.codec_type == "audio" }.count <= 1 &&
            firstStreams.allSatisfy {
                ["h264", "aac"].contains($0.codec_name ?? "") && $0.extradata_hash != nil &&
                    ($0.side_data_list ?? []).allSatisfy { ($0.rotation ?? 0) == 0 }
            } && probes.allSatisfy { $0.streams == firstStreams }
        if compatible {
            let manifest = directory.appendingPathComponent("collection.ffconcat")
            var aliases: [URL] = []
            defer {
                for alias in aliases { try? Tools.files.removeItem(at: alias) }
                try? Tools.files.removeItem(at: manifest)
            }
            var lines = ["ffconcat version 1.0"]
            for (index, clip) in clips.enumerated() {
                let alias = directory.appendingPathComponent("part-\(index).mp4")
                try Tools.files.createSymbolicLink(at: alias, withDestinationURL: clip)
                aliases.append(alias)
                lines.append("file \(alias.lastPathComponent)")
                lines.append("duration \(number(lengths[index]))")
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: manifest)
            _ = try await Tools.run("ffmpeg", base + [
                "-f", "concat", "-i", manifest.path, "-map", "0:V:0", "-map", "0:a:0?",
                "-c", "copy", "-movflags", "+faststart", result.path
            ], in: directory, progress: progress)
        } else {
            let hasAudio = audio.contains(true)
            lengths = lengths.map { ceil($0 * 30) / 30 }
            let rotated = (firstVideo.side_data_list?.first?.rotation ?? 0) % 180 != 0
            let aspect = (firstVideo.sample_aspect_ratio ?? "").split(separator: ":").compactMap { Double($0) }
            let pixelRatio = aspect.count == 2 && aspect[0] > 0 && aspect[1] > 0 ? aspect[0] / aspect[1] : 1
            let displayWidth = Int(max(2, min(8192, Double(firstVideo.width ?? 1920) * pixelRatio)))
            let displayHeight = max(2, firstVideo.height ?? 1080)
            let width = (rotated ? displayHeight : displayWidth) / 2 * 2
            let height = (rotated ? displayWidth : displayHeight) / 2 * 2
            let filters = clips.indices.flatMap { i -> [String] in
                let duration = number(lengths[i])
                let video = "[\(i):V:0]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,fps=30,tpad=stop_mode=clone:stop_duration=\(duration),trim=duration=\(duration),format=yuv420p,setpts=PTS-STARTPTS[v\(i)]"
                guard hasAudio else { return [video] }
                let source = audio[i] ? "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo,apad"
                    : "anullsrc=r=48000:cl=stereo"
                return [video, source + ",atrim=duration=\(duration),asetpts=PTS-STARTPTS[a\(i)]"]
            }
            let inputs = clips.indices.map { hasAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }.joined()
            let graph = (filters + ["\(inputs)concat=n=\(clips.count):v=1:a=\(hasAudio ? 1 : 0)[v]" + (hasAudio ? "[a]" : "")])
                .joined(separator: ";")
            var options = clips.flatMap { ["-i", $0.path] } + ["-filter_complex", graph, "-map", "[v]"]
            if hasAudio { options += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"] }
            options += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "17", "-movflags", "+faststart", result.path]
            progress("统一分段的视频格式")
            _ = try await Tools.run("ffmpeg", base + options, in: directory)
        }
        var offset = 0.0
        let cuts = lengths.dropLast().enumerated().map { i, length in
            offset += length
            return Cut(offset, "原合集分段 · \(clips[i + 1].lastPathComponent)")
        }
        return Collection(source: result, cuts: cuts, count: clips.count)
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
