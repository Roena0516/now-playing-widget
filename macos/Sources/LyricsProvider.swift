import Foundation

enum LyricsLookup {
    case synced([LyricLine], source: String)
    case instrumental
    case plainOnly
    case notFound
    var isFound: Bool {
        switch self { case .synced, .instrumental: return true; default: return false }
    }
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
/// LRCLIB (https://lrclib.net), the open lyrics database Pear Desktop's synced-lyrics plugin also uses.
/// Search order, normalization, Jaro-Winkler matching follow src/Lyrics.cs (FindLrclib). No cache here:
/// LyricsFinder decides what is worth remembering. Throws when the lookup failed (busy, timeout, server error).
@MainActor final class LyricsProvider {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let session = URLSession(configuration: .ephemeral)
    private let transport: Transport?
    private let log: (String) -> Void
    private let sleep: (TimeInterval) async throws -> Void
    var baseURL = "https://lrclib.net"
    init(transport: Transport? = nil, log: @escaping (String) -> Void = { _ in },
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(for: .seconds(seconds)) }) {
        self.transport = transport; self.log = log; self.sleep = sleep
    }
    static let lookupRetryDelays = [0, 15, 45]
    static func isBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "LRCLIB" && [429, 502, 503, 504].contains(error.code)
    }
    static func retryDelay(_ response: HTTPURLResponse) -> TimeInterval {
        let advertised = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
        return min(10, max(2, advertised.isFinite ? advertised : 2))
    }
    /// GET with one quick retry when LRCLIB is busy (429/502/503/504). It is a free, volunteer-run
    /// service whose search endpoint answers 503 fairly often under load; keep the request count low.
    private func fetch(_ path: String, _ query: [URLQueryItem]) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var url = URLComponents(string: baseURL.trimmed("/") + "/api/\(path)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        request.setValue("PearNowPlaying-macOS/\(appVersion) (+https://github.com/Roena0516/pear-now-playing)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            let data: Data, response: HTTPURLResponse
            if let transport { (data, response) = try await transport(request) }
            else {
                let result = try await session.data(for: request)
                guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                (data, response) = (result.0, http)
            }
            try Task.checkCancellation()
            let busy = [429, 502, 503, 504].contains(response.statusCode)
            if busy && attempt == 0 {
                let delay = Self.retryDelay(response)
                log("INFO LRCLIB \(path) busy (\(response.statusCode)), asking again in \(Int(delay))s")
                try await sleep(delay); try Task.checkCancellation(); continue
            }
            guard (200...299).contains(response.statusCode) || (path == "get" && response.statusCode == 404) else {
                throw NSError(domain: "LRCLIB", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "LRCLIB \(path) \(response.statusCode)"])
            }
            return (data, response.statusCode)
        }
        throw URLError(.badServerResponse)
    }

    private func search(_ query: [URLQueryItem]) async throws -> [LyricRecord] {
        let (data, _) = try await fetch("search", query)
        return try JSONDecoder().decode([LyricRecord].self, from: data)
    }

    /// `titleTolerance`: allowed length difference when only the title matches (covers looked up by title use 10s).
    /// `titleOnly`: also accept a result whose artist differs if the title and length match.
    func find(_ song: Song, titleTolerance: Double = 3, titleOnly: Bool = true) async throws -> LyricsLookup {
        try Task.checkCancellation()
        var best: LyricRecord?
        var how = "not found"
        var sawPlain = false
        // A request that fails for a reason other than "server busy" (bad response, 500 …) doesn't end
        // the lookup: the next way of searching is tried, and the error only counts if nothing turns up.
        // Busy answers and timeouts end it, since the following requests would hit the same wall.
        var lastError: Error?
        func attempt<T>(_ fallback: T, _ call: () async throws -> T) async throws -> T {
            do { return try await call() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if Self.isBusy(error) || (error as? URLError)?.code == .timedOut { throw error }
                lastError = error; log("INFO LRCLIB request failed (\(error.localizedDescription)), trying the next search")
                return fallback
            }
        }

        // 1) exact signature lookup (artist + title + album + duration): one row, usually fast
        // also under the alternative / cleaned-up title ("ビノミ - Binomi" -> "ビノミ"): exact lookups are cheap
        if !song.artist.isEmpty && song.duration > 0 {
            for title in [song.title, song.alternativeTitle, Self.cleanTitle(song.title)].filter({ !$0.trimmed.isEmpty }).uniqued().prefix(3) {
                let record: LyricRecord? = try await attempt(nil) {
                    let (data, status) = try await fetch("get", [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: title),
                                                                 URLQueryItem(name: "album_name", value: song.album), URLQueryItem(name: "duration", value: String(Int(song.duration.rounded(.toNearestOrEven))))])
                    return status == 404 ? nil : try JSONDecoder().decode(LyricRecord.self, from: data)
                }
                if let record {
                    sawPlain = sawPlain || !(record.plainLyrics ?? "").isEmpty
                    if record.hasSynced || record.instrumental == true { best = record; how = title == song.title ? "get" : "get \"\(title)\""; break }
                }
            }
        }

        // 2) search like Pear does, then looser free-text searches
        var seen: [LyricRecord] = []
        if best == nil {
            var query = [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: song.title)]
            if !song.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: song.album)) }
            let records = try await attempt([]) { try await search(query) }; seen += records
            best = Self.pick(records, song: song); if best != nil { how = "search" }
        }
        if best == nil {
            let alt = song.alternativeTitle.isEmpty ? song.title : song.alternativeTitle
            let artist = Self.artistVariants(song.artist).first ?? ""
            for text in [alt + " " + artist, Self.cleanTitle(song.title) + " " + artist, Self.cleanTitle(alt)].map(\.trimmed).uniqued() where !text.isEmpty {
                let records = try await attempt([]) { try await search([URLQueryItem(name: "q", value: text)]) }; seen += records
                if let match = Self.pick(records, song: song) { best = match; how = "q=" + text; break }
            }
        }

        // 3) artist written differently (e.g. "Kenshi Yonezu" vs "米津玄師"): same title and nearly the same length
        if best == nil, titleOnly, let match = Self.pickByTitle(seen, song: song, tolerance: titleTolerance) { best = match; how = "title match (\(match.artistName ?? ""))" }
        if best == nil, let lastError { throw lastError }
        try Task.checkCancellation()

        let result: LyricsLookup
        if let best, best.instrumental == true { result = .instrumental }
        else if let best, case let lines = parseLRC(best.syncedLyrics ?? ""), !lines.isEmpty { result = .synced(lines, source: "LRCLIB") }
        else {
            sawPlain = sawPlain || seen.contains { !($0.plainLyrics ?? "").isEmpty }
            result = sawPlain ? .plainOnly : .notFound
        }
        switch result {
        case .synced: log("INFO lyrics found via LRCLIB \(how): \(song.artist) - \(song.title) (\(Int(song.duration))s)")
        case .instrumental: log("INFO lyrics instrumental: \(song.artist) - \(song.title)")
        default: log("INFO lyrics not found\(sawPlain ? " (plain lyrics only)" : ""): \(song.artist) - \(song.title) (\(Int(song.duration))s)")
        }
        return result
    }
    /// The result by the same artist and of about the same length. Pear's tags count as artist names too (they
    /// often hold the artist's other spellings), but a tag only vouches for the artist: tags that are the song or
    /// album name are left out, and a result matched through a tag must also have the song's title. Otherwise
    /// "LAMIA" by BlackY (tagged "LAMIA") took a song by the rapper Lamia. Same as src/Lyrics.cs.
    static func pick(_ records: [LyricRecord], song: Song) -> LyricRecord? {
        let ours = artistVariants(song.artist)
        let names = Set([song.title, song.alternativeTitle, cleanTitle(song.title), cleanTitle(song.alternativeTitle), song.album].map(norm).filter { !$0.isEmpty })
        let tags = song.tags.map { $0.lowercased() }.filter { !ours.contains($0) && !names.contains(norm($0)) }
        var candidates = records.filter { record in
            let theirs = artistVariants(record.artistName ?? "")
            if ours.contains(where: { a in theirs.contains { b in jaroWinkler(a, b) > 0.9 } }) { return true }
            guard !tags.isEmpty, titleFits(record.trackName ?? "", song) else { return false }
            return tags.contains { a in theirs.contains { b in jaroWinkler(a, b) > 0.9 } }
        }
        if song.duration > 0 {
            candidates = candidates.filter { abs(($0.duration ?? 0) - song.duration) <= 15 }
                .sorted { abs(($0.duration ?? 0) - song.duration) < abs(($1.duration ?? 0) - song.duration) }
        }
        // prefer entries that actually have timestamps
        if let synced = candidates.first(where: \.hasSynced) { return synced }
        // "instrumental" hides the lyrics, so it has to be about this very version: other remixes of the song
        // fall within the length tolerance too (PUPA (Endorfin. Remix) took the uma remix's mark). And if an entry
        // of this version has words, the mark is someone's mistake. Same as src/Lyrics.cs.
        let same = candidates.filter { sameVersion($0.trackName ?? "", song) }
        if same.contains(where: { $0.instrumental != true && !($0.plainLyrics ?? "").trimmed.isEmpty }) { return nil }
        return same.first { $0.instrumental == true }
    }
    /// The same title once featured artists are left out, so remix and version tags must agree:
    /// "PUPA (feat. Endorfin.) [Endorfin. Remix]" is "PUPA (Endorfin. Remix)", but "PUPA (uma Remix)" and "PUPA" are not.
    static func sameVersion(_ trackName: String, _ song: Song) -> Bool {
        let t = norm(withoutFeat(trackName))
        return !t.isEmpty && [song.title, song.alternativeTitle].contains { norm(withoutFeat($0)) == t }
    }
    private static func withoutFeat(_ title: String) -> String {
        title.replacingOccurrences(of: #"[\(\[（][^\)\]）]*\b(feat|ft|with)\b[^\)\]）]*[\)\]）]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
    /// A result's track name is this song (its title, alternative title or cleaned-up title).
    static func titleFits(_ trackName: String, _ song: Song) -> Bool {
        [song.title, song.alternativeTitle, cleanTitle(song.title)].filter { !$0.trimmed.isEmpty }.contains { CoverLyrics.sameTitle(trackName, $0) }
    }
    /// Fallback when the artist name doesn't match: the title must be the same (ignoring case, spaces
    /// and punctuation) and the length within `tolerance` seconds, which together are very unlikely to collide.
    static func pickByTitle(_ records: [LyricRecord], song: Song, tolerance: Double = 3) -> LyricRecord? {
        guard song.duration > 0 else { return nil }
        var titles = Set([norm(song.title), norm(cleanTitle(song.title))])
        if !song.alternativeTitle.isEmpty { titles.insert(norm(song.alternativeTitle)); titles.insert(norm(cleanTitle(song.alternativeTitle))) }
        titles.remove("")
        return records.filter { $0.hasSynced && titles.contains(norm($0.trackName ?? "")) && abs(($0.duration ?? 0) - song.duration) <= tolerance }
            .min { abs(($0.duration ?? 0) - song.duration) < abs(($1.duration ?? 0) - song.duration) }
    }
    static func norm(_ text: String) -> String { CoverLyrics.norm(text) }
    static func cleanTitle(_ text: String) -> String {
        text.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\(\[][^\)\]]*(official|mv|m/v|video|audio|lyric|live|ver\.|version|feat|prod|cover|歌ってみた|踊ってみた|弾いてみた)[^\)\]]*[\)\]]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*/?\s*(covered by|cover by)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"歌ってみた|踊ってみた|弾いてみた"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s　]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/-| "))
    }
    static func artistVariants(_ artist: String) -> [String] {
        let parts = artist.replacingOccurrences(of: #"\s*(?:[&,、/×]|\bfeat\.?|\bft\.?|\bx\b|\band\b|\s및\s|\sと\s)\s*"#, with: "\n", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\n")
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
    nonisolated static func jaroWinkler(_ left: String, _ right: String) -> Double {
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
