import Foundation

/// Times a cover's lyrics by the video's captions. A cover gets its original's lyrics, and the singing often starts a
/// little earlier or later than the original's (measured 2026-11-15 on 14 歌ってみた videos: -0.9 s to +2.4 s, most
/// +0.2 to +1 s). The captions' lines are matched to the lyrics' lines near the same time, and the offset most of the
/// matches agree on is used. Caption text is only compared here: never kept, shown or logged; only the offset is kept
/// (CaptionTimingStore). Same rules as src/CaptionTiming.cs.
enum CaptionTiming {
    /// How far from a lyric line its caption may be (ms).
    static let window = 15000
    /// Characters of each lyric line compared (its beginning).
    static let prefix = 8
    static let minScore = 0.75
    /// Offsets this close (ms) count as agreeing.
    static let agree = 250
    static let minAgreeing = 4

    /// Lyrics from another recording than the video: a cover's original, or an MV's official audio.
    static func applies(_ result: LyricsLookup?) -> Bool {
        guard case .synced(let lines, let source)? = result, !lines.isEmpty else { return false }
        return source.contains("원곡") || source.contains("공식 음원")
    }

    /// A cover's original's lyrics ("… · 원곡", "… · 원곡 검색"). These go without the default lead (lyricsOffsetMs'
    /// default, 0.3 s early): the user found covers' lyrics too early with it (2026-11-15). Same as src/CaptionTiming.cs.
    static func isCover(_ result: LyricsLookup?) -> Bool {
        guard case .synced(let lines, let source)? = result, !lines.isEmpty else { return false }
        return source.contains("원곡")
    }

    /// Lyrics shown without the default lead (lyricsOffsetMs' default, 0.3 s early; only the user's change to it stays):
    /// YouTube Music's own (timed to the recording, they matched its app only without the lead, 2026-11-20), and a
    /// cover's original's the captions didn't time. Same as src/CaptionTiming.cs.
    static func withoutLead(_ result: LyricsLookup?, timedByCaptions: Bool) -> Bool {
        guard case .synced(let lines, let source)? = result, !lines.isEmpty else { return false }
        return source.hasPrefix("YouTube Music") || (source.contains("원곡") && !timedByCaptions)
    }

    /// Identifies the lyrics an offset was measured against (a re-lookup may bring other lyrics).
    static func lyricsKey(_ lines: [LyricLine]) -> String {
        "\(lines.count):\(ms(lines.first?.time ?? 0)):\(ms(lines.last?.time ?? 0))"
    }

    static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// How much later (ms) the video sings than the lyrics' times, or nil when the captions don't settle it: fewer
    /// than minAgreeing matched lines agree within `agree` ms, or they are fewer than half the matches.
    static func estimate(_ lyrics: [LyricLine], _ captions: [LyricLine]) -> Int? {
        var text: [Unicode.Scalar] = [], times: [Int] = []
        for c in captions {
            let n = norm(c.text)
            text += n; times += Array(repeating: ms(c.time), count: n.count)
        }
        var offsets: [Int] = []
        for line in lyrics {
            let p = Array(norm(line.text).prefix(prefix))
            guard p.count >= 3, text.count >= p.count else { continue }
            let t = ms(line.time)
            var best = 0.0, bestOffset = 0
            for j in 0...(text.count - p.count) {
                // only from where a caption line (auto captions: a word) starts, near the lyric's time
                if abs(times[j] - t) > window || (j > 0 && times[j - 1] == times[j]) { continue }
                let r = similarity(p, Array(text[j..<(j + p.count)]))
                if r > best { best = r; bestOffset = times[j] - t }
            }
            if best >= minScore { offsets.append(bestOffset) }
        }
        guard let first = offsets.first else { return nil }
        // the offset the most matches agree with (the smaller one on a tie)
        var center = first, most = -1
        for c in offsets {
            let n = offsets.filter { abs($0 - c) <= agree }.count
            if n > most || (n == most && abs(c) < abs(center)) { most = n; center = c }
        }
        let cluster = offsets.filter { abs($0 - center) <= agree }.sorted()
        guard cluster.count >= minAgreeing, cluster.count * 2 >= offsets.count else { return nil }
        let m = cluster.count / 2
        return cluster.count % 2 == 1 ? cluster[m] : Int((Double(cluster[m - 1] + cluster[m]) / 2).rounded())
    }

    /// Letters and digits only, lower case, katakana as hiragana, without bracketed parts ("[音楽]").
    static func norm(_ s: String) -> [Unicode.Scalar] {
        let cleaned = s.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: #"[\[(（【].*?[\])）】]"#, with: "", options: .regularExpression)
        var out: [Unicode.Scalar] = []
        for var ch in cleaned.unicodeScalars {
            if (0x30A1...0x30F6).contains(ch.value), let h = Unicode.Scalar(ch.value - 0x60) { ch = h }
            switch ch.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: out.append(ch)
            default: break
            }
        }
        return out
    }

    /// 2 × the longest common subsequence / both lengths (1 = the same).
    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        guard a.count + b.count > 0 else { return 0 }
        var prev = Array(repeating: 0, count: b.count + 1), cur = prev
        for ca in a {
            for k in 0..<b.count { cur[k + 1] = ca == b[k] ? prev[k] + 1 : max(prev[k + 1], cur[k]) }
            swap(&prev, &cur)
        }
        return 2 * Double(prev[b.count]) / Double(a.count + b.count)
    }

    /// The lyrics' language as caption tracks name it: ja, ko, zh or en.
    static func language(_ lyrics: [LyricLine]) -> String {
        var kana = 0, hangul = 0, han = 0, latin = 0
        for l in lyrics {
            for u in l.text.utf16 {
                switch u {
                case 0x3040...0x30FF: kana += 1
                case 0xAC00...0xD7A3: hangul += 1
                case 0x4E00...0x9FFF: han += 1
                case 0x41...0x5A, 0x61...0x7A: latin += 1
                default: break
                }
            }
        }
        let letters = max(1, kana + hangul + han + latin)
        if kana * 20 >= letters { return "ja" }
        if hangul >= han && hangul >= latin && hangul > 0 { return "ko" }
        if han >= latin && han > 0 { return "zh" }
        return "en"
    }

    /// The offset for a video by its captions in the lyrics' language (uploaded ones first, then auto ones), or nil
    /// when none settles it. Throws when YouTube can't be reached (not to be remembered as "none").
    @MainActor static func find(_ ytm: YTMusicProvider, _ videoId: String, _ lyrics: [LyricLine]) async throws -> Int? {
        let lang = language(lyrics)
        let tracks = try await ytm.captionTracks(videoId)
            .filter { $0.language == lang || $0.language.hasPrefix(lang + "-") }
            .enumerated().sorted { ($0.element.auto ? 1 : 0, $0.offset) < ($1.element.auto ? 1 : 0, $1.offset) }.map(\.element)
            .prefix(2)
        for t in tracks {
            let captions = try await ytm.captionLines(t)
            if let offset = estimate(lyrics, captions) {
                Log.info("caption timing \(videoId): \(offset >= 0 ? "+" : "")\(offset) ms (\(t.language)\(t.auto ? " auto" : ""))")
                return offset
            }
        }
        Log.info("caption timing \(videoId): not settled (\(tracks.count) \(lang) track(s))")
        return nil
    }
}

/// Caption timings found (and "none"s), so a cover isn't measured again every time it plays. Only the video ID, the
/// lyrics it was measured against (CaptionTiming.lyricsKey) and the offset are kept, in caption-timing.json in the
/// caches folder; entries older than 30 days are measured again (captions may have been added). Same format as the
/// Windows version (CaptionTimingStore in src/CaptionTiming.cs).
final class CaptionTimingStore {
    static let maxDays = 30, maxEntries = 3000
    private struct Entry: Codable { var id: String; var lyrics: String; var ms: Int?; var day: Int }
    private struct File: Codable { var version: Int? = 1; var videos: [Entry] }

    private let file: URL
    private var entries: [Entry] = []   // oldest first

    static var defaultFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PearNowPlaying-macOS", isDirectory: true).appendingPathComponent("caption-timing.json")
    }

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(File.self, from: data) else { return }
        entries = decoded.videos.filter { LyricsTiming.canKeep($0.id) }.map {
            var e = $0; e.ms = e.ms.map { max(-LyricsTiming.limit, min(LyricsTiming.limit, $0)) }; return e
        }
    }

    private static var today: Int { Int(Date().timeIntervalSince1970 / 86400) }

    /// The video's offset measured against these lyrics: .some(nil) when it didn't settle, nil when not measured.
    func get(_ videoId: String, _ lyricsKey: String) -> Int?? {
        guard let e = entries.first(where: { $0.id == videoId && $0.lyrics == lyricsKey && Self.today - $0.day <= Self.maxDays }) else { return nil }
        return .some(e.ms)
    }

    func set(_ videoId: String, _ lyricsKey: String, _ ms: Int?) {
        entries.removeAll { $0.id == videoId || Self.today - $0.day > Self.maxDays }
        entries.append(Entry(id: videoId, lyrics: lyricsKey, ms: ms, day: Self.today))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
    }

    func forget(_ videoId: String) {
        let before = entries.count
        entries.removeAll { $0.id == videoId }
        if entries.count != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // a "none" has no "ms" (the Windows version writes null; both read either)
            let data = try JSONEncoder().encode(File(videos: entries))
            try data.write(to: file, options: .atomic)
        } catch { Log.write("WARN caption timing not saved: \(error.localizedDescription)") }
    }
}
