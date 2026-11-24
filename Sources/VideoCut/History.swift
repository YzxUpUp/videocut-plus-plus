import Foundation
import Darwin

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt = Date()
    var original: URL?
    var directory: URL?
    var sourceLink: URL?
    var collection: URL?
    var preview: URL?
    var repaired: URL?
    var report: WatermarkReport?
    var cuts: [Cut] = []
    var seeds: [MaskSeed] = []
    var analyzed = false
    var maskNeedsUpdate = false
    var exports: [URL] = []

    var canOpen: Bool { original.map { Tools.files.isReadableFile(atPath: $0.path) } ?? false }
}

struct HistoryStore {
    let file: URL

    func read() throws -> [HistoryEntry] {
        guard Tools.files.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: file))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func write(_ entries: [HistoryEntry]) throws {
        try Tools.files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    static func discover(jobs: [DownloadCleanup.Job], workRoot: URL, exportRoot: URL?) -> [HistoryEntry] {
        let downloads = jobs.compactMap { job -> HistoryEntry? in
            guard let id = UUID(uuidString: job.id),
                  let source = job.files.first(where: {
                      $0.deletingPathExtension().lastPathComponent == "source" &&
                          ["mp4", "mkv", "webm", "mov", "avi", "flv", "ts", "m4v"].contains($0.pathExtension.lowercased())
                  }) else { return nil }
            return HistoryEntry(
                id: id, title: "历史下载 · " + id.uuidString.prefix(8),
                updatedAt: modified(source), original: source,
                directory: workRoot.appendingPathComponent(job.id, isDirectory: true),
                repaired: job.files.first { $0.lastPathComponent.hasPrefix("repair-") && $0.pathExtension == "mp4" }
            )
        }
        let folders = exportRoot.flatMap {
            try? Tools.files.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        } ?? []
        let collections = folders.compactMap { folder -> HistoryEntry? in
            guard folder.lastPathComponent.range(of: #" - 分段(?: \d+)?$"#, options: .regularExpression) != nil,
                  let clips = try? Media.collectionClips(in: folder),
                  clips.contains(where: HistoryDeletion.isExportClip) else { return nil }
            return HistoryEntry(id: UUID(), title: folder.lastPathComponent, updatedAt: modified(folder), exports: [folder])
        }
        return downloads + collections
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

struct HistoryDeletion {
    fileprivate struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        static func read(_ url: URL) throws -> FileIdentity? {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileIdentity(device: info.st_dev, inode: info.st_ino)
        }
    }

    struct Plan {
        let entry: HistoryEntry
        let download: DownloadCleanup.Job?
        let files: [URL]
        let emptyFolders: [URL]
        fileprivate let identities: [String: FileIdentity]

        var message: String {
            let detail: String
            if files.isEmpty {
                detail = "移除「\(entry.title)」的历史记录。"
            } else {
                let folders = Set(files.map { $0.deletingLastPathComponent().path }).sorted()
                let shown = folders.prefix(3).joined(separator: "\n")
                let remaining = folders.count > 3 ? "\n另有 \(folders.count - 3) 个目录" : ""
                detail = "将删除「\(entry.title)」及以下位置的 \(files.count) 个关联文件。\n\(shown)\(remaining)"
            }
            return detail + "\n\n删除后无法恢复。外部导入的源文件及其他任务引用的文件会保留。"
        }
    }

    static func plan(for entry: HistoryEntry, downloads: [DownloadCleanup.Job], workRoot: URL,
                     otherEntries: [HistoryEntry]) throws -> Plan {
        let peers = otherEntries.filter { $0.id != entry.id }
        let protectedFiles = Set(peers.flatMap { [$0.original, $0.preview, $0.repaired].compactMap { $0 } }
            .compactMap(DownloadCleanup.canonicalPath))
        let protectedFolders = Set(peers.flatMap { $0.exports + [$0.collection].compactMap { $0 } }
            .compactMap(DownloadCleanup.canonicalPath))

        let download = downloads.first { UUID(uuidString: $0.id) == entry.id }
        var files = download?.files ?? []
        var folders = download?.folders ?? []
        if let directory = entry.directory.flatMap(ordinaryDirectory),
           let root = DownloadCleanup.canonicalPath(workRoot),
           directory.deletingLastPathComponent().path == root,
           UUID(uuidString: directory.lastPathComponent) != nil {
            let cache = DownloadCleanup.processingFiles(in: directory)
            files += cache.files
            folders += cache.folders
            let combined = directory.appendingPathComponent("collection.mp4")
            if entry.collection != nil, entry.original.flatMap(DownloadCleanup.canonicalPath) == combined.path,
               isOrdinaryFile(combined) {
                files.append(combined)
            }
        }

        for export in entry.exports.compactMap(ordinaryDirectory) where !protectedFolders.contains(export.path) {
            let clips = try Tools.files.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)
            files += clips.filter(isExportClip)
            folders.append(export)
        }
        let unshared = unique(files.filter {
            !protectedFiles.contains($0.path) && !protectedFolders.contains($0.deletingLastPathComponent().path)
        })
        var identities: [String: FileIdentity] = [:]
        for file in unshared { identities[file.path] = try FileIdentity.read(file) }
        let removableFolders = folders.filter { !protectedFolders.contains($0.path) }
        return Plan(entry: entry, download: download, files: unshared.filter { identities[$0.path] != nil },
                    emptyFolders: unique(removableFolders), identities: identities)
    }

    static func remove(_ plan: Plan) async throws {
        for file in plan.files {
            if let identity = try FileIdentity.read(file), identity != plan.identities[file.path] {
                throw AppError("关联文件已被替换，请重新确认后再试。")
            }
        }
        try DownloadCleanup.removeFiles(plan.files, emptyFolders: plan.emptyFolders)
    }

    static func isExportClip(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"^\d{2,}\.mp4$"#, options: [.regularExpression, .caseInsensitive]) != nil
            && isOrdinaryFile(url)
    }

    private static func ordinaryDirectory(_ url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              let path = DownloadCleanup.canonicalPath(url) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isOrdinaryFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink == false
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
