import AppKit
import AVFoundation
import Foundation

@MainActor
final class Workspace: ObservableObject {
    static let jobsRoot = Tools.support.appendingPathComponent("Jobs", isDirectory: true)
    private static let downloadFolderKey = "downloadFolder"
    private static let exportFolderKey = "exportFolder"
    private static let downloadJobsKey = "downloadJobs"

    @Published var link = ""
    @Published var downloadFolder = UserDefaults.standard.url(forKey: Workspace.downloadFolderKey) {
        didSet { UserDefaults.standard.set(downloadFolder, forKey: Self.downloadFolderKey) }
    }
    @Published var exportFolder = UserDefaults.standard.url(forKey: Workspace.exportFolderKey) {
        didSet { UserDefaults.standard.set(exportFolder, forKey: Self.exportFolderKey) }
    }
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
    @Published private(set) var cleanupStatus: String?
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var historyError: String?
    @Published private(set) var pendingHistoryDeletion: HistoryDeletion.Plan?
    @Published private(set) var videoTitle: String?
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
    private let historyStore: HistoryStore
    private var savedHistory: [HistoryEntry] = []
    private var discoveredHistory: [HistoryEntry] = []
    private var activeHistory: HistoryEntry?
    private var historyReadFailed = false
    private var lastDownload: (link: URL, directory: URL, work: URL)?
    private var cookieFile: URL?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var observer: Any?
    private var pendingSeek: UUID?

    init(historyStore: HistoryStore = HistoryStore(file: Tools.support.appendingPathComponent("History.json"))) {
        self.historyStore = historyStore
        do {
            savedHistory = try historyStore.read()
            history = savedHistory
        } catch {
            historyReadFailed = true
            historyError = "无法读取历史记录。现有记录文件已保留。"
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.playable != nil, self.pendingSeek == nil, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        task?.cancel()
    }

    var hasCookies: Bool { cookieFile != nil }
    var duration: Double { info?.duration ?? 0 }
    var downloadRoot: URL { downloadFolder ?? Self.jobsRoot }

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
            let root = self.downloadRoot.standardizedFileURL
            let directory: URL
            let work: URL
            if let last = self.lastDownload, last.link == url,
               last.directory.deletingLastPathComponent().standardizedFileURL.path == root.path {
                directory = last.directory
                work = last.work
            } else {
                let jobID = UUID().uuidString
                directory = root.appendingPathComponent(jobID, isDirectory: true)
                work = Self.jobsRoot.appendingPathComponent(jobID, isDirectory: true)
                self.lastDownload = (url, directory, work)
            }
            if self.downloadFolder != nil {
                var isDirectory: ObjCBool = false
                guard Tools.files.fileExists(atPath: root.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw AppError("下载目录不可用，请在设置中重新选择。")
                }
            }
            try Tools.files.createDirectory(at: directory, withIntermediateDirectories: true)
            if work != directory {
                try Tools.files.createDirectory(at: work, withIntermediateDirectories: true)
            }
            var registered = self.downloadJobs
            registered[directory.lastPathComponent] = DownloadCleanup.canonicalPath(root) ?? root.path
            self.downloadJobs = registered
            let host = url.host?.lowercased() ?? ""
            let useCookies = host == "douyin.com" || host.hasSuffix(".douyin.com")
            let source = try await Media.download(
                url, directory: directory, cookies: useCookies ? self.cookieFile : nil,
                progress: self.progress(id)
            )
            self.activity = "载入视频"
            let key = UUID(uuidString: work.lastPathComponent) ?? UUID()
            var entry = self.savedHistory.first { $0.id == key } ?? HistoryEntry(
                id: key, title: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
            )
            entry.original = source
            entry.directory = work
            entry.sourceLink = url
            try await self.load(entry)
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
            try await self.load(HistoryEntry(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                                             original: url, directory: self.makeDirectory()))
            self.status = "视频已载入"
        }
    }

    func refreshHistory() async {
        let downloads = await DownloadCleanup.jobs(in: Self.jobsRoot, currentRoot: downloadRoot, registered: downloadJobs)
        guard !Task.isCancelled else { return }
        discoveredHistory = HistoryStore.discover(jobs: downloads, workRoot: Self.jobsRoot, exportRoot: exportFolder)
        updateHistoryList()
    }

    func prepareHistoryDeletion(_ entry: HistoryEntry) {
        guard !historyReadFailed else { return }
        launch("检查历史文件") { _ in
            do {
                let jobs = await DownloadCleanup.jobs(in: Self.jobsRoot, currentRoot: self.downloadRoot,
                                                       registered: self.downloadJobs)
                try Task.checkCancellation()
                self.pendingHistoryDeletion = try HistoryDeletion.plan(
                    for: entry, downloads: jobs, workRoot: Self.jobsRoot,
                    otherEntries: self.history + [self.activeHistory].compactMap { $0 }
                )
                self.historyError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.historyError = "无法检查关联文件。\(error.localizedDescription)"
            }
        }
    }

    func dismissHistoryDeletion() { pendingHistoryDeletion = nil }

    func deleteHistory(_ plan: HistoryDeletion.Plan) {
        guard !historyReadFailed, history.contains(where: { $0.id == plan.entry.id }) else { return }
        dismissHistoryDeletion()
        launch("删除历史记录") { _ in
            if let job = plan.download {
                self.downloadJobs[job.id] = job.root.path
                if self.lastDownload?.directory.lastPathComponent == job.id { self.lastDownload = nil }
            }
            let paths = Set(plan.files.map(\.path))
            if self.activeHistory?.id == plan.entry.id || [self.original, self.playable, self.repaired]
                .compactMap({ $0 }).compactMap(DownloadCleanup.canonicalPath).contains(where: paths.contains) {
                self.closePreview()
                self.result = nil
            }
            do {
                try await HistoryDeletion.remove(plan)
                let remaining = self.savedHistory.filter { $0.id != plan.entry.id }
                if remaining.count != self.savedHistory.count { try self.historyStore.write(remaining) }
                self.savedHistory = remaining
                self.discoveredHistory.removeAll { $0.id == plan.entry.id }
                if let job = plan.download, job.files.allSatisfy({ paths.contains($0.path) }) {
                    self.downloadJobs.removeValue(forKey: job.id)
                }
                self.updateHistoryList()
                self.historyError = nil
                self.status = "已删除历史记录"
            } catch {
                self.historyError = "删除未完成，历史记录已保留。\(error.localizedDescription)"
            }
        }
    }

    func restore(_ entry: HistoryEntry) {
        launch("打开历史任务") { _ in
            try await self.load(entry)
            if let link = entry.sourceLink { self.link = link.absoluteString }
            self.status = "已打开历史任务"
        }
    }

    func importCollection(_ folder: URL) {
        launch("导入视频合集") { id in
            let directory = try self.makeDirectory()
            do {
                let imported = try await Media.importCollection(folder, in: directory, progress: self.progress(id))
                let title = folder.lastPathComponent.replacingOccurrences(
                    of: #" - 分段(?: \d+)?$"#, with: "", options: .regularExpression
                )
                try await self.load(HistoryEntry(
                    id: id, title: title.isEmpty ? folder.lastPathComponent : title, original: imported.source,
                    directory: directory, collection: folder, cuts: imported.cuts
                ))
                self.status = "已导入 \(imported.count) 个分段，可重新处理"
            } catch {
                try? Tools.files.removeItem(at: directory)
                throw error
            }
        }
    }

    private func updateHistoryList() {
        let knownIDs = Set(savedHistory.map(\.id))
        let knownOriginals = Set(savedHistory.compactMap(\.original).compactMap(DownloadCleanup.canonicalPath))
        let knownFolders = Set(savedHistory.flatMap { $0.exports + [$0.collection].compactMap { $0 } }
            .compactMap(DownloadCleanup.canonicalPath))
        history = (savedHistory + discoveredHistory.filter {
            !knownIDs.contains($0.id) &&
                !($0.original.flatMap(DownloadCleanup.canonicalPath).map(knownOriginals.contains) ?? false) &&
                !$0.exports.compactMap(DownloadCleanup.canonicalPath).contains(where: knownFolders.contains)
        }).sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    private func saveHistory() -> Bool {
        guard !historyReadFailed, var entry = activeHistory else { return false }
        entry.updatedAt = Date()
        entry.preview = playable == original ? nil : playable
        entry.repaired = repaired
        entry.report = report
        entry.cuts = cuts
        entry.seeds = seeds
        entry.analyzed = analyzed
        entry.maskNeedsUpdate = maskNeedsUpdate
        activeHistory = entry
        let entries = [entry] + savedHistory.filter { $0.id != entry.id }
        do {
            try historyStore.write(entries)
            savedHistory = entries
            historyError = nil
            updateHistoryList()
            return true
        } catch {
            historyError = "无法保存历史记录。请检查本机应用数据目录。"
            return false
        }
    }

    func useDouyinCookies(_ url: URL?) {
        cookieFile = url
        objectWillChange.send()
    }

    func clearDownloads() {
        launch("清理下载") { _ in
            self.cleanupStatus = nil
            var registered = self.downloadJobs
            let jobs = await DownloadCleanup.jobs(in: Self.jobsRoot, currentRoot: self.downloadRoot, registered: registered)
            try Task.checkCancellation()
            guard !jobs.isEmpty else {
                self.cleanupStatus = "目前没有可清理的下载文件。"
                return
            }

            for job in jobs { registered[job.id] = job.root.path }
            self.downloadJobs = registered
            let paths = Set(jobs.flatMap(\.files).map(\.path))
            if [self.original, self.playable, self.repaired].compactMap({ $0 })
                .compactMap(DownloadCleanup.canonicalPath).contains(where: paths.contains) {
                self.closePreview()
            }
            if let last = self.lastDownload, jobs.contains(where: { $0.id == last.directory.lastPathComponent }) {
                self.lastDownload = nil
            }
            let outcome = await DownloadCleanup.remove(jobs)
            for id in outcome.completed { registered.removeValue(forKey: id) }
            self.downloadJobs = registered
            let remaining = jobs.count - outcome.completed.count - outcome.failed
            var message = "已清理 \(outcome.completed.count) 个下载任务。"
            if outcome.failed > 0 { message += "\(outcome.failed) 个任务未清理完成，可重试。" }
            if remaining > 0 { message += "已停止，剩余 \(remaining) 个任务。" }
            self.updateHistoryList()
            self.cleanupStatus = message
            self.status = message
        }
    }

    private var downloadJobs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.downloadJobsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadJobsKey) }
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
        let title = videoTitle ?? original.deletingPathExtension().lastPathComponent
        launch("导出视频") { id in
            let exported = try await Media.export(source, info: info, cuts: cuts, destination: destination,
                                                  title: title, progress: self.progress(id))
            self.result = exported
            self.activeHistory?.exports.append(exported)
            self.saveHistory()
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
        let request = UUID()
        pendingSeek = request
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.pendingSeek == request else { return }
                self.pendingSeek = nil
                let actual = self.player.currentTime().seconds
                if !finished, actual.isFinite { self.currentTime = actual }
            }
        }
    }

    func preview(_ cut: Cut) {
        player.pause()
        seek(to: cut.seconds)
    }

    func addCut() {
        guard currentTime > 0.05 && currentTime < duration - 0.05,
              !cuts.contains(where: { abs($0.seconds - currentTime) < 0.05 }) else { return }
        cuts.append(Cut(currentTime, "手动添加"))
        cuts.sort { $0.seconds < $1.seconds }
        saveHistory()
    }

    func removeCut(_ id: UUID) {
        cuts.removeAll { $0.id == id }
        saveHistory()
    }

    func changeCut(_ id: UUID, to value: Double) {
        guard value.isFinite, value > 0.05, value < duration - 0.05,
              !cuts.contains(where: { $0.id != id && abs($0.seconds - value) < 0.05 }),
              let position = cuts.firstIndex(where: { $0.id == id }) else { return }
        cuts[position].seconds = value
        cuts[position].reason = "手动调整"
        let cut = cuts[position]
        cuts.sort { $0.seconds < $1.seconds }
        preview(cut)
        saveHistory()
    }

    func addSeed(_ rect: CGRect) {
        guard rect.width >= 0.008, rect.height >= 0.008 else { return }
        maskNeedsUpdate = true
        seeds.append(MaskSeed(seconds: currentTime, x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height))
        saveHistory()
        status = "已记录第 \(seeds.count) 个水印框，可以重新检测并修补。"
    }

    func clearSeeds() {
        maskNeedsUpdate = repaired != nil
        seeds.removeAll()
        saveHistory()
        status = "已清除纠正选框"
    }

    private func load(_ entry: HistoryEntry) async throws {
        guard let source = entry.original, let directory = entry.directory, entry.canOpen else {
            throw AppError("找不到这条历史任务的原片。若分段文件仍在，可导入合集重新处理。")
        }
        try Tools.files.createDirectory(at: directory, withIntermediateDirectories: true)
        let details = try await Media.probe(source, in: directory)
        let asset = AVURLAsset(url: source)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let transform = try? await tracks?.first?.load(.preferredTransform)
        let displayTransform = transform ?? .identity
        let compatible = (try? await asset.load(.isPlayable)) == true && displayTransform.isIdentity
        let ready: URL
        if let preview = entry.preview, Tools.files.isReadableFile(atPath: preview.path) {
            ready = preview
        } else {
            ready = compatible ? source : try await Media.preparePlayable(source, in: directory)
        }
        try Task.checkCancellation()
        activeHistory = entry
        videoTitle = entry.title
        original = source
        playable = ready
        repaired = entry.repaired.flatMap { Tools.files.isReadableFile(atPath: $0.path) ? $0 : nil }
        compareOriginal = false
        info = details
        workspace = directory
        cuts = entry.cuts.filter { $0.seconds > 0 && $0.seconds < details.duration }
        analyzed = entry.analyzed
        seeds = entry.seeds
        maskNeedsUpdate = entry.maskNeedsUpdate || (entry.repaired != nil && repaired == nil && !seeds.isEmpty)
        report = repaired == nil && (entry.report?.repairedFrames ?? 0) > 0 ? nil : entry.report
        result = entry.exports.last(where: { Tools.files.fileExists(atPath: $0.path) })
        show(repaired ?? ready, at: 0)
        saveHistory()
    }

    private func keepShortVideo() {
        cuts = []
        analyzed = true
        saveHistory()
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
        saveHistory()
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
        if saveHistory(), let old { try? Tools.files.removeItem(at: old) }
        status = report.detected == 0
            ? "未检测到可靠的水印，可框选疑似水印后重新处理。"
            : "已处理 \(report.repairedFrames) 帧，\(report.uncertain.count) 处待复核。"
    }

    private func makeDirectory() throws -> URL {
        let directory = Self.jobsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Tools.files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func show(_ url: URL?, at time: Double) {
        player.replaceCurrentItem(with: url.map { AVPlayerItem(url: $0) })
        seek(to: time)
    }

    private func closePreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        pendingSeek = nil
        activeHistory = nil
        videoTitle = nil
        original = nil
        playable = nil
        repaired = nil
        info = nil
        workspace = nil
        compareOriginal = false
        currentTime = 0
        cuts.removeAll()
        seeds.removeAll()
        maskNeedsUpdate = false
        analyzed = false
        report = nil
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
