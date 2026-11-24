import AppKit
import AVFoundation
import Foundation

@MainActor
final class Workspace: ObservableObject {
    @Published var link = ""
    @Published var provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .openAI {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published var cuts: [Cut] = []
    @Published private(set) var original: URL?
    @Published private(set) var playable: URL?
    @Published private(set) var repaired: URL?
    @Published private(set) var info: MediaInfo?
    @Published private(set) var report: WatermarkReport?
    @Published private(set) var missing = Tools.missing
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published private(set) var status = "粘贴链接或打开本地视频"
    @Published private(set) var currentTime = 0.0
    @Published private(set) var result: URL?
    @Published var error: String?
    @Published var settings = false
    @Published var compareOriginal = false {
        didSet {
            guard oldValue != compareOriginal else { return }
            show(compareOriginal ? playable : repaired ?? playable, at: currentTime)
        }
    }
    @Published private(set) var seeds: [MaskSeed] = []
    @Published private(set) var maskNeedsUpdate = false
    @Published private(set) var analyzed = false
    let player = AVPlayer()

    private var workspace: URL?
    private var lastDownload: (link: URL, directory: URL)?
    private var cookieFile: URL?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var observer: Any?

    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard time.seconds.isFinite else { return }
                self?.currentTime = time.seconds
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        task?.cancel()
    }

    var hasCookies: Bool { cookieFile != nil }
    var duration: Double { info?.duration ?? 0 }

    func model(for provider: Provider) -> String {
        UserDefaults.standard.string(forKey: "model.\(provider.rawValue)") ?? provider.defaultModel
    }

    func saveModel(_ model: String, for provider: Provider) {
        UserDefaults.standard.set(model, forKey: "model.\(provider.rawValue)")
    }

    func refreshDependencies() { missing = Tools.missing }

    func download() {
        launch("下载视频") { id in
            let url = try SourceLink.parse(self.link)
            let directory: URL
            if let last = self.lastDownload, last.link == url {
                directory = last.directory
            } else {
                directory = try self.makeDirectory()
                self.lastDownload = (url, directory)
            }
            let host = url.host?.lowercased() ?? ""
            let useCookies = host == "douyin.com" || host.hasSuffix(".douyin.com")
            let source = try await Media.download(
                url, directory: directory, cookies: useCookies ? self.cookieFile : nil,
                progress: self.progress(id)
            )
            self.activity = "载入视频"
            try await self.load(source, directory: directory)
            var needsKey = false
            if self.duration <= 60 {
                self.keepShortVideo()
            } else if let ai = try? AIClient.make(self.provider, model: self.model(for: self.provider)) {
                try await self.analyzeLoaded(with: ai)
            } else {
                needsKey = true
            }
            if Tools.files.isExecutableFile(atPath: Tools.python.path) {
                try await self.repairLoaded(id)
            }
            if needsKey { self.status = "下载完成。配置 API Key 后可开始 AI 分段。" }
        }
    }

    func importVideo(_ url: URL) {
        launch("载入视频") { _ in
            try await self.load(url, directory: self.makeDirectory())
            self.status = "视频已载入"
        }
    }

    func useDouyinCookies(_ url: URL?) {
        cookieFile = url
        objectWillChange.send()
    }

    func analyze() {
        launch("准备 AI 分析") { _ in
            if self.duration <= 60 {
                self.keepShortVideo()
            } else {
                let ai = try AIClient.make(self.provider, model: self.model(for: self.provider))
                try await self.analyzeLoaded(with: ai)
            }
        }
    }

    func repair() {
        launch("检测水印") { id in try await self.repairLoaded(id) }
    }

    func install() {
        launch("安装本机依赖") { id in
            try Tools.files.createDirectory(at: Tools.support, withIntermediateDirectories: true)
            _ = try await Tools.run(URL(fileURLWithPath: "/bin/bash"), [Tools.setup.path],
                                    in: Tools.support, progress: self.progress(id))
            self.refreshDependencies()
            self.status = self.missing.isEmpty ? "本机依赖已就绪" : "请检查依赖"
        }
    }

    func export(to destination: URL) {
        guard let source = repaired ?? playable, let info, let original else { return }
        let cuts = self.cuts
        let downloaded = original.lastPathComponent.hasPrefix("source.") && lastDownload != nil
        let title = downloaded ? lastDownload?.link.lastPathComponent ?? "视频" : original.deletingPathExtension().lastPathComponent
        launch("导出视频") { id in
            self.result = try await Media.export(source, info: info, cuts: cuts, destination: destination,
                                                 title: title, progress: self.progress(id))
            self.status = "已导出 \(cuts.count + 1) 个 MP4"
        }
    }

    func cancel() {
        guard let task else { return }
        activity = "正在取消"
        task.cancel()
    }

    func seek(to value: Double) {
        let time = min(max(0, value), duration)
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func addCut() {
        guard currentTime > 0.05 && currentTime < duration - 0.05,
              !cuts.contains(where: { abs($0.seconds - currentTime) < 0.05 }) else { return }
        cuts.append(Cut(currentTime, "手动添加"))
        cuts.sort { $0.seconds < $1.seconds }
    }

    func changeCut(_ id: UUID, to value: Double) {
        guard value.isFinite, value > 0.05, value < duration - 0.05,
              !cuts.contains(where: { $0.id != id && abs($0.seconds - value) < 0.05 }),
              let position = cuts.firstIndex(where: { $0.id == id }) else { return }
        cuts[position].seconds = value
        cuts[position].reason = "手动调整"
        cuts.sort { $0.seconds < $1.seconds }
        seek(to: value)
    }

    func addSeed(_ rect: CGRect) {
        guard rect.width >= 0.008, rect.height >= 0.008 else { return }
        maskNeedsUpdate = true
        seeds.append(MaskSeed(seconds: currentTime, x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height))
        status = "已记录第 \(seeds.count) 个水印框，可以重新检测并修补。"
    }

    func clearSeeds() {
        maskNeedsUpdate = repaired != nil
        seeds.removeAll()
        status = "已清除纠正选框"
    }

    private func load(_ source: URL, directory: URL) async throws {
        let details = try await Media.probe(source, in: directory)
        let asset = AVURLAsset(url: source)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let transform = try? await tracks?.first?.load(.preferredTransform)
        let displayTransform = transform ?? .identity
        let compatible = (try? await asset.load(.isPlayable)) == true && displayTransform.isIdentity
        let ready = compatible ? source : try await Media.preparePlayable(source, in: directory)
        try Task.checkCancellation()
        let oldRepair = repaired
        let oldPreview = playable == original ? nil : playable
        original = source
        playable = ready
        repaired = nil
        compareOriginal = false
        info = details
        workspace = directory
        cuts.removeAll()
        analyzed = false
        seeds.removeAll()
        maskNeedsUpdate = false
        report = nil
        result = nil
        show(ready, at: 0)
        if let oldRepair { try? Tools.files.removeItem(at: oldRepair) }
        if let oldPreview { try? Tools.files.removeItem(at: oldPreview) }
    }

    private func keepShortVideo() {
        cuts = []
        analyzed = true
        status = "视频不足或等于 60 秒，保留整段。"
    }

    private func analyzeLoaded(with ai: AIClient) async throws {
        guard let source = playable, let info, let workspace else { throw AppError("请先载入视频。") }
        activity = "本地转写与提取画面"
        async let frames = Media.samples(source, in: workspace)
        async let captions = Media.captions(source, info: info, in: workspace)
        async let scenes = Media.scenes(source, in: workspace)
        let inputs = try await (frames, captions, scenes)
        let suggestions = try await ai.suggest(info: info, frames: inputs.0, captions: inputs.1, scenes: inputs.2) {
            self.activity = $0
        }
        try Task.checkCancellation()
        cuts = suggestions
        analyzed = true
        status = cuts.isEmpty ? "未找到可靠切点，已保留整段供复核。" : "已找到 \(cuts.count) 个切点"
    }

    private func repairLoaded(_ id: UUID) async throws {
        guard let source = playable, let workspace else { throw AppError("请先载入视频。") }
        let old = repaired
        let time = currentTime
        player.pause()
        activity = "检测水印"
        let (video, report) = try await Media.watermark(source, directory: workspace, seeds: seeds, progress: progress(id))
        repaired = video
        self.report = report
        maskNeedsUpdate = false
        compareOriginal = false
        show(video ?? source, at: time)
        if let old { try? Tools.files.removeItem(at: old) }
        status = report.detected == 0
            ? "未检测到可靠的水印，可框选疑似水印后重新处理。"
            : "已处理 \(report.repairedFrames) 帧，\(report.uncertain.count) 处待复核。"
    }

    private func makeDirectory() throws -> URL {
        let directory = Tools.support.appendingPathComponent("Jobs/\(UUID().uuidString)", isDirectory: true)
        try Tools.files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func show(_ url: URL?, at time: Double) {
        player.replaceCurrentItem(with: url.map { AVPlayerItem(url: $0) })
        seek(to: time)
    }

    private func progress(_ id: UUID) -> @Sendable (String) -> Void {
        { [weak self] text in
            Task { @MainActor in
                guard self?.operationID == id, self?.task?.isCancelled == false else { return }
                self?.activity = text
            }
        }
    }

    private func launch(_ label: String, run: @escaping (UUID) async throws -> Void) {
        guard task == nil else { return }
        let id = UUID()
        operationID = id
        activity = label
        busy = true
        error = nil
        task = Task {
            defer {
                busy = false
                activity = ""
                operationID = nil
                task = nil
                refreshDependencies()
            }
            do {
                try await run(id)
            } catch is CancellationError {
                status = "已取消"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
