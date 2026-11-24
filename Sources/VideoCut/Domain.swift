import Foundation
import Security

enum Provider: String, CaseIterable, Identifiable {
    case openAI, glm
    var id: Self { self }
    var name: String { self == .openAI ? "OpenAI GPT" : "智谱 GLM" }
    var defaultModel: String { self == .openAI ? "gpt-5-mini" : "glm-4.6v" }
    var endpoint: URL {
        URL(string: self == .openAI ? "https://api.openai.com/v1/responses"
            : "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
    }

    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.videocutplusplus.desktop",
         kSecAttrAccount as String: rawValue]
    }

    func apiKey() throws -> String {
        var query = keyQuery
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let bytes = data as? Data,
              let key = String(data: bytes, encoding: .utf8) else {
            throw AppError("无法读取 macOS 钥匙串（\(status)）。")
        }
        return key
    }

    func save(key: String) throws {
        let query = keyQuery as CFDictionary
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError("无法删除钥匙串里的 Key（\(status)）。")
            }
            return
        }
        let data = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query, data as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(keyQuery.merging(data) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("无法保存 API Key（\(status)）。") }
    }
}

struct MediaInfo {
    let duration: Double
    let hasAudio: Bool
    let fps: Double
}

struct Caption {
    let start: Double
    let end: Double
    let text: String
}

struct Cut: Codable, Identifiable, Equatable {
    let id: UUID
    var seconds: Double
    var reason: String
    var confidence: Double

    init(_ seconds: Double, _ reason: String, _ confidence: Double = 1) {
        id = UUID()
        self.seconds = seconds
        self.reason = reason
        self.confidence = confidence
    }
}

enum CutPlanner {
    static func choose(_ candidates: [Cut], duration: Double) -> [Cut] {
        var remaining = candidates.filter {
            $0.confidence >= 0.7 && $0.seconds.isFinite && $0.seconds > 0 && $0.seconds < duration
        }.sorted { $0.seconds < $1.seconds }
        var chosen: [Cut] = []
        var start = 0.0
        while duration - start > 60 {
            let lower = start + 45
            let upper = start + 75
            let ideal = start + 60
            let nearby = remaining.filter { (lower...upper).contains($0.seconds) }
            let best = nearby.min { a, b in
                let da = abs(a.seconds - ideal)
                let db = abs(b.seconds - ideal)
                return da == db ? a.confidence > b.confidence : da < db
            } ?? remaining.first { $0.seconds > upper }
            guard let best else { break }
            chosen.append(best)
            start = best.seconds
            remaining.removeAll { $0.seconds <= start }
        }
        return chosen
    }

    static func refine(_ suggestions: [Cut], scenes: [Double], captions: [Caption]) -> [Cut] {
        suggestions.compactMap { cut in
            let localSpeech = captions.filter { $0.start < cut.seconds + 1.5 && $0.end > cut.seconds - 1.5 }
            let stops = localSpeech.map(\.end) + scenes.filter { abs($0 - cut.seconds) <= 1.25 }
            func insideSpeech(_ time: Double) -> Bool {
                localSpeech.contains { time > $0.start + 0.06 && time < $0.end - 0.06 }
            }
            if let time = stops.filter({ abs($0 - cut.seconds) <= 1.25 && !insideSpeech($0) })
                .min(by: { abs($0 - cut.seconds) < abs($1 - cut.seconds) }) {
                return Cut(time, cut.reason, cut.confidence)
            }
            return insideSpeech(cut.seconds) ? nil : cut
        }
    }
}

struct SourceLink {
    static func parse(_ pasted: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: pasted, range: NSRange(pasted.startIndex..., in: pasted))
        for url in matches.compactMap(\.url) {
            guard let host = url.host?.lowercased(),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  url.user == nil, url.password == nil, url.port == nil else { continue }
            let accepted = ["bilibili.com", "b23.tv", "youtube.com", "youtu.be", "douyin.com"]
            guard accepted.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.fragment = nil
            if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
                parts.queryItems = parts.queryItems?.filter { $0.name == "p" }
            } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
                parts.queryItems = parts.queryItems?.filter { $0.name == "v" }
            }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
            if let result = parts.url { return result }
        }
        throw AppError("请粘贴 B 站、YouTube 或抖音的单条视频链接。")
    }
}

func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int((seconds * 100).rounded()))
    return String(format: "%02d:%02d.%02d", value / 6000, value / 100 % 60, value % 100)
}

func number(_ seconds: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
}
