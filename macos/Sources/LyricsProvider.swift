import Foundation

enum LyricsLookup {
    case synced([LyricLine], source: String)
    case instrumental
    case plainOnly
    case notFound
    var isFound: Bool {
        switch self { case .synced, .instrumental: return true; default: return false }
    }
    var sourceName: String {
        if case .synced(_, let source) = self { return source }
        return ""
    }
}
struct LyricRecord: Decodable {
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var syncedLyrics: String?
    var plainLyrics: String?
    var id: Int?
    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
    /// Lyrics uploaded again with the same timing look alike: number of lines, first and last line (seconds).
    var timing: String {
        let lines = parseLRC(syncedLyrics ?? "")
        guard let first = lines.first, let last = lines.last else { return "" }
        return "\(lines.count)|\(Int(first.time.rounded()))|\(Int(last.time.rounded()))"
    }
    /// Synced lyrics that run on past the end of their own recording, or of this song, are another version's: a
    /// "Bad Apple!!" entry listed as 232s carried the 5:19 original's lyrics (last line at 305s) and was taken for a
    /// 222s cover. Such lyrics would scroll out of step, so the entry isn't used. Same as src/Lyrics.cs.
    func fits(_ songDuration: Double) -> Bool {
        guard let last = parseLRC(syncedLyrics ?? "").map(\.time).max() else { return true }
        let own = duration ?? 0
        return (own <= 0 || last <= own + 5) && (songDuration <= 0 || last <= songDuration + 5)
    }
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
    /// While the song plays, a failed lookup is tried again for this long (seconds; e.g. while paused).
    static let lookupRetryFor: TimeInterval = 600
    static func isBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "LRCLIB" && [429, 502, 503, 504].contains(error.code)
    }
    /// Retry-After in seconds (1 when missing: LRCLIB's 503 usually says 1), at least 1.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return 1 }
        if let seconds = Double(value), seconds.isFinite { return max(1, seconds) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = format.date(from: value) { return max(1, date.timeIntervalSinceNow) }
        return 1
    }

    // LRCLIB's rules (https://lrclib.net/docs, read 2026-10-20): an identified client gets ~90 requests/min per
    // IP; send requests one after another with 200-500 ms between them; on 429 or 503 wait at least Retry-After
    // (503 usually says 1s) plus up to 30% random jitter, or risk a temporary ban. Same as src/Lyrics.cs.
    static let spacing: TimeInterval = 0.3, perMinute = 60, attempts = 4, maxRetryAfter: TimeInterval = 30
    /// Random extra share of a Retry-After wait (0-30%); tests make it 0.
    var jitter: () -> Double = { Double.random(in: 0...0.3) }
    private var recent: [Date] = []   // request starts in the last minute
    private var nextStart = Date.distantPast   // pacing, and Retry-After for every request (not only the one told)
    private var lastBusy = Date.distantPast

    /// How long to wait before trying a failed lookup again: a second right after LRCLIB said it was busy (the
    /// next request also waits for its Retry-After, so LRCLIB is asked again about as soon as it allows),
    /// otherwise (no connection, timeouts) 15 seconds.
    var retryWait: TimeInterval { Date().timeIntervalSince(lastBusy) < 10 ? 1 : 15 }

    /// This request's turn: after the previous one plus the spacing, any Retry-After pause, and within perMinute
    /// requests a minute (all lookups share it: the current song and the next one). `waited`: the caller has just
    /// slept through a Retry-After pause itself.
    private func waitTurn(waited: Bool) async throws {
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        var start = waited ? now : max(now, nextStart)
        if recent.count >= Self.perMinute { start = max(start, recent[recent.count - Self.perMinute].addingTimeInterval(60)) }
        recent.append(start)
        nextStart = max(nextStart, start.addingTimeInterval(Self.spacing))
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try await sleep(wait); try Task.checkCancellation() }
    }

    /// GET, retried while LRCLIB is busy (429/502/503/504) after its Retry-After (1s if none) plus jitter, up to
    /// `attempts` times; then the lookup ends (busy) and goes on to Kugou / NetEase, and is tried again later. A
    /// Retry-After over maxRetryAfter seconds isn't waited for here, but still holds back every request until it has passed.
    private func fetch(_ path: String, _ query: [URLQueryItem]) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var url = URLComponents(string: baseURL.trimmed("/") + "/api/\(path)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        request.setValue("NowPlayingWidget-macOS/\(appVersion) (+https://github.com/Roena0516/now-playing-widget)", forHTTPHeaderField: "User-Agent")
        var waited = false
        for attempt in 1...Self.attempts {
            try await waitTurn(waited: waited)
            let data: Data, response: HTTPURLResponse
            if let transport { (data, response) = try await transport(request) }
            else {
                let result = try await session.data(for: request)
                guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                (data, response) = (result.0, http)
            }
            try Task.checkCancellation()
            if [429, 502, 503, 504].contains(response.statusCode) {
                let delay = Self.retryAfter(response) * (1 + jitter())
                nextStart = max(nextStart, Date().addingTimeInterval(delay)); lastBusy = Date()
                // a rate limit (429) ends the lookup at once: Kugou / NetEase stand in while LRCLIB is waited out
                let last = attempt == Self.attempts || delay > Self.maxRetryAfter || response.statusCode == 429
                log("INFO LRCLIB \(path) busy (\(response.statusCode)), \(last ? "giving up for now" : "asking again") after \(String(format: "%.1f", delay))s")
                if !last { try await sleep(delay); try Task.checkCancellation(); waited = true; continue }
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
    /// `artistTolerance`: how far (seconds) a result by the same artist may be from the song's length.
    /// `titleCopies`: a title-only match needs this many identical uploads of its lyrics.
    func find(_ song: Song, titleTolerance: Double = 3, titleOnly: Bool = true, artistTolerance: Double = 15, titleCopies: Int = 1) async throws -> LyricsLookup {
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
            // "心を刺す言葉だけ - Only Words": LRCLIB may list the song under either half (this one only as "Only Words")
            let names = [song.title, song.alternativeTitle, Self.cleanTitle(song.title)] + CoverLyrics.titleHalves(Self.cleanTitle(song.title))
            for title in names.filter({ !$0.trimmed.isEmpty }).uniqued().prefix(4) {
                let record: LyricRecord? = try await attempt(nil) {
                    let (data, status) = try await fetch("get", [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: title),
                                                                 URLQueryItem(name: "album_name", value: song.album), URLQueryItem(name: "duration", value: String(Int(song.duration.rounded(.toNearestOrEven))))])
                    return status == 404 ? nil : try JSONDecoder().decode(LyricRecord.self, from: data)
                }
                if let record {
                    sawPlain = sawPlain || !(record.plainLyrics ?? "").isEmpty
                    if (record.hasSynced && record.fits(song.duration)) || record.instrumental == true { best = record; how = title == song.title ? "get" : "get \"\(title)\""; break }
                }
            }
        }

        // 2) search like Pear does, then looser free-text searches
        var seen: [LyricRecord] = []
        if best == nil {
            var query = [URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: song.title)]
            if !song.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: song.album)) }
            let records = try await attempt([]) { try await search(query) }; seen += records
            best = Self.pick(records, song: song, tolerance: artistTolerance); if best != nil { how = "search" }
        }
        if best == nil {
            let alt = song.alternativeTitle.isEmpty ? song.title : song.alternativeTitle
            let artist = Self.artistVariants(song.artist).first ?? ""
            // the last one without a "○○ver." naming the singer: other versions of the same song are listed by the
            // bare title, and the artist / title / length checks still decide
            for text in [alt + " " + artist, Self.cleanTitle(song.title) + " " + artist, CoverLyrics.withoutVersionTag(Self.cleanTitle(alt))].map(\.trimmed).uniqued() where !text.isEmpty {
                let records = try await attempt([]) { try await search([URLQueryItem(name: "q", value: text)]) }; seen += records
                if let match = Self.pick(records, song: song, tolerance: artistTolerance) { best = match; how = "q=" + text; break }
            }
        }

        // 3) artist written differently (e.g. "Kenshi Yonezu" vs "米津玄師"): same title and nearly the same length
        if best == nil, titleOnly, let match = Self.pickByTitle(seen, song: song, tolerance: titleTolerance, copies: titleCopies) { best = match; how = "title match (\(match.artistName ?? ""))" }
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
    static func pick(_ records: [LyricRecord], song: Song, tolerance: Double = 15) -> LyricRecord? {
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
            candidates = candidates.filter { abs(($0.duration ?? 0) - song.duration) <= tolerance }
                .sorted { abs(($0.duration ?? 0) - song.duration) < abs(($1.duration ?? 0) - song.duration) }
        }
        // prefer entries that actually have timestamps
        if let synced = candidates.first(where: { $0.hasSynced && $0.fits(song.duration) }) { return synced }
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
    static func withoutFeat(_ title: String) -> String {
        title.replacingOccurrences(of: #"[\(\[（][^\)\]）]*\b(feat|ft|with)\b[^\)\]）]*[\)\]）]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
    /// A result's track name is this song (its title, alternative title or cleaned-up title).
    static func titleFits(_ trackName: String, _ song: Song) -> Bool {
        [song.title, song.alternativeTitle, cleanTitle(song.title)].filter { !$0.trimmed.isEmpty }.contains { CoverLyrics.sameTitle(trackName, $0) }
    }
    /// Fallback when the artist name doesn't match: the title must be the same (ignoring case, spaces, punctuation and
    /// tags like 【PV】) and the length within `tolerance`. Among several such results, the lyrics uploaded most often
    /// with the same timing win (a song's well-known version is listed many times, one singer's cover once or twice).
    /// `copies`: when the matches disagree (several different lyrics), how many identical uploads the winner needs; a
    /// single kind of match ("ryo" credited as "supercell") is taken as is. Same as src/Lyrics.cs.
    static func pickByTitle(_ records: [LyricRecord], song: Song, tolerance: Double = 3, copies: Int = 1) -> LyricRecord? {
        guard song.duration > 0 else { return nil }
        var titles = Set([norm(song.title), norm(cleanTitle(song.title))])
        if !song.alternativeTitle.isEmpty { titles.insert(norm(song.alternativeTitle)); titles.insert(norm(cleanTitle(song.alternativeTitle))) }
        titles.remove("")
        var matches = records.filter {
            $0.hasSynced && $0.fits(song.duration) && abs(($0.duration ?? 0) - song.duration) <= tolerance
                && (titles.contains(norm($0.trackName ?? "")) || titles.contains(norm(cleanTitle($0.trackName ?? ""))))
        }
        // Lyrics that sing the title are this song's: an album's lyrics can be uploaded under another track's name
        // (トンデモワンダーズ's, several times, as "チュルリラ・チュルリラ・ダッダッダ!"). Only when some do.
        let singing = matches.filter { r in titles.contains { $0.count >= 3 && norm(r.syncedLyrics ?? "").contains($0) } }
        if !singing.isEmpty { matches = singing }
        func gap(_ r: LyricRecord) -> Double { abs((r.duration ?? 0) - song.duration) }
        func key(_ r: LyricRecord) -> String { r.id.map(String.init) ?? "\(r.trackName ?? "")|\(r.artistName ?? "")|\(r.duration ?? 0)" }
        struct Group { let items: [LyricRecord]; let copies: Int; let closest: Double }
        let groups: [Group] = Dictionary(grouping: matches, by: \.timing).values.map { items in
            Group(items: items, copies: Set(items.map(key)).count, closest: items.map(gap).min() ?? 0)
        }.sorted { $0.copies != $1.copies ? $0.copies > $1.copies : $0.closest < $1.closest }
        guard let best = groups.first else { return nil }
        if groups.count > 1 && (best.copies < copies || best.copies == groups[1].copies) { return nil }   // no clear winner
        return best.items.min { gap($0) < gap($1) }
    }
    static func norm(_ text: String) -> String { CoverLyrics.norm(text) }
    static func cleanTitle(_ text: String) -> String {
        text.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\(\[][^\)\]]*(official|mv|m/v|video|audio|lyric|live|ver\.|version|feat|prod|cover|歌ってみた|踊ってみた|弾いてみた)[^\)\]]*[\)\]]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*/?\s*(covered by|cover by)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?<![\p{L}\p{N}])(?:PV|MV|ＰＶ|ＭＶ)(?![\p{L}\p{N}])"#, with: " ", options: [.regularExpression, .caseInsensitive])   // "Bad Apple!! ＰＶ"
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
