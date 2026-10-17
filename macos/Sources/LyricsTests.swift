import Foundation

@MainActor func runLyricsTests() async {
    let record = LyricRecord(trackName: "M@GICAL CURE! LOVE SHOT!", artistName: "SAWTOWNE feat. Hatsune Miku", duration: 202, instrumental: false, syncedLyrics: "[00:01.00]Test line", plainLyrics: "Test line")
    let song = Song(["title": "M@GICAL☆CURE! LOVE SHOT!", "alternativeTitle": "M@GICAL☆CURE! LOVE SHOT! (feat. Hatsune Miku)", "artist": "SAWTOWNE 및 初音ミク", "tags": ["SAWTOWNE", "Hatsune Miku"], "songDuration": 202])
    precondition(LyricsProvider.pick([record], song: song) != nil, "Artist tags must match multilingual artist names")
    precondition(LyricsProvider.pickByTitle([record], song: song) != nil, "Star/heart punctuation must not prevent a match")
    precondition(LyricsProvider.artistVariants("비비 (BIBI) & 윤하") == ["비비 (bibi)", "비비", "bibi", "윤하"])
    precondition(abs(LyricsProvider.jaroWinkler("martha", "marhta") - 0.961111111) < 0.00001)
    let tooFar = LyricRecord(trackName: song.title, artistName: "Unknown", duration: 206, instrumental: false, syncedLyrics: "[00:01]test")
    precondition(LyricsProvider.pickByTitle([tooFar], song: song) == nil, "Different edits must not match the three-second fallback")
    let wrongArtist = LyricRecord(trackName: "Other", artistName: "Unrelated", duration: 202, instrumental: false, syncedLyrics: "[00:01]test")
    precondition(LyricsProvider.pick([wrongArtist], song: song) == nil)
    let exactDuration = LyricRecord(trackName: song.title, artistName: "SAWTOWNE", duration: 202, instrumental: false, syncedLyrics: "[00:01]closest")
    let closeDuration = LyricRecord(trackName: song.title, artistName: "SAWTOWNE", duration: 211, instrumental: false, syncedLyrics: "[00:01]farther")
    precondition(LyricsProvider.pick([closeDuration, exactDuration], song: song)?.syncedLyrics == exactDuration.syncedLyrics)
    do {
        var urls: [URL] = []
        let provider = LyricsProvider(transport: { request in
            let url = request.url!; urls.append(url)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let isGet = url.path.hasSuffix("/get")
            let isFreeText = q.contains { $0.name == "q" }
            let body = isGet ? #"{"syncedLyrics":null,"plainLyrics":"Plain only"}"# : isFreeText ? #"[{"trackName":"Original Song","artistName":"Different Name","duration":100,"syncedLyrics":"[00:01.00]Original line"}]"# : "[]"
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let track = Song(["title": "Original Song (Official MV)", "alternativeTitle": "Original Song", "artist": "Artist", "songDuration": 100, "videoId": "lookup-test"])
        let result = try await provider.find(track)
        if case .synced(let lines, let source) = result { precondition(lines.count == 1 && source == "title match") } else { preconditionFailure("Fallback chain did not find lyrics") }
        precondition(urls.count >= 4 && urls.first?.path == "/api/get")
        let count = urls.count
        _ = try await provider.find(track)
        precondition(urls.count == count, "Successful results must be cached")
        provider.forget(track); _ = try await provider.find(track)
        precondition(urls.count > count, "Manual retry must evict cached results")
        let plainProvider = LyricsProvider(transport: { request in
            let body = request.url!.path.hasSuffix("/get") ? #"{"plainLyrics":"Only plain lyrics"}"# : #"[{"trackName":"Original Song","artistName":"Artist","duration":100,"plainLyrics":"Only plain lyrics"}]"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        if case .plainOnly = try await plainProvider.find(track) {} else { preconditionFailure("Plain lyrics must be distinguished from synced lyrics") }
        var failures = 0
        let failingProvider = LyricsProvider(transport: { request in
            failures += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        for _ in 0..<2 {
            do { _ = try await failingProvider.find(track); preconditionFailure("503 must propagate for retry") }
            catch { }
        }
        precondition(failures == 2, "Server failures must not be cached")
        let cancelled = Task { try await provider.find(track) }; cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled lookups must not publish results") } catch { }
        print("PASS: original artist/tag matching, title normalization, duration selection, fallback chain, cache eviction, plain-only diagnosis, 503 retries and cancellation")
        exit(0)
    } catch { fputs("Lyrics tests failed: \(error)\n", stderr); exit(1) }
}

@MainActor func auditLyricCandidates(songFile: String, resultsFile: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: songFile))
    let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let song = Song(dict)
    let results = try JSONDecoder().decode([LyricRecord].self, from: Data(contentsOf: URL(fileURLWithPath: resultsFile)))
    let artistMatch = LyricsProvider.pick(results, song: song)
    let titleMatch = LyricsProvider.pickByTitle(results, song: song)
    print("Candidates: \(results.count), synced: \(results.filter(\.hasSynced).count), artist/tag match: \(artistMatch != nil), normalized title match: \(titleMatch != nil)")
    if let match = artistMatch ?? titleMatch {
        print("Selected: \(match.trackName ?? "") / \(match.artistName ?? "") / \(match.duration ?? 0)s / parsed timed lines: \(parseLRC(match.syncedLyrics ?? "").count)")
    }
}
