import Foundation

@MainActor func runLyricsTests() async {
    let record = LyricRecord(trackName: "M@GICAL CURE! LOVE SHOT!", artistName: "SAWTOWNE feat. Hatsune Miku", duration: 202, instrumental: false, syncedLyrics: "[00:01.00]Test line", plainLyrics: "Test line")
    let song = Song(["title": "M@GICAL☆CURE! LOVE SHOT!", "alternativeTitle": "M@GICAL☆CURE! LOVE SHOT! (feat. Hatsune Miku)", "artist": "SAWTOWNE 및 初音ミク", "tags": ["SAWTOWNE", "Hatsune Miku"], "songDuration": 202])
    precondition(LyricsProvider.pick([record], song: song) != nil, "Artist tags must match multilingual artist names")
    precondition(LyricsProvider.pickByTitle([record], song: song) != nil, "Star/heart punctuation must not prevent a match")
    precondition(LyricsProvider.artistVariants("비비 (BIBI) & 윤하") == ["비비 (bibi)", "비비", "bibi", "윤하"])
    precondition(LyricsProvider.artistVariants("supercell 및 初音ミク") == ["supercell", "初音ミク"])
    precondition(LyricsProvider.artistVariants("Artist と Singer") == ["artist", "singer"])
    for (input, expected) in [
        ("【歌ってみた】曲名 / covered by 誰か", "曲名"),
        ("曲名【MV】", "曲名"),
        ("Title (Official Video)", "Title"),
        ("曲名（残す） / Cover by Singer", "曲名（残す）"),
        (" / 曲名　歌ってみた - ", "曲名"),
        ("Song (Cover)", "Song"),
        ("Song (Live Version)", "Song")
    ] { precondition(LyricsProvider.cleanTitle(input) == expected, "Unexpected cleaned title: \(input)") }
    precondition(LyricsProvider.lookupRetryDelays == [0, 15, 45])
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
        }, sleep: { _ in })
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
        }, sleep: { _ in })
        if case .plainOnly = try await plainProvider.find(track) {} else { preconditionFailure("Plain lyrics must be distinguished from synced lyrics") }
        var recoveredRequests = 0
        var recoveredWaits: [TimeInterval] = []
        let resilient = LyricsProvider(transport: { request in
            recoveredRequests += 1
            let body = recoveredRequests == 1 ? "{}" : #"{"trackName":"Original Song","artistName":"Artist","duration":100,"syncedLyrics":"[00:01.00]Recovered"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: recoveredRequests == 1 ? 503 : 200, httpVersion: nil, headerFields: ["Retry-After": "8"])!)
        }, sleep: { recoveredWaits.append($0) })
        if case .synced = try await resilient.find(track) {} else { preconditionFailure("A busy endpoint must recover after one quick retry") }
        precondition(recoveredRequests == 2 && recoveredWaits == [8])
        for status in [429, 502, 503, 504] {
            var requests = 0
            var waits: [TimeInterval] = []
            let busy = LyricsProvider(transport: { request in
                requests += 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
            }, sleep: { waits.append($0) })
            do { _ = try await busy.find(track); preconditionFailure("Busy service must end this lookup") }
            catch { precondition(LyricsProvider.isBusy(error)) }
            precondition(requests == 2 && waits == [10], "Do not flood other searches while the server is busy")
        }
        var backoffStarted = false
        var backoffRequests = 0
        let cancellable = LyricsProvider(transport: { request in
            backoffRequests += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in backoffStarted = true; try await Task.sleep(for: .seconds(30)) })
        let pending = Task { try await cancellable.find(track) }
        for _ in 0..<100 { if backoffStarted { break }; await Task.yield() }
        precondition(backoffStarted)
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled backoff must not retry") } catch { }
        precondition(backoffRequests == 1)
        var failures = 0
        let failingProvider = LyricsProvider(transport: { request in
            failures += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in })
        var firstFailures = 0
        for iteration in 0..<2 {
            do { _ = try await failingProvider.find(track); preconditionFailure("503 must propagate for retry") }
            catch { }
            if iteration == 0 { firstFailures = failures }
        }
        precondition(firstFailures > 0 && failures == firstFailures * 2, "Server failures must not be cached")
        let cancelled = Task { try await provider.find(track) }; cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled lookups must not publish results") } catch { }
        print("PASS: original artist/tag matching, title normalization, duration selection, fallback chain, cache eviction, plain-only diagnosis, bounded busy retries, Retry-After, cancellation during backoff and video-title cleanup")
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
