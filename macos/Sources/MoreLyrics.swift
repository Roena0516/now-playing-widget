import Foundation

/// Synced lyrics from Kugou and NetEase Cloud Music, asked only when LRCLIB has none for the song (or is busy).
/// Both are unofficial endpoints the music apps use themselves, answered without signing in; either may stop working
/// at any time, so a source that keeps failing is skipped for a while and the lookup goes on without it. Their catalogs
/// hold many songs LRCLIB lacks (vocaloid, utaite, Korean and Chinese releases), but also covers and remixes under the
/// same name: a result must have the song's title and be by its artist (or, where the caller allows it, have the exact
/// title and length), and its lyrics must fit the song's length. Same as src/MoreLyrics.cs.
@MainActor final class MoreLyrics {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Candidate { var source = "", id = "", key = "", title = "", artist = ""; var duration: Double = 0 }
    enum Result { case found([LyricLine], source: String), none, failed }

    private final class Source {
        let name: String
        var failures = 0
        var skipUntil = Date.distantPast
        init(_ name: String) { self.name = name }
        var paused: Bool { Date() < skipUntil }
    }

    private let session = URLSession(configuration: .ephemeral)
    private let transport: Transport?
    private let log: (String) -> Void
    private let kugou = Source("Kugou"), netease = Source("NetEase")
    private var memo: [String: Result] = [:]
    var kugouBase = "https://lyrics.kugou.com", neteaseBase = "https://music.163.com"

    init(transport: Transport? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.log = log
    }

    /// "Find lyrics again": ask the sources even if they were failing.
    func resetPause() { for s in [kugou, netease] { s.failures = 0; s.skipUntil = .distantPast } }

    /// Kugou first (its search takes the song's length), then NetEase. `.failed` when nothing was found and a source
    /// couldn't be asked (busy, unreachable, skipped for now): not a final "none".
    /// `titleTolerance`: a result by another artist with the exact title may be this far (seconds) from the song's
    /// length; negative = artist matches only. `artistTolerance`: the same for a result by the song's artist.
    func find(_ song: Song, titleTolerance: Double, artistTolerance: Double) async throws -> Result {
        let title = Self.searchTitle(song)
        guard !title.isEmpty, song.duration > 0 else { return .none }
        let memoKey = "\(LyricsProvider.norm(title))|\(LyricsProvider.norm(song.artist))|\(Int(song.duration))|\(titleTolerance)|\(artistTolerance)"
        if let known = memo[memoKey] { return known }
        var unasked = false
        for source in [kugou, netease] {
            if source.paused { unasked = true; log("INFO \(source.name) skipped (paused after repeated failures)"); continue }
            do {
                let found = source === kugou ? try await kugouSearch(song, title) : try await neteaseSearch(song, title)
                let picked = Self.choose(found, song: song, titleTolerance: titleTolerance, artistTolerance: artistTolerance)
                var result: Result?
                for c in picked.prefix(2) {
                    let text = source === kugou ? try await kugouLyrics(c) : try await neteaseLyrics(c)
                    let lines = Self.cleanLines(parseLRC(text), c)
                    if lines.count >= 3 && Self.fits(lines, own: c.duration, song: song.duration) {
                        log("INFO lyrics found via \(source.name) (\(c.artist) - \(c.title), \(Int(c.duration))s): \(song.artist) - \(song.title)")
                        result = .found(lines, source: source.name)
                        break
                    }
                }
                source.failures = 0
                if let result { remember(memoKey, result); return result }
                log("INFO \(source.name): no match among \(found.count) results for \"\(title)\" (\(picked.count) fit)")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                unasked = true
                source.failures += 1
                if source.failures >= 3 { source.skipUntil = Date().addingTimeInterval(600); source.failures = 0 }
                log("WARN \(source.name) lyrics failed for \(song.artist) - \(song.title): \(error.localizedDescription)"
                    + (source.paused ? " (skipped for 10 minutes)" : ""))
            }
        }
        if unasked { return .failed }
        remember(memoKey, .none)
        return .none
    }

    private func remember(_ key: String, _ result: Result) {
        if memo.count > 200 { memo.removeAll() }
        memo[key] = result
    }

    /// The title to search for: the original title if known, without tags and a singer's "○○ver.".
    static func searchTitle(_ song: Song) -> String {
        let t = song.alternativeTitle.trimmed.isEmpty ? song.title : song.alternativeTitle
        return CoverLyrics.withoutVersionTag(LyricsProvider.cleanTitle(LyricsProvider.withoutFeat(t))).trimmed
    }

    // MARK: Kugou: lyrics search by keyword and length, then the chosen candidate's LRC (base64)

    private func kugouSearch(_ song: Song, _ title: String) async throws -> [Candidate] {
        // Kugou finds nothing without an artist it knows ("Naisho no Pierced Earrings" for 内緒のピアス); NetEase may
        guard let artist = LyricsProvider.artistVariants(song.artist).first else { return [] }
        let d = try await json(kugouBase + "/search", ["ver": "1", "man": "yes", "client": "pc", "keyword": artist + " - " + title,
                                                      "duration": String(Int64(song.duration * 1000)), "hash": ""])
        return (d?["candidates"] as? [[String: Any]] ?? []).map { c in
            Candidate(source: "Kugou", id: Self.text(c["id"]), key: Self.text(c["accesskey"]), title: Self.text(c["song"]),
                      artist: Self.text(c["singer"]), duration: Self.number(c["duration"]) / 1000)
        }
    }

    private func kugouLyrics(_ c: Candidate) async throws -> String {
        let d = try await json(kugouBase + "/download", ["ver": "1", "client": "pc", "id": c.id, "accesskey": c.key, "fmt": "lrc", "charset": "utf8"])
        guard let content = d?["content"] as? String, let data = Data(base64Encoded: content) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: NetEase: song search (with lengths), then the chosen song's LRC

    private func neteaseSearch(_ song: Song, _ title: String) async throws -> [Candidate] {
        let q = (title + " " + (LyricsProvider.artistVariants(song.artist).first ?? "")).trimmed
        let d = try await json(neteaseBase + "/api/cloudsearch/pc", ["s": q, "type": "1", "limit": "10"])
        let songs = (d?["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.map { s in
            let artists = (s["ar"] as? [[String: Any]] ?? []).map { Self.text($0["name"]) }.filter { !$0.isEmpty }
            return Candidate(source: "NetEase", id: String(Int64(Self.number(s["id"]))), title: Self.text(s["name"]),
                             artist: artists.joined(separator: ", "), duration: Self.number(s["dt"]) / 1000)
        }
    }

    private func neteaseLyrics(_ c: Candidate) async throws -> String {
        let d = try await json(neteaseBase + "/api/song/lyric", ["id": c.id, "lv": "1"])
        let text = (d?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        return text.contains("纯音乐，请欣赏") ? "" : text   // "instrumental, enjoy": no words to show
    }

    private func json(_ base: String, _ query: [String: String]) async throws -> [String: Any]? {
        try Task.checkCancellation()
        var url = URLComponents(string: base)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 10
        request.setValue("PearNowPlaying-macOS/\(appVersion) (+https://github.com/Roena0516/pear-now-playing)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: HTTPURLResponse
        if let transport { (data, response) = try await transport(request) }
        else {
            let result = try await session.data(for: request)
            guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            (data, response) = (result.0, http)
        }
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            throw NSError(domain: url.host ?? "lyrics", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "\(url.host ?? "") \(response.statusCode)"])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    // MARK: matching (pure, tested)

    /// The candidates worth downloading, best first. The title must be the song's (ignoring tags and bracketed notes
    /// like "(feat. …)" or "(求婚)"); remixes and arrangements only for a song that is one. By the song's artist (or a
    /// Pear tag naming them) within `artistTolerance`, or by anyone with the exact title within `titleTolerance`
    /// (negative = not at all). Exact titles and closer lengths first. Same as src/MoreLyrics.cs.
    static func choose(_ found: [Candidate], song: Song, titleTolerance: Double, artistTolerance: Double) -> [Candidate] {
        var titles = Set<String>()
        for t in [song.title, song.alternativeTitle] where !t.trimmed.isEmpty {
            let clean = LyricsProvider.cleanTitle(LyricsProvider.withoutFeat(t))
            for x in [t, clean, CoverLyrics.withoutVersionTag(clean)] + CoverLyrics.titleHalves(clean) { titles.insert(LyricsProvider.norm(x)) }
        }
        titles.remove("")
        let arranged = CoverLyrics.looksArranged(song.title) || CoverLyrics.looksArranged(song.alternativeTitle)
        var ours = LyricsProvider.artistVariants(song.artist)
        let names = [song.title, song.alternativeTitle, song.album].map(LyricsProvider.norm).filter { !$0.isEmpty }
        for tag in song.tags where !names.contains(LyricsProvider.norm(tag)) {
            let t = tag.trimmed.lowercased()
            if !t.isEmpty && !ours.contains(t) { ours.append(t) }
        }
        var ranked: [(c: Candidate, rank: Int, gap: Double)] = []
        for c in found {
            if c.duration <= 0 || (!arranged && CoverLyrics.looksArranged(c.title)) { continue }
            let exact = titles.contains(LyricsProvider.norm(c.title)) || titles.contains(LyricsProvider.norm(LyricsProvider.cleanTitle(c.title)))
            if !exact && !titles.contains(LyricsProvider.norm(bare(c.title))) { continue }
            let theirs = LyricsProvider.artistVariants(c.artist)
            let byArtist = ours.contains { a in theirs.contains { b in LyricsProvider.jaroWinkler(a, b) > 0.9 } }
            let gap = abs(c.duration - song.duration)
            if byArtist && gap <= artistTolerance { ranked.append((c, exact ? 0 : 1, gap)) }
            else if exact && titleTolerance >= 0 && gap <= titleTolerance { ranked.append((c, 2, gap)) }
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.gap < $1.gap }.map(\.c)
    }

    /// The title without any bracketed part: "호랑풍류가 (시드노벨 - ′나와 호랑이님′ 주제가)" -> "호랑풍류가".
    private static func bare(_ title: String) -> String {
        LyricsProvider.cleanTitle(title.replacingOccurrences(of: #"\s*[\(（\[【［〔][^\)）\]】］〕]*[\)）\]】］〕]"#, with: " ", options: .regularExpression))
    }

    private static let credit = try! NSRegularExpression(pattern:
        #"^\s*(?:作?词|作?曲|编曲|词曲|作词作曲|作詞|編曲|作詞作曲|作編曲|演唱|歌手|原唱|翻唱|制作人?|製作|监制|出品|发行|混音|混缩|缩混|母带|和声|合声|"#
        + #"吉他|贝斯|鼓|弦乐|键盘|录音|录音师|配唱|人声|OP|SP|ISRC|Lyrics?|Lyricist|Music|Written by|Compos(?:er|ed by)|Arrange(?:r|d by)|"#
        + #"Produc(?:er|ed by)|Vocals?|Mix(?:ed by|ing)?|Master(?:ed by|ing)?|Illust(?:ration)?|Movie|Guitar|Bass|Drums)\s*[:：]"#,
        options: [.caseInsensitive])

    /// Drop the credits these services put among the lyrics ("作词 : …", "曲：…") and Kugou's opening "Title - Artist"
    /// line, which would otherwise scroll by as lyrics.
    static func cleanLines(_ lines: [LyricLine], _ c: Candidate) -> [LyricLine] {
        let title = LyricsProvider.norm(bare(c.title))
        var kept: [LyricLine] = []
        for (i, line) in lines.enumerated() {
            let text = line.text
            if credit.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { continue }
            if i < 3 && !title.isEmpty && text.contains(" - ") && LyricsProvider.norm(text).contains(title) { continue }
            kept.append(line)
        }
        // nothing but credits and blank lines: no lyrics
        guard kept.contains(where: { !$0.text.trimmed.isEmpty }) else { return [] }
        return kept.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    /// The last line within its own recording and this song (5s of slack), as LyricRecord.fits.
    static func fits(_ lines: [LyricLine], own: Double, song: Double) -> Bool {
        guard let last = lines.map(\.time).max() else { return false }
        return (own <= 0 || last <= own + 5) && (song <= 0 || last <= song + 5)
    }
}
