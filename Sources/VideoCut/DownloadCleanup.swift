import Foundation
import Darwin

struct DownloadCleanup {
    struct Job: Sendable {
        let id: String
        let root: URL
        let folders: [URL]
        let files: [URL]
    }

    struct Result {
        var completed: [String] = []
        var failed = 0
    }

    private static let files = FileManager.default
    private static let attributes: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    private static let sourcePattern = #"^source(?:\.f[\w-]+)?\.(?:mp4|mkv|webm|mov|avi|flv|ts|m4a|mp3|aac|opus|ogg|m4v|3gp|mpg|mpeg|wav|ytdl)(?:\.part(?:-Frag\d+)?|\.ytdl)?$"#
    private static let cachePattern = #"^(?:(?:preview|repair)-[0-9a-f-]{36}\.mp4|speech\.(?:wav|json)|\.process-[0-9a-f-]{36}\.log)$"#
    private static let cookiePattern = #"^\.douyin-[0-9a-f-]{36}\.cookies$"#
    private static let framePattern = #"^\d{6,}\.jpg$"#

    static func canonicalPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    static func jobs(in jobsRoot: URL, currentRoot: URL, registered: [String: String]) async -> [Job] {
        let jobsRoot = URL(fileURLWithPath: canonicalPath(jobsRoot) ?? jobsRoot.path, isDirectory: true)
        let currentRoot = URL(fileURLWithPath: canonicalPath(currentRoot) ?? currentRoot.path, isDirectory: true)
        let workFolders = children(of: jobsRoot).filter(isJobFolder)
        var candidates = registered
        // Older versions placed downloads in UUID job folders. Custom roots also
        // have a matching internal work folder, which establishes app ownership.
        for folder in workFolders where candidates[folder.lastPathComponent] == nil {
            let id = folder.lastPathComponent
            if children(of: folder).contains(where: isSource) {
                candidates[id] = jobsRoot.path
            } else if currentRoot != jobsRoot {
                let external = currentRoot.appendingPathComponent(id, isDirectory: true)
                if isJobFolder(external), children(of: external).contains(where: isSource) {
                    candidates[id] = currentRoot.path
                }
            }
        }

        return candidates.compactMap { id, path in
            guard UUID(uuidString: id) != nil else { return nil }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let download = root.appendingPathComponent(id, isDirectory: true)
            let work = jobsRoot.appendingPathComponent(id, isDirectory: true)
            guard isJobFolder(download), root.path == canonicalPath(root) else { return nil }
            let output = children(of: download).filter { isSource($0) || matchesRegular($0, cookiePattern) }
            let cache = processingFiles(in: work)
            let removableFiles = cache.files + output
            guard !removableFiles.isEmpty else { return nil }
            let folders = download.path == work.path ? cache.folders : cache.folders + [download]
            return Job(id: id, root: root, folders: folders, files: removableFiles)
        }
    }

    static func remove(_ jobs: [Job]) async -> Result {
        var result = Result()
        for job in jobs {
            if Task.isCancelled { break }
            do {
                try removeFiles(job.files, emptyFolders: job.folders)
                result.completed.append(job.id)
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    static func processingFiles(in work: URL) -> (files: [URL], folders: [URL]) {
        let samples = work.appendingPathComponent("samples", isDirectory: true)
        guard isJobFolder(work) else { return ([], []) }
        let generated = children(of: work).filter { matchesRegular($0, cachePattern) }
        let frames = isDirectory(samples) ? children(of: samples).filter { matchesRegular($0, framePattern) } : []
        return (generated + frames, [samples, work])
    }

    static func removeFiles(_ targets: [URL], emptyFolders: [URL]) throws {
        for file in targets {
            try Task.checkCancellation()
            let target = URL(fileURLWithPath: file.path)
            var attributes = stat()
            if lstat(target.path, &attributes) != 0 {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard target.path == canonicalPath(target), isRegular(target) else {
                throw AppError("文件位置已变化，请重新确认后再试。")
            }
            // unlink cannot recursively remove a directory that replaced this file.
            if unlink(target.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for folder in emptyFolders where isDirectory(folder) && folder.path == canonicalPath(folder) {
            // rmdir only removes empty folders, including when other files were added later.
            if rmdir(folder.path) != 0, errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func children(of directory: URL) -> [URL] {
        (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(attributes))) ?? []
    }

    private static func isJobFolder(_ url: URL) -> Bool {
        UUID(uuidString: url.lastPathComponent) != nil && isDirectory(url)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: attributes) else { return false }
        return values.isDirectory == true && values.isSymbolicLink == false
    }

    private static func isRegular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: attributes) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink == false
    }

    private static func isSource(_ url: URL) -> Bool { matchesRegular(url, sourcePattern) }

    private static func matchesRegular(_ url: URL, _ pattern: String) -> Bool {
        url.lastPathComponent.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            && isRegular(url)
    }
}
