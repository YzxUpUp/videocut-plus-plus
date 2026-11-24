import Foundation

@main
enum LocalChecks {
    static func main() async throws {
        try testParsesSupportedShareLinksAndKeepsPageSelection()
        testChoosesClosestReliableBoundariesThenKeepsShortTail()
        testRefinesNearSpeechEndAndRejectsMidSentence()
        try testParsesProviderResponseEnvelopes()
        print("链接、切点和两家 API 响应解析检查通过")
        try await checkDownloadCleanup()
        print("下载清理、导出保留和目录边界检查通过")
        if let link = ProcessInfo.processInfo.environment["VIDEOCUT_TEST_LINK"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try await Media.download(SourceLink.parse(link), directory: directory) { _ in }
            let info = try await Media.probe(source, in: directory)
            print("已下载并读取视频，时长 \(info.duration) 秒")
        }
        if let path = ProcessInfo.processInfo.environment["VIDEOCUT_TEST_MEDIA"] {
            try await checkMedia(path)
            print("本地转写、抽帧和 MP4 分段检查通过")
        }
    }

    static func testParsesSupportedShareLinksAndKeepsPageSelection() throws {
        equal(
            try SourceLink.parse("分享 https://www.bilibili.com/video/BV1Sk4y1B76w/?spm_id_from=123&p=2#top").absoluteString,
            "https://www.bilibili.com/video/BV1Sk4y1B76w/?p=2"
        )
        equal(
            try SourceLink.parse("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=123").absoluteString,
            "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )
        equal(try SourceLink.parse("复制打开抖音 https://v.douyin.com/AbCd/ 观看").host, "v.douyin.com")
        throwsError(try SourceLink.parse("https://douyin.com.example.org/video/123"))
    }

    static func testChoosesClosestReliableBoundariesThenKeepsShortTail() {
        let candidates = [
            Cut(49, "早切点"), Cut(63, "接近目标"), Cut(122, "低置信", 0.4),
            Cut(143, "内容延长后再切"), Cut(185, "短尾段不再切")
        ]
        equal(CutPlanner.choose(candidates, duration: 197).map(\.seconds), [63, 143])
        equal(CutPlanner.choose([], duration: 197), [])
        equal(CutPlanner.choose([Cut(48, "整段保留")], duration: 58), [])
    }

    static func testRefinesNearSpeechEndAndRejectsMidSentence() {
        let captions = [Caption(start: 51, end: 64, text: "一句完整对话")]
        let cuts = CutPlanner.refine([Cut(58, "不应保留"), Cut(63.4, "最后一词附近")],
                                     scenes: [57.9, 63.1], captions: captions)
        equal(cuts.map(\.seconds), [64])
    }

    static func testParsesProviderResponseEnvelopes() throws {
        let suggestions = #"{"cuts":[{"seconds":61.2,"reason":"对话结束","confidence":0.9}]}"#
        let responses: [(Provider, [String: Any])] = [
            (.openAI, ["output": [["type": "message", "content": [["type": "output_text", "text": suggestions]]]]]),
            (.glm, ["choices": [["message": ["content": "```json\n" + suggestions + "\n```"]]]])
        ]
        for (provider, response) in responses {
            let text = try AIClient.responseText(JSONSerialization.data(withJSONObject: response), provider: provider)
            equal(try AIClient.decodeCuts(text).map(\.seconds), [61.2])
        }
        throwsError(try AIClient.decodeCuts("invalid"))
        equal(try AIClient.decodeCuts(#"{"cuts":[]}"#), [])
    }

    private static func checkDownloadCleanup() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let jobs = scratch.appendingPathComponent("Jobs", isDirectory: true)
        let current = scratch.appendingPathComponent("当前下载目录", isDirectory: true)
        let previous = scratch.appendingPathComponent("之前的下载目录", isDirectory: true)
        let defaultID = UUID().uuidString
        let legacyID = UUID().uuidString
        let trackedID = UUID().uuidString
        let importID = UUID().uuidString
        let previousJob = previous.appendingPathComponent(trackedID, isDirectory: true)
        let legacyJob = current.appendingPathComponent(legacyID, isDirectory: true)
        let filesToClean = [
            jobs.appendingPathComponent("\(defaultID)/source.mp4"),
            jobs.appendingPathComponent("\(defaultID)/samples/000001.jpg"),
            jobs.appendingPathComponent("\(legacyID)/repair-\(UUID().uuidString).mp4"),
            legacyJob.appendingPathComponent("source.mkv"),
            previousJob.appendingPathComponent("source.f247.webm.part-Frag1")
        ]
        let keepFiles = [
            scratch.appendingPathComponent("outside.mp4"),
            jobs.appendingPathComponent("\(defaultID)/已导出/01.mp4"),
            jobs.appendingPathComponent("\(importID)/preview-\(UUID().uuidString).mp4"),
            current.appendingPathComponent("\(UUID().uuidString)/source.mp4"),
            legacyJob.appendingPathComponent("source.txt"),
            previousJob.appendingPathComponent("导出/01.mp4")
        ]
        for file in filesToClean + keepFiles {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let symlink = legacyJob.appendingPathComponent("source.mp4")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: keepFiles[0])

        let registered = [trackedID: try unwrap(DownloadCleanup.canonicalPath(previous))]
        let plan = await DownloadCleanup.jobs(in: jobs, currentRoot: current, registered: registered)
        equal(Set(plan.map(\.id)), Set([defaultID, legacyID, trackedID]))
        equal(Set(plan.flatMap(\.files).map(\.path)), Set(filesToClean.compactMap(DownloadCleanup.canonicalPath)))
        let result = await DownloadCleanup.remove(plan)
        equal(result.failed, 0)
        equal(Set(result.completed), Set([defaultID, legacyID, trackedID]))
        equal(filesToClean.filter { fm.fileExists(atPath: $0.path) }.map(\.path), [])
        check((keepFiles + [symlink]).allSatisfy { fm.fileExists(atPath: $0.path) })
        let repeated = await DownloadCleanup.jobs(in: jobs, currentRoot: current, registered: [:])
        check(repeated.isEmpty)
    }

    private static func checkVisionRequests(info: MediaInfo, frames: [FrameSample],
                                            scenes: [Double]) async throws {
        // Keep the provider contract exercise independent of API credentials and charges.
        for provider in Provider.allCases {
            var requests = 0
            let ai = AIClient(provider: provider, model: provider.defaultModel, key: "local-test") { request in
                requests += 1
                equal(request.url, provider.endpoint)
                equal(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test")
                let payload = try unwrap(try JSONSerialization.jsonObject(with: unwrap(request.httpBody)) as? [String: Any])
                equal(payload["model"] as? String, provider.defaultModel)
                let input = try unwrap(payload[provider == .openAI ? "input" : "messages"] as? [[String: Any]])
                let content = try unwrap(input.first?["content"] as? [[String: Any]])
                check(content.contains { $0["type"] as? String == (provider == .openAI ? "input_image" : "image_url") })
                let marks = [57, 124, 181].map { seconds -> [String: Any] in
                    ["seconds": seconds, "reason": "模拟回复：该段内容结束", "confidence": 0.9]
                }
                let raw = try JSONSerialization.data(withJSONObject: ["cuts": marks])
                let text = String(decoding: raw, as: UTF8.self)
                let envelope: [String: Any] = provider == .openAI
                    ? ["output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
                    : ["choices": [["message": ["content": text]]]]
                let response = try unwrap(HTTPURLResponse(
                    url: provider.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
                ))
                return (try JSONSerialization.data(withJSONObject: envelope), response)
            }
            try await ai.testConnection()
            let result = try await ai.suggest(info: info, frames: frames, captions: [], scenes: scenes) { _ in }
            equal(result.count, 3)
            equal(requests, 4)
        }
    }

    private static func checkMedia(_ path: String) async throws {
        let source = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try await Media.probe(source, in: directory)
        async let frames = Media.samples(source, in: directory)
        async let captions = Media.captions(source, info: info, in: directory)
        async let scenes = Media.scenes(source, in: directory)
        let inputs = try await (frames, captions, scenes)
        check(inputs.0.count > 1)
        check(inputs.0.allSatisfy { FileManager.default.isReadableFile(atPath: $0.url.path) })
        check(zip(inputs.0, inputs.0.dropFirst()).allSatisfy { $0.seconds < $1.seconds })
        if info.hasAudio { isFalse(inputs.1.isEmpty) }
        if (195...200).contains(info.duration) {
            try await checkVisionRequests(info: info, frames: inputs.0, scenes: inputs.2)
            print("两家 AI 接入的图片请求和切点流程通过模拟响应测试")
        }

        let cuts = [Cut(info.duration / 3, "测试"), Cut(info.duration * 2 / 3, "测试")]
        let folder = try await Media.export(source, info: info, cuts: cuts, destination: directory, title: "样例") { _ in }
        let clips = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        equal(clips.map(\.lastPathComponent), ["01.mp4", "02.mp4", "03.mp4"])
        var total = 0.0
        var frameCount = 0
        for clip in clips {
            let result = try await Media.probe(clip, in: directory)
            equal(result.hasAudio, info.hasAudio)
            equal(result.duration, info.duration / 3, accuracy: max(2 / info.fps, 0.1))
            total += result.duration
            frameCount += try await countFrames(clip, in: directory)
        }
        equal(total, info.duration, accuracy: max(3 / info.fps, 0.12))
        let originalFrames = try await countFrames(source, in: directory)
        equal(frameCount, originalFrames)
    }

    private static func countFrames(_ video: URL, in directory: URL) async throws -> Int {
        let text = try await Tools.run("ffprobe", [
            "-v", "error", "-count_frames", "-select_streams", "V:0", "-show_entries",
            "stream=nb_read_frames", "-of", "csv=p=0", video.path
        ], in: directory)
        return try unwrap(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}


private func equal<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    precondition(actual == expected, "第 \(line) 行，实际 \(actual)，预期 \(expected)")
}
private func equal(_ actual: Double, _ expected: Double, accuracy: Double, line: UInt = #line) {
    precondition(abs(actual - expected) <= accuracy, "第 \(line) 行，实际 \(actual)，预期 \(expected)")
}
private func check(_ value: Bool, line: UInt = #line) {
    precondition(value, "第 \(line) 行检查失败")
}
private func isFalse(_ value: Bool, line: UInt = #line) { check(!value, line: line) }
private func throwsError<T>(_ action: @autoclosure () throws -> T, line: UInt = #line) {
    do {
        _ = try action()
        preconditionFailure("第 \(line) 行没有产生预期错误")
    } catch {}
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError("外部程序未返回预期结果") }
    return value
}
