import Foundation

enum LyricsLookup {
    case synced([LyricLine], source: String)
    case instrumental
    case plainOnly
    case notFound
}
struct LyricRecord: Decodable {
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var syncedLyrics: String?
    var plainLyrics: String?
    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
}
/// Search order, normalization, Jaro-Winkler matching and cache behavior follow src/Lyrics.cs.
@MainActor final class LyricsProvider {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let session = URLSession(configuration: .ephemeral)
    private let transport: Transport?
    private let log: (String) -> Void
    private var cache: [String: LyricsLookup] = [:]
    init(transport: Transport? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.log = log
    }
    func forget(_ song: Song) { cache.removeValue(forKey: song.videoId + "|" + song.title) }
    private func fetch(_ path: String, _ query: [URLQueryItem]) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var url = URLComponents(string: "https://lrclib.net/api/\(path)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        request.setValue("PearNowPlaying-macOS/1.0 (+https://github.com/pdh0128/pear-now-playing)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: HTTPURLResponse
        if let transport { (data, response) = try await transport(request) }
        else {
            let result = try await session.data(for: request)
            guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            (data, response) = (result.0, http)
        }
        try Task.checkCancellation()
        log("LRCLIB \(path): HTTP \(response.statusCode)")
        guard (200...299).contains(response.statusCode) || (path == "get" && response.statusCode == 404) else {
            throw NSError(domain: "LRCLIB", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "LRCLIB HTTP \(response.statusCode)"])
        }
        return (data, response.statusCode)
    }
    private func search(_ query: [URLQueryItem]) async throws -> [LyricRecord] {
        let (data, _) = try await fetch("search", query)
        let records = try JSONDecoder().decode([LyricRecord].self, from: data)
        log("검색 후보 \(records.count)건, 싱크 가사 \(records.filter(\.hasSynced).count)건")
        return records
    }
    func find(_ song: Song) async throws -> LyricsLookup {
        try Task.checkCancellation()
        let key = song.videoId + "|" + song.title
        if let cached = cache[key] { return cached }
        var best: LyricRecord?
        var how = "get"
        var sawPlain = false
        var lastError: Error?
        func attemptSearch(_ query: [URLQueryItem]) async throws -> [LyricRecord] {
            do { return try await search(query) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error; log("검색 요청 실패, 다음 검색 방식 시도: \(error.localizedDescription)")
                return []
            }
        }
        if !song.title.isEmpty && !song.artist.isEmpty && song.duration > 0 {
            do {
            let (data, status) = try await fetch("get", [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: song.title), URLQueryItem(name: "album_name", value: song.album), URLQueryItem(name: "duration", value: String(Int(song.duration.rounded(.toNearestOrEven))))])
            if status != 404 {
                let record = try JSONDecoder().decode(LyricRecord.self, from: data)
                sawPlain = !(record.plainLyrics ?? "").isEmpty
                if record.hasSynced || record.instrumental == true { best = record }
            }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error; log("정확 조회 실패, 검색 방식 시도: \(error.localizedDescription)")
            }
        }
        var seen: [LyricRecord] = []
        if best == nil {
            var query = [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: song.title)]
            if !song.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: song.album)) }
            let records = try await attemptSearch(query); seen += records
            best = Self.pick(records, song: song); how = "search"
        }
        if best == nil {
            let alt = song.alternativeTitle.isEmpty ? song.title : song.alternativeTitle
            let artist = Self.artistVariants(song.artist).first ?? ""
            var attempted = Set<String>()
            for query in [alt + " " + artist, Self.cleanTitle(song.title) + " " + artist, Self.cleanTitle(alt)] {
                let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty, attempted.insert(query).inserted else { continue }
                let records = try await attemptSearch([URLQueryItem(name: "q", value: query)]); seen += records
                if let match = Self.pick(records, song: song) { best = match; how = "q=" + query; break }
            }
        }
        if best == nil { best = Self.pickByTitle(seen, song: song); how = "title match" }
        if best == nil, let lastError { throw lastError }
        let result: LyricsLookup
        if let best {
            if best.instrumental == true { result = .instrumental; log("연주곡: \(song.artist) - \(song.title)") }
            else {
                let lines = parseLRC(best.syncedLyrics ?? "")
                result = lines.isEmpty ? .notFound : .synced(lines, source: how)
                log("가사 \(lines.count)줄, 경로 \(how): \(song.artist) - \(song.title) (\(Int(song.duration))s)")
            }
        } else {
            sawPlain = sawPlain || seen.contains { !($0.plainLyrics ?? "").isEmpty }
            result = sawPlain ? .plainOnly : .notFound
            log("\(sawPlain ? "일반 가사만 있음" : "가사 찾지 못함"): \(song.artist) - \(song.title)")
        }
        try Task.checkCancellation()
        cache[key] = result
        return result
    }
    static func pick(_ records: [LyricRecord], song: Song) -> LyricRecord? {
        let ours = artistVariants(song.artist)
        let tags = song.tags.map { $0.lowercased() }.filter { !ours.contains($0) }
        var candidates = records.filter { record in
            let theirs = artistVariants(record.artistName ?? "")
            return (ours + tags).contains { a in theirs.contains { b in jaroWinkler(a, b) > 0.9 } }
        }
        if song.duration > 0 {
            candidates = candidates.filter { abs(($0.duration ?? 0) - song.duration) <= 15 }
                .sorted { abs(($0.duration ?? 0) - song.duration) < abs(($1.duration ?? 0) - song.duration) }
        }
        return candidates.first(where: \.hasSynced) ?? candidates.first { $0.instrumental == true }
    }
    static func pickByTitle(_ records: [LyricRecord], song: Song) -> LyricRecord? {
        guard song.duration > 0 else { return nil }
        var titles = Set([norm(song.title), norm(cleanTitle(song.title))])
        if !song.alternativeTitle.isEmpty { titles.insert(norm(song.alternativeTitle)); titles.insert(norm(cleanTitle(song.alternativeTitle))) }
        titles.remove("")
        return records.filter { $0.hasSynced && titles.contains(norm($0.trackName ?? "")) && abs(($0.duration ?? 0) - song.duration) <= 3 }
            .min { abs(($0.duration ?? 0) - song.duration) < abs(($1.duration ?? 0) - song.duration) }
    }
    static func norm(_ text: String) -> String {
        String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
    static func cleanTitle(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\(\[【][^\)\]】]*(official|mv|m/v|video|audio|lyric|live|ver\.|version|feat|prod)[^\)\]】]*[\)\]】]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func artistVariants(_ artist: String) -> [String] {
        let parts = artist.replacingOccurrences(of: #"\s*(?:[&,、/×]|\bfeat\.?|\bft\.?|\bx\b|\band\b)\s*"#, with: "\n", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\n")
        let regex = try! NSRegularExpression(pattern: #"^(.*?)\s*[\(\[](.+?)[\)\]]\s*$"#)
        var variants: [String] = []
        func add(_ text: String) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !value.isEmpty && !variants.contains(value) { variants.append(value) }
        }
        for part in parts {
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); add(part)
            if let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) {
                for index in [1, 2] { if let range = Range(match.range(at: index), in: part) { add(String(part[range])) } }
            }
        }
        return variants
    }
    static func jaroWinkler(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        // Match the original C# algorithm's UTF-16 indexing.
        let a = Array(left.utf16), b = Array(right.utf16)
        if a.isEmpty || b.isEmpty { return 0 }
        let range = max(0, max(a.count, b.count) / 2 - 1)
        var ma = Array(repeating: false, count: a.count), mb = Array(repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            let lo = max(0, i - range), hi = min(i + range + 1, b.count)
            if lo >= hi { continue }
            for j in lo..<hi where !mb[j] && a[i] == b[j] { ma[i] = true; mb[j] = true; matches += 1; break }
        }
        if matches == 0 { return 0 }
        var transpositions = 0, k = 0
        for i in a.indices where ma[i] {
            while !mb[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }; k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) { if a[i] != b[i] { break }; prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
struct LyricsLog {
    static let file = Settings.directory.appendingPathComponent("lyrics.log")
    static func write(_ message: String) {
        do {
            try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber, size.intValue > 512 * 1024 { try FileManager.default.removeItem(at: file) }
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + message + "\n").utf8))
        } catch { NSLog("Lyrics log: %@", error.localizedDescription) }
    }
}
