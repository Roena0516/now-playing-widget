import Foundation

/// Follows Pear's synced-lyrics/providers/YTMusic.ts. Anonymous next/browse requests
/// never import the player's cookies or reuse the local Pear bearer token.
@MainActor final class YTMusicProvider {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let session = URLSession(configuration: .ephemeral)
    private let transport: Transport?
    private let log: (String) -> Void
    private var cache: [String: LyricsLookup] = [:]
    init(transport: Transport? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.log = log
    }
    func forget(_ song: Song) { cache.removeValue(forKey: song.videoId) }
    private func post(_ url: String, body: [String: Any], label: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.timeoutInterval = 12; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: HTTPURLResponse
        if let transport { (data, response) = try await transport(request) }
        else {
            let result = try await session.data(for: request)
            guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            (data, response) = (result.0, http)
        }
        try Task.checkCancellation(); log("YTMusic \(label): HTTP \(response.statusCode)")
        guard (200...299).contains(response.statusCode) else { throw NSError(domain: "YTMusic", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "YTMusic \(label) HTTP \(response.statusCode)"]) }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return result
    }
    func find(_ song: Song) async throws -> LyricsLookup {
        try Task.checkCancellation()
        guard !song.videoId.isEmpty else { return .notFound }
        if let cached = cache[song.videoId] { return cached }
        let next = try await post("https://music.youtube.com/youtubei/v1/next?prettyPrint=false", body: ["videoId": song.videoId, "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20261016.01.00"]]], label: "next")
        guard let browseID = Self.lyricsBrowseID(in: next) else { log("YTMusic: 가사 탭 없음"); return .notFound }
        let body: [String: Any] = ["browseId": browseID, "context": ["client": ["clientName": "26", "clientVersion": "7.01.05"]]]
        var plainOnly = false
        // Try Google's endpoint first. Pear's existing provider uses the proxy below
        // because direct anonymous browse requests may return no lyrics in some regions.
        do {
            let response = try await post("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", body: body, label: "browse")
            let result = Self.parse(response)
            if case .synced(let lines, _) = result { cache[song.videoId] = result; log("YTMusic 가사 \(lines.count)줄: \(song.artist) - \(song.title)"); return result }
            if case .plainOnly = result { plainOnly = true }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log("YTMusic 직접 조회 실패, Pear 제공자 경로 시도: \(error.localizedDescription)")
        }
        let response = try await post("https://ytmbrowseproxy.zvz.be/browse?prettyPrint=false", body: body, label: "Pear provider browse")
        let result = Self.parse(response)
        if case .synced(let lines, _) = result { cache[song.videoId] = result; log("YTMusic 가사 \(lines.count)줄 (Pear 제공자): \(song.artist) - \(song.title)"); return result }
        if case .plainOnly = result { return .plainOnly }
        return plainOnly ? .plainOnly : .notFound
    }
    static func lyricsBrowseID(in object: Any, depth: Int = 0) -> String? {
        guard depth < 30 else { return nil }
        if let dict = object as? [String: Any] {
            if let endpoint = dict["browseEndpoint"] as? [String: Any],
               let config = endpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
               let music = config["browseEndpointContextMusicConfig"] as? [String: Any],
               music["pageType"] as? String == "MUSIC_PAGE_TYPE_TRACK_LYRICS" { return endpoint["browseId"] as? String }
            for value in dict.values { if let id = lyricsBrowseID(in: value, depth: depth + 1) { return id } }
        } else if let values = object as? [Any] {
            for value in values { if let id = lyricsBrowseID(in: value, depth: depth + 1) { return id } }
        }
        return nil
    }
    private static func find(_ key: String, in object: Any, depth: Int = 0) -> Any? {
        guard depth < 30 else { return nil }
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let match = find(key, in: value, depth: depth + 1) { return match } }
        } else if let values = object as? [Any] {
            for value in values { if let match = find(key, in: value, depth: depth + 1) { return match } }
        }
        return nil
    }
    static func parse(_ response: [String: Any]) -> LyricsLookup {
        guard let contents = response["contents"] else { return .notFound }
        if let data = find("timedLyricsData", in: contents) as? [[String: Any]], !data.isEmpty {
            var lines: [LyricLine] = []
            for row in data {
                guard let cue = row["cueRange"] as? [String: Any],
                      let milliseconds = Double(String(describing: cue["startTimeMilliseconds"] ?? "")), milliseconds.isFinite,
                      let text = row["lyricLine"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(LyricLine(id: lines.count, time: max(0, milliseconds / 1000), text: trimmed.isEmpty ? "♪" : trimmed))
            }
            if !lines.isEmpty {
                lines = lines.sorted { $0.time < $1.time }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
                return .synced(lines, source: "YTMusic")
            }
            if data.contains(where: { !(($0["lyricLine"] as? String) ?? "").isEmpty }) { return .plainOnly }
        }
        if let shelf = find("musicDescriptionShelfRenderer", in: contents) as? [String: Any],
           let description = shelf["description"] as? [String: Any], let runs = description["runs"] as? [[String: Any]],
           runs.contains(where: { !(($0["text"] as? String) ?? "").isEmpty }) { return .plainOnly }
        return .notFound
    }
}
