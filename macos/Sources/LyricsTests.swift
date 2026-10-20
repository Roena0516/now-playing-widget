import Foundation

@MainActor func runLyricsTests() async {
    runCoverTests()
    runDisplayTitleTests()
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
    precondition(LyricsProvider.lookupRetryFor == 600 && LyricsProvider().retryWait == 15)
    precondition(abs(LyricsProvider.jaroWinkler("martha", "marhta") - 0.961111111) < 0.00001)
    let tooFar = LyricRecord(trackName: song.title, artistName: "Unknown", duration: 206, instrumental: false, syncedLyrics: "[00:01]test")
    precondition(LyricsProvider.pickByTitle([tooFar], song: song) == nil, "Different edits must not match the three-second fallback")
    let wrongArtist = LyricRecord(trackName: "Other", artistName: "Unrelated", duration: 202, instrumental: false, syncedLyrics: "[00:01]test")
    precondition(LyricsProvider.pick([wrongArtist], song: song) == nil)
    // "instrumental" only for this very version, and not when an entry of it has words (PUPA (Endorfin. Remix))
    let pupa = Song(["title": "PUPA (Endorfin. Remix)", "artist": "Morimori Atsushi", "album": "PUPA -Metamorphoses-", "songDuration": 222])
    let uma = LyricRecord(trackName: "PUPA (uma Remix) [feat. uma]", artistName: "Morimori Atsushi", duration: 216, instrumental: true, syncedLyrics: nil, plainLyrics: nil)
    let extended = LyricRecord(trackName: "PUPA", artistName: "Morimori Atsushi", duration: 216, instrumental: true, syncedLyrics: nil, plainLyrics: nil)
    precondition(LyricsProvider.pick([uma, extended], song: pupa) == nil, "another version's instrumental mark doesn't count")
    let marked = LyricRecord(trackName: "PUPA (Endorfin. Remix)", artistName: "Morimori Atsushi", duration: 222, instrumental: true, syncedLyrics: nil, plainLyrics: nil)
    let worded = LyricRecord(trackName: "PUPA (feat. Endorfin.) [Endorfin. Remix]", artistName: "Morimori Atsushi", duration: 222, instrumental: false, syncedLyrics: nil, plainLyrics: "words")
    precondition(LyricsProvider.pick([marked], song: pupa)?.instrumental == true, "this version's own mark counts")
    precondition(LyricsProvider.pick([marked, worded], song: pupa) == nil, "but not when an entry of this version has words")
    let original = Song(["title": "PUPA", "artist": "Morimori Atsushi", "songDuration": 128])
    precondition(LyricsProvider.pick([LyricRecord(trackName: "Pupa", artistName: "Morimori Atsushi", duration: 128, instrumental: true, syncedLyrics: nil, plainLyrics: nil)], song: original)?.instrumental == true)
    // romanized title and artist from Pear, the original title from YouTube Music: the entry crediting ササノマリイ (a tag)
    let kanade = Song(["title": "kanade tomosu sora nekobolo version", "alternativeTitle": "カナデトモスソラ　ねこぼーろver.", "artist": "Sasanomaly", "album": "nekobolo selection", "songDuration": 256,
                       "tags": ["Sasanomaly", "ササノマリイ", "nekobolo", "ねこぼーろ", "ネコボーロ", "nekobolo selection", "kanade tomosu sora nekobolo version"]])
    let unit = LyricRecord(trackName: "カナデトモスソラ", artistName: "25時、ナイトコードで。", duration: 257, instrumental: false, syncedLyrics: "[00:01.00]a")
    let credited = LyricRecord(trackName: "カナデトモスソラ (feat. 宵崎奏&朝比奈まふゆ&東雲絵名&暁山瑞希&巡音ルカ)", artistName: "ササノマリイ/ねこぼーろ/25時、ナイトコードで。/巡音ルカ", duration: 257, instrumental: false, syncedLyrics: "[00:01.00]b")
    precondition(LyricsProvider.pick([unit, credited], song: kanade)?.syncedLyrics == "[00:01.00]b", "the original title lets a tag vouch for the artist")
    // an entry whose lyrics run on past its own (wrong) length isn't used: "Bad Apple!!" listed as 232s, lines up to 305s
    let apple = Song(title: "Bad Apple!!", artist: "Bad Apple!! feat. nomico", videoId: "badapple001", duration: 222)
    let long = (0..<64).map { String(format: "[%02d:%05.2f]line %d", Int(Double($0) * 4.78) / 60, (Double($0) * 4.78).truncatingRemainder(dividingBy: 60), $0) }.joined(separator: "\n")
    let mislabeled = LyricRecord(trackName: "Bad Apple!! feat.nomico", artistName: "nomico", duration: 232, instrumental: false, syncedLyrics: long)
    precondition(!mislabeled.fits(222) && LyricsProvider.pick([mislabeled], song: apple) == nil, "lyrics longer than the entry aren't used")
    precondition(LyricsProvider.pickByTitle([mislabeled], song: Song(title: "Bad Apple!! feat.nomico", artist: "x", duration: 232), tolerance: 3) == nil, "nor by title")
    let fitting = LyricRecord(trackName: "Bad Apple!! feat.nomico", artistName: "nomico", duration: 319, instrumental: false, syncedLyrics: long)
    precondition(fitting.fits(319) && !fitting.fits(222), "the same lyrics fit the full-length song, not a shorter one")
    // title-only matches: the lyrics uploaded most often win, and a named original artist needs 3 identical uploads
    let pvLyrics = "[00:29.10]流れてく\n[03:26.20]end"
    let pv = (1...3).map { LyricRecord(trackName: "【東方】Bad Apple!! ＰＶ【影絵】", artistName: "kasidid2", duration: 220, instrumental: false, syncedLyrics: pvLyrics, id: $0) }
    let oneCover = LyricRecord(trackName: "Bad Apple!!!", artistName: "FalKKonE and Rena", duration: 221, instrumental: false, syncedLyrics: "[00:27.32]流れてく\n[03:25.95]end", id: 9)
    let short = Song(title: "Bad Apple!!", artist: "nomico", duration: 222)
    precondition(LyricsProvider.pickByTitle([oneCover] + pv, song: short, tolerance: 10)?.artistName == "kasidid2", "the version uploaded 3 times beats one cover, 【PV】 tags ignored")
    let english = LyricRecord(trackName: "Bad Apple", artistName: "Touhou/Cristina Vee", duration: 219, instrumental: false, syncedLyrics: "[00:29.20]Ever on and on\n[03:35.70]end", id: 8)
    precondition(LyricsProvider.pickByTitle([oneCover, english], song: short, tolerance: 10, copies: 3) == nil, "two different covers and no clear winner: nothing")
    precondition(LyricsProvider.pickByTitle([oneCover, english] + pv, song: short, tolerance: 10, copies: 3)?.artistName == "kasidid2", "three identical uploads win")
    precondition(LyricsProvider.pickByTitle([oneCover], song: short, tolerance: 10, copies: 3)?.artistName == "FalKKonE and Rena", "a single kind of match is taken as is (ryo / supercell)")
    // another song's lyrics uploaded several times under this title lose to lyrics that sing the title
    let mislabeled2 = (1...4).map { LyricRecord(trackName: "チュルリラ・チュルリラ・ダッダッダ!", artistName: "ワンダーランズ×ショウタイム", duration: 197, instrumental: false, syncedLyrics: "[00:01.00]エビバディ→解体！\n[03:00.00]トンデモワンダーズ", id: $0) }
    let singsTitle = LyricRecord(trackName: "チュルリラ・チュルリラ・ダッダッダ!", artistName: "和田たけあき(くらげP)", duration: 196, instrumental: false, syncedLyrics: "[00:15.00]ざっと数えて40名\n[01:00.00]チュルリラ チュルリラ ダッダッダ", id: 9)
    precondition(LyricsProvider.pickByTitle(mislabeled2 + [singsTitle], song: Song(title: "チュルリラ・チュルリラ・ダッダッダ！", artist: "x", duration: 197))?.artistName == "和田たけあき(くらげP)", "lyrics that sing the title win")
    // a tag only vouches for the artist: "LAMIA" by BlackY (tagged with its own title) must not take Lamia's song
    let lamia = Song(["title": "LAMIA", "alternativeTitle": "LAMIA", "artist": "BlackY", "album": "ONGEKI Sound Collection 06",
                      "tags": ["BlackY", "ブラッキー", "ONGEKI Sound Collection 06", "LAMIA"], "songDuration": 150])
    let rapper = LyricRecord(trackName: "MALLLOPPO (feat. SASV)", artistName: "Lamia", duration: 146, instrumental: false, syncedLyrics: "[00:10.85]Ah, ah, sembra GTA V")
    precondition(LyricsProvider.pick([rapper], song: lamia) == nil, "a tag that is the title is not an artist name")
    var tagged = lamia; tagged.tags = ["Lamia"]
    precondition(LyricsProvider.pick([rapper], song: tagged) == nil, "a match through a tag needs the song's title")
    let kana = Song(["title": "LAMIA", "artist": "ブラッキー", "tags": ["BlackY"], "songDuration": 150])
    let byTag = LyricRecord(trackName: "LAMIA", artistName: "BlackY", duration: 150, instrumental: false, syncedLyrics: "[00:01.00]x")
    precondition(LyricsProvider.pick([byTag], song: kana) != nil, "another spelling of the artist in the tags still matches")
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
        if case .synced(let lines, let source) = result { precondition(lines.count == 1 && source == "LRCLIB") } else { preconditionFailure("Fallback chain did not find lyrics") }
        let gets = urls.filter { $0.path == "/api/get" }.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value }
        precondition(urls.first?.path == "/api/get" && gets == ["Original Song (Official MV)", "Original Song"], "Exact lookups also try the alternative / cleaned title")
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
        resilient.jitter = { 0 }
        if case .synced = try await resilient.find(track) {} else { preconditionFailure("A busy endpoint must recover after one quick retry") }
        precondition(recoveredRequests == 2 && recoveredWaits == [8], "Retry-After honored: \(recoveredWaits)")
        for status in [429, 502, 503, 504] {
            var requests = 0
            var waits: [TimeInterval] = []
            let busy = LyricsProvider(transport: { request in
                requests += 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "1"])!)
            }, sleep: { waits.append($0) })
            busy.jitter = { 0 }
            do { _ = try await busy.find(track); preconditionFailure("Busy service must end this lookup") }
            catch { precondition(LyricsProvider.isBusy(error)) }
            if status == 429 { precondition(requests == 1 && waits.isEmpty, "rate limited: the lookup ends at once (Kugou / NetEase stand in)") }
            else { precondition(requests == 4 && waits == [1, 1, 1], "asked again after each Retry-After, 4 times, then no other searches: \(requests) \(waits)") }
        }
        // a long Retry-After: not waited for in this lookup, but the next request waits for it
        var longWaits: [TimeInterval] = []
        var longRequests = 0
        let banned = LyricsProvider(transport: { request in
            longRequests += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }, sleep: { longWaits.append($0) })
        banned.jitter = { 0 }
        do { _ = try await banned.find(track); preconditionFailure("Rate limited lookup must end") } catch { }
        precondition(longRequests == 1 && longWaits.isEmpty, "Retry-After 120: lookup ends at once")
        precondition(banned.retryWait == 1, "after a busy answer the lookup is tried again soon (the requests wait for Retry-After)")
        do { _ = try await banned.find(track) } catch { }
        precondition(longWaits.first.map { $0 > 119 && $0 <= 120 } == true, "and the next request waits it out: \(longWaits)")
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
        await runFinderTests()
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

/// The whole lookup order (LyricsFinder), with YouTube and LRCLIB answered locally.
@MainActor func runFinderTests() async {
    func lrclib(_ handler: @escaping (URL) -> (Int, String)) -> LyricsProvider {
        LyricsProvider(transport: { request in
            let (status, body) = handler(request.url!)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in })
    }
    let synced = #"[{"trackName":"Song","artistName":"Band","duration":200,"syncedLyrics":"[00:01.00]From LRCLIB"}]"#
    let noTab: YTMusicProvider.Transport = { request in try FakeYouTube.ok(request, FakeYouTube.next(FakeYouTube.body(request)["videoId"] as? String ?? "")) }
    let song = Song(title: "Song", artist: "Band", videoId: "audioVideo1", mediaType: "AUDIO", duration: 200)
    do {
        // found results are cached; forget() asks again
        var asked = 0
        let finder = LyricsFinder(lrclib: lrclib { url in asked += 1; return url.path.hasSuffix("/get") ? (404, "") : (200, synced) }, ytm: YTMusicProvider(transport: noTab))
        guard case .synced(_, let source) = try await finder.find(song), source == "LRCLIB" else { preconditionFailure("LRCLIB after YouTube Music had none") }
        let count = asked
        _ = try await finder.find(song); precondition(asked == count, "Found lyrics are cached")
        finder.forget(song); _ = try await finder.find(song); precondition(asked > count, "Manual retry must evict cached results")

        // a look-ahead that finds nothing doesn't stop the real lookup when the song starts
        asked = 0
        let ahead = LyricsFinder(lrclib: lrclib { url in asked += 1; return url.path.hasSuffix("/get") ? (404, "") : (200, "[]") }, ytm: YTMusicProvider(transport: noTab))
        try await ahead.prefetch(Song(title: "Song", artist: "Band", videoId: "audioVideo1", mediaType: "UNKNOWN", duration: 200))
        let afterPrefetch = asked
        if case .notFound = try await ahead.find(song) {} else { preconditionFailure("Nothing to find") }
        precondition(asked > afterPrefetch, "A miss while fetching ahead must not be cached")
        let afterFind = asked
        _ = try await ahead.find(song); precondition(asked == afterFind, "A miss with YouTube Music answering is final")

        // YouTube Music down: "not found" is not final
        asked = 0
        let ytmDown = LyricsFinder(lrclib: lrclib { url in asked += 1; return url.path.hasSuffix("/get") ? (404, "") : (200, "[]") },
                                   ytm: YTMusicProvider(transport: { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) }))
        _ = try await ytmDown.find(song); let first = asked
        _ = try await ytmDown.find(song); precondition(asked == first * 2, "A miss while YouTube Music failed is asked again")

        // MV: the official audio track's lyrics
        let mvSong = Song(title: "Song (Official Music Video)", artist: "Band", videoId: "mvVideo0001", mediaType: "ORIGINAL_MUSIC_VIDEO", duration: 200)
        let catalog = LyricsFinder(lrclib: lrclib { _ in preconditionFailure("LRCLIB not needed") }, ytm: YTMusicProvider(transport: { request in
            let body = FakeYouTube.body(request)
            switch body["videoId"] as? String ?? body["browseId"] as? String ?? "" {
            case "mvVideo0001": return try FakeYouTube.ok(request, FakeYouTube.next("mvVideo0001", title: "Song (Official Music Video)", artist: "Band", artistId: "UCband",
                                                                                     length: "3:20", type: "MUSIC_VIDEO_TYPE_OMV", lyricsId: "lyrMV"))
            case "lyrMV": return try FakeYouTube.ok(request, FakeYouTube.unavailable)
            case "UCband": return try FakeYouTube.ok(request, FakeYouTube.artistPage([("MPREb_song", "Song")]))
            case "MPREb_song": return try FakeYouTube.ok(request, FakeYouTube.album([("atvVideo001", "Song", "3:21")]))
            case "atvVideo001": return try FakeYouTube.ok(request, FakeYouTube.next("atvVideo001", title: "Song", artist: "Band", length: "3:21", type: "MUSIC_VIDEO_TYPE_ATV", lyricsId: "lyrATV"))
            case "lyrATV": return try FakeYouTube.ok(request, FakeYouTube.timed([(1000, "From the audio track")]))
            case let other: preconditionFailure("unexpected request \(other)")
            }
        }))
        guard case .synced(let audioLines, "YouTube Music · 공식 음원") = try await catalog.find(mvSong), audioLines.first?.text == "From the audio track" else {
            preconditionFailure("MV must use the official audio track's lyrics")
        }

        // cover: the original linked in the description
        let cover = Song(title: "【歌ってみた】ヴァンパイア / DECO*27 covered by X", artist: "X", videoId: "coverVideo1", mediaType: "USER_GENERATED_CONTENT", duration: 200)
        let covers = LyricsFinder(lrclib: lrclib { _ in preconditionFailure("LRCLIB not needed") }, ytm: YTMusicProvider(transport: { request in
            let body = FakeYouTube.body(request)
            if request.url!.path.hasSuffix("/player") {
                precondition(body["videoId"] as? String == "coverVideo1")
                return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "原曲\nhttps://youtu.be/origVideo01\n\nMix: https://youtu.be/mixVideo001"]])
            }
            switch body["videoId"] as? String ?? body["browseId"] as? String ?? "" {
            case "coverVideo1": return try FakeYouTube.ok(request, FakeYouTube.next("coverVideo1"))
            case "origVideo01": return try FakeYouTube.ok(request, FakeYouTube.next("origVideo01", title: "ヴァンパイア", artist: "DECO*27", length: "3:22", type: "MUSIC_VIDEO_TYPE_ATV", lyricsId: "lyrOrig"))
            case "lyrOrig": return try FakeYouTube.ok(request, FakeYouTube.timed([(1000, "From the original")]))
            case let other: preconditionFailure("unexpected request \(other)")
            }
        }))
        guard case .synced(let coverLines, "YouTube Music · 원곡") = try await covers.find(cover), coverLines.first?.text == "From the original" else {
            preconditionFailure("A cover must use the original's lyrics")
        }
        // the lyrics relay down (502): the original is still identified and looked up on LRCLIB
        let relayDown = LyricsFinder(lrclib: lrclib { url in
            if url.path.hasSuffix("/get") { return (404, "") }
            return (200, #"[{"trackName":"ヴァンパイア","artistName":"DECO*27","duration":202,"syncedLyrics":"[00:01.00]From LRCLIB\n[00:05.00]two"}]"#)
        }, ytm: YTMusicProvider(transport: { request in
            if request.url!.host?.contains("ytmbrowseproxy") == true { return (Data("error code: 502".utf8), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!) }
            let body = FakeYouTube.body(request)
            if request.url!.path.hasSuffix("/player") {
                return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "原曲\nhttps://youtu.be/origVideo01"]])
            }
            switch body["videoId"] as? String ?? "" {
            case "coverVideo1": return try FakeYouTube.ok(request, FakeYouTube.next("coverVideo1"))
            case "origVideo01": return try FakeYouTube.ok(request, FakeYouTube.next("origVideo01", title: "ヴァンパイア", artist: "DECO*27", length: "3:22", type: "MUSIC_VIDEO_TYPE_ATV", lyricsId: "lyrOrig"))
            case let other: preconditionFailure("unexpected request \(other)")
            }
        }))
        guard case .synced(let relayLines, "LRCLIB · 원곡") = try await relayDown.find(cover), relayLines.first?.text == "From LRCLIB" else {
            preconditionFailure("relay down: the cover's original must still be looked up on LRCLIB")
        }

        // cover without links: song name read from the title, looked up on LRCLIB with a 10s length tolerance
        var queries: [String] = []
        let byTitle = LyricsFinder(lrclib: lrclib { url in
            queries.append(url.query ?? "")
            if url.path.hasSuffix("/get") { return (404, "") }
            return (200, #"[{"trackName":"ワールドイズマイン","artistName":"supercell","duration":208,"syncedLyrics":"[00:01.00]From the original search"}]"#)
        }, ytm: YTMusicProvider(transport: { request in
            if request.url!.path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "いつもありがとうございます"]]) }
            return try FakeYouTube.ok(request, FakeYouTube.next(FakeYouTube.body(request)["videoId"] as? String ?? ""))
        }))
        let unlinked = Song(title: "ワールドイズマイン / ryo(covered by 誰か)", artist: "誰か", videoId: "coverVideo2", mediaType: "USER_GENERATED_CONTENT", duration: 200)
        guard case .synced(_, "LRCLIB · 원곡 검색") = try await byTitle.find(unlinked) else { preconditionFailure("Cover without a link must fall back to the title") }
        precondition(queries.contains { $0.contains("track_name=%E3%83%AF") || $0.contains("track_name=ワ") })

        // the original is linked but 13s off, and LRCLIB has another song of the same name and the cover's exact
        // length: no lyrics, rather than that song's (a VoiSona cover of JUNKY's メランコリック picked ナノ's)
        var homonymAsked = 0
        let homonym = LyricsFinder(lrclib: lrclib { url in
            homonymAsked += 1
            if url.path.hasSuffix("/get") { return (404, "") }
            return (200, #"[{"trackName":"メランコリック","artistName":"ナノ","duration":233,"syncedLyrics":"[00:01.00]another song"}]"#)
        }, ytm: YTMusicProvider(transport: { request in
            let body = FakeYouTube.body(request)
            if request.url!.path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "Vocal : 雨衣\nご本家様 → https://youtu.be/junkyMelan1"]]) }
            switch body["videoId"] as? String ?? "" {
            case "junkyMelan1": return try FakeYouTube.ok(request, FakeYouTube.next("junkyMelan1", title: "メランコリック / Junky feat.鏡音リン", artist: "JUNKY", length: "3:40", type: "MUSIC_VIDEO_TYPE_OMV"))
            case let id: return try FakeYouTube.ok(request, FakeYouTube.next(id))
            }
        }))
        let voisona = Song(title: "「メランコリック」covered by 雨衣", artist: "VoiSona公式", videoId: "voisonaMel1", mediaType: "USER_GENERATED_CONTENT", duration: 233)
        guard case .notFound = try await homonym.find(voisona) else { preconditionFailure("a same-name song must not stand in for a known original") }
        precondition(homonymAsked > 0, "the cover's own LRCLIB search still runs, with artist matches only")

        // the linked original's video is 16s longer, but the description names the artist: found by that artist
        // within the cover's tolerance (코가네 랑's 호랑풍류가), and never another artist's song of the same name
        let named = LyricsFinder(lrclib: lrclib { url in
            if url.path.hasSuffix("/get") { return (404, "") }
            return (200, #"[{"trackName":"호랑풍류가","artistName":"다른 가수","duration":253,"syncedLyrics":"[00:01.00]wrong"},{"trackName":"호랑풍류가 (시드노벨 - ′나와 호랑이님′ 주제가)","artistName":"나래 (Narae)","duration":251,"syncedLyrics":"[00:01.00]right"}]"#)
        }, ytm: YTMusicProvider(transport: { request in
            let body = FakeYouTube.body(request)
            if request.url!.path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "🐯Original: 상록수 feat. 나래(Narae) - 호랑풍류가\nhttps://youtu.be/horangMV001"]]) }
            switch body["videoId"] as? String ?? "" {
            case "horangMV001": return try FakeYouTube.ok(request, FakeYouTube.next("horangMV001", title: "[Music] 상록수 feat. 나래(Narae) - 호랑풍류가", artist: "SQUARE MUSIQ", length: "4:29", type: "MUSIC_VIDEO_TYPE_UGC"))
            case let id: return try FakeYouTube.ok(request, FakeYouTube.next(id))
            }
        }))
        let rang = Song(title: "호랑풍류가 [나와 호랑이님 OST] / 코가네 랑 (Cogane Rang) Cover", artist: "코가네 랑 COGANE RANG", videoId: "rangCover01", mediaType: "USER_GENERATED_CONTENT", duration: 253)
        guard case .synced(let rangLines, _) = try await named.find(rang), rangLines.first?.text == "right" else { preconditionFailure("the artist the description names finds the original") }

        // an original titled "日本語 - English" that LRCLIB lists only under the English half (MIMI's Only Words)
        let halves = LyricsFinder(lrclib: lrclib { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.path.hasSuffix("/get") {
                return items.first { $0.name == "track_name" }?.value == "Only Words" ? (200, #"{"trackName":"Only Words","artistName":"MIMI","duration":192,"syncedLyrics":"[00:01.00]only words"}"#) : (404, "")
            }
            return (200, "[]")
        }, ytm: YTMusicProvider(transport: { request in
            let body = FakeYouTube.body(request)
            if request.url!.path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "原曲: https://youtu.be/mimiOnlyMV1"]]) }
            switch body["videoId"] as? String ?? "" {
            case "mimiOnlyMV1": return try FakeYouTube.ok(request, FakeYouTube.next("mimiOnlyMV1", title: "心を刺す言葉だけ - Only Words (feat. Hatsune Miku & KAFU)", artist: "MIMI", length: "3:12", type: "MUSIC_VIDEO_TYPE_OMV"))
            case let id: return try FakeYouTube.ok(request, FakeYouTube.next(id))
            }
        }))
        let enCover = Song(title: "心を刺す言葉だけ/ MIMI covered byえん × yureru.", artist: "えん / neG", videoId: "enCover0001", mediaType: "USER_GENERATED_CONTENT", duration: 196)
        guard case .synced(let halfLines, _) = try await halves.find(enCover), halfLines.first?.text == "only words" else { preconditionFailure("the English half of the original's title finds it") }

        // LRCLIB busy while looking for the original: the lookup fails (retried later), nothing cached
        var busyCalls = 0
        let busy = LyricsFinder(lrclib: lrclib { _ in busyCalls += 1; return (503, "") }, ytm: YTMusicProvider(transport: { request in
            if request.url!.path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "-"]]) }
            return try FakeYouTube.ok(request, FakeYouTube.next(FakeYouTube.body(request)["videoId"] as? String ?? ""))
        }))
        do { _ = try await busy.find(unlinked); preconditionFailure("Busy LRCLIB must fail the lookup") } catch { precondition(error is LrclibFailed) }
        let firstBusy = busyCalls
        do { _ = try await busy.find(unlinked); preconditionFailure("Busy LRCLIB must fail again") } catch { }
        precondition(busyCalls == firstBusy * 2, "Failures are not cached")
        // a cover's description is asked for while YouTube Music is still being asked about the video itself
        var events: [String] = []
        let parallel = LyricsFinder(lrclib: lrclib { url in url.path.hasSuffix("/get") ? (404, "") : (200, "[]") }, ytm: YTMusicProvider(transport: { request in
            let path = request.url!.path, id = FakeYouTube.body(request)["videoId"] as? String ?? ""
            events.append("start \(path) \(id)")
            if path.hasSuffix("/next") && id == "coverVideo3" { try await Task.sleep(for: .milliseconds(300)) }
            defer { events.append("end \(path) \(id)") }
            if path.hasSuffix("/player") { return try FakeYouTube.ok(request, ["videoDetails": ["shortDescription": "-"]]) }
            return try FakeYouTube.ok(request, FakeYouTube.next(id))
        }))
        _ = try await parallel.find(Song(title: "【歌ってみた】Song covered by X", artist: "X", videoId: "coverVideo3", mediaType: "USER_GENERATED_CONTENT", duration: 200))
        let playerStart = events.firstIndex(of: "start /youtubei/v1/player coverVideo3"), nextEnd = events.firstIndex(of: "end /youtubei/v1/next coverVideo3")
        precondition(playerStart != nil && nextEnd != nil && playerStart! < nextEnd!, "The description is fetched alongside the first lookup: \(events)")

        // a look-ahead that failed (busy) succeeds on a later try, and the song then starts without asking LRCLIB
        var lrclibCalls = 0
        let retried = LyricsFinder(lrclib: lrclib { url in
            lrclibCalls += 1
            if lrclibCalls <= LyricsProvider.attempts { return (503, "") }
            return url.path.hasSuffix("/get") ? (404, "") : (200, synced)
        }, ytm: YTMusicProvider(transport: noTab))
        let queued = Song(title: "Song", artist: "Band", videoId: "audioVideo1", mediaType: "UNKNOWN", duration: 200)
        do { try await retried.prefetch(queued); preconditionFailure("busy look-ahead must fail") } catch { precondition(!(error is CancellationError)) }
        try await retried.prefetch(queued)
        let callsBeforeStart = lrclibCalls
        precondition(retried.known(Song(title: "Other", artist: "Band", videoId: "otherVideo1", mediaType: "AUDIO", duration: 200)) == nil, "unknown songs need a lookup")
        guard case .synced = retried.known(song) else { preconditionFailure("fetched-ahead lyrics are known at once, so the card can swap them in place") }
        guard case .synced = try await retried.find(song) else { preconditionFailure("fetched-ahead lyrics must be used") }
        precondition(lrclibCalls == callsBeforeStart, "A song fetched ahead must not ask LRCLIB again when it starts")
        // lyrics found on LRCLIB are kept on disk and used by the next run without asking anyone
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pear-lyrics-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let offline: LyricsProvider.Transport = { _ in preconditionFailure("must not ask LRCLIB") }
        let offlineYtm: YTMusicProvider.Transport = { _ in preconditionFailure("must not ask YouTube") }
        let firstRun = LyricsFinder(lrclib: lrclib { url in url.path.hasSuffix("/get") ? (404, "") : (200, synced) }, ytm: YTMusicProvider(transport: noTab),
                                    disk: LyricsDiskCache(directory: dir))
        _ = try await firstRun.find(song)
        precondition(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audioVideo1.json").path), "LRCLIB lyrics saved")
        let nextRun = LyricsFinder(lrclib: LyricsProvider(transport: offline), ytm: YTMusicProvider(transport: offlineYtm), disk: LyricsDiskCache(directory: dir))
        guard case .synced(let storedLines, "LRCLIB") = try await nextRun.find(song), storedLines.first?.text == "From LRCLIB", storedLines.first?.time == 1 else {
            preconditionFailure("The next run must read the saved lyrics")
        }
        nextRun.forget(song)
        precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audioVideo1.json").path), "Find-again removes saved lyrics")
        precondition(!LyricsDiskCache.keeps(.synced([LyricLine(id: 0, time: 1, text: "x")], source: "YouTube Music · 공식 음원")))
        precondition(LyricsDiskCache.keeps(.synced([LyricLine(id: 0, time: 1, text: "x")], source: "LRCLIB · 원곡 검색")) && !LyricsDiskCache.keeps(.notFound))
        let small = LyricsDiskCache(directory: dir, maxEntries: 3)
        try Data(#"{"version":1,"videoId":"oldVideo001","title":"","artist":"","source":"LRCLIB","instrumental":false,"savedAt":"2000-01-01T00:00:00Z","lines":[{"timeMs":1,"text":"x"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("oldVideo001.json"))
        precondition(small.load("oldVideo001") == nil && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("oldVideo001.json").path), "Expired entries are dropped")
        try Data(#"{"version":5,"videoId":"oldFormat01","title":"","artist":"","source":"LRCLIB · 원곡 검색","instrumental":false,"savedAt":"\#(ISO8601DateFormatter().string(from: Date()))","lines":[{"timeMs":1,"text":"x"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("oldFormat01.json"))
        precondition(small.load("oldFormat01") == nil, "entries of older formats are looked up again")
        small.save(Song(title: "x", artist: "y", videoId: "../../evil1"), .instrumental)
        precondition(small.load("../../evil1") == nil, "Invalid video IDs are not used as file names")
        for i in 0..<6 { small.save(Song(title: "t", artist: "a", videoId: "prune00000\(i)"), .synced([LyricLine(id: 0, time: 1, text: "x")], source: "LRCLIB")) }
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count
        precondition(kept <= 3, "Kept under the size limit (\(kept))")

        // Kugou / NetEase: matching rules
        typealias C = MoreLyrics.Candidate
        let usagi = Song(title: "回る空うさぎ", artist: "Orangestar", duration: 173)
        let chosen = MoreLyrics.choose([C(title: "アスノヨゾラ哨戒班", artist: "Orangestar, IA", duration: 177),
                                        C(title: "回る空うさぎ（Cover Orangestar / 初音未来）", artist: "シンシン", duration: 176),
                                        C(title: "回る空うさぎ", artist: "Orangestar、初音ミク", duration: 174)], song: usagi, titleTolerance: 3, artistTolerance: 15)
        precondition(chosen.map(\.duration) == [174], "same artist and title only, not the artist's other song or a cover: \(chosen)")
        precondition(MoreLyrics.choose([C(title: "トンデモワンダーズ (Self Remix)", artist: "sasakure.UK", duration: 200), C(title: "トンデモワンダーズ", artist: "sasakure.UK, 初音ミク", duration: 197)],
                                       song: Song(title: "トンデモワンダーズ", artist: "sasakure.UK", duration: 195), titleTolerance: 3, artistTolerance: 15).map(\.duration) == [197], "no remix for the original")
        precondition(MoreLyrics.choose([C(title: "호랑풍류가 (시드노벨 - ′나와 호랑이님′ 주제가)", artist: "나래", duration: 250)],
                                       song: Song(title: "호랑풍류가", artist: "나래", duration: 251), titleTolerance: 3, artistTolerance: 15).count == 1, "bracketed notes ignored")
        let anyone = Song(title: "メランコリック", artist: "", duration: 220)
        precondition(MoreLyrics.choose([C(title: "メランコリック", artist: "Junky", duration: 226)], song: anyone, titleTolerance: -1, artistTolerance: 10).isEmpty, "title-only off")
        precondition(MoreLyrics.choose([C(title: "メランコリック", artist: "Junky", duration: 221)], song: anyone, titleTolerance: 3, artistTolerance: 10).count == 1, "exact title within 3s")
        var tagged = Song(title: "プロポーズ", artist: "Naisho no Pierced Earrings", duration: 232); tagged.tags = ["内緒のピアス", "プロポーズ"]
        precondition(MoreLyrics.choose([C(title: "プロポーズ", artist: "内緒のピアス", duration: 232)], song: tagged, titleTolerance: -1, artistTolerance: 15).count == 1, "Pear's tag names the artist")
        let cleaned = MoreLyrics.cleanLines(parseLRC("[00:00.00]プロポーズ - 内緒のピアス\n[00:00.24]词：内緒のピアス\n[00:00.41]曲：内緒のピアス\n[00:00.62]例えば君が明日死ぬなら\n[00:01.00] 作曲 : X\n[00:06.21]僕は今から笑って"),
                                            C(title: "プロポーズ", artist: "内緒のピアス"))
        precondition(cleaned.map(\.text) == ["例えば君が明日死ぬなら", "僕は今から笑って"] && cleaned.map(\.id) == [0, 1], "credits dropped: \(cleaned.map(\.text))")
        precondition(MoreLyrics.cleanLines(parseLRC("[00:00.00] 作词 : A\n[00:01.00] 作曲 : B"), C(title: "Z")).isEmpty, "credits only: no lyrics")

        // Kugou / NetEase in the lookup: after LRCLIB finds nothing (or is busy), kept on disk; a failing source isn't a final miss
        let kugouLrc = Data("[00:00.00]Song - Band\n[00:01.00]From Kugou\n[00:02.00]two\n[00:03.00]three".utf8).base64EncodedString()
        var moreAsked: [String] = []
        func more(kugouDown: Bool = false, kugouHas: Bool = true) -> MoreLyrics {
            MoreLyrics(transport: { request in
                let path = request.url!.path; moreAsked.append(path)
                func ok(_ body: Any) throws -> (Data, HTTPURLResponse) { (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
                if kugouDown && request.url!.host == "lyrics.kugou.com" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
                switch path {
                case "/search": return try ok(["candidates": kugouHas ? [["id": "1", "accesskey": "k", "song": "Song", "singer": "Band", "duration": 201000]] : []])
                case "/download": return try ok(["content": kugouLrc])
                case "/api/cloudsearch/pc": return try ok(["result": ["songs": [["id": 7, "name": "Song (feat. X)", "ar": [["name": "Other"]], "dt": 200000]]]])
                case "/api/song/lyric": return try ok(["lrc": ["lyric": "[00:00.00] 作词 : A\n[00:01.00]From NetEase\n[00:02.00]b\n[00:03.00]c"]])
                default: preconditionFailure("unexpected \(path)")
                }
            })
        }
        let moreDir = FileManager.default.temporaryDirectory.appendingPathComponent("pear-lyrics-more-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moreDir) }
        let withKugou = LyricsFinder(lrclib: lrclib { url in url.path.hasSuffix("/get") ? (404, "") : (200, "[]") }, ytm: YTMusicProvider(transport: noTab),
                                     more: more(), disk: LyricsDiskCache(directory: moreDir))
        guard case .synced(let kLines, "Kugou") = try await withKugou.find(song), kLines.first?.text == "From Kugou" else { preconditionFailure("Kugou after LRCLIB had none") }
        precondition(LyricsDiskCache(directory: moreDir).load(song.videoId) != nil, "Kugou lyrics saved")
        let busyDir = FileManager.default.temporaryDirectory.appendingPathComponent("pear-lyrics-busy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: busyDir) }
        // LRCLIB busy (503): asked again, no Kugou / NetEase
        moreAsked = []
        let lrclib503 = LyricsFinder(lrclib: lrclib { _ in (503, "") }, ytm: YTMusicProvider(transport: noTab), more: more())
        do { _ = try await lrclib503.find(song); preconditionFailure("503: the lookup fails, to ask LRCLIB again") } catch { precondition(!(error is CancellationError)) }
        precondition(moreAsked.isEmpty, "503: Kugou / NetEase not asked: \(moreAsked)")
        // LRCLIB rate-limited (429): Kugou / NetEase stand in
        let lrclibBusy = LyricsFinder(lrclib: lrclib { _ in (429, "") }, ytm: YTMusicProvider(transport: noTab), more: more(kugouHas: false),
                                      disk: LyricsDiskCache(directory: busyDir))
        guard case .synced(let nLines, "NetEase") = try await lrclibBusy.find(song), nLines.first?.text == "From NetEase" else { preconditionFailure("NetEase (exact title within 3s) while LRCLIB rate-limits") }
        precondition(LyricsDiskCache(directory: busyDir).load(song.videoId) == nil, "a stand-in for a rate-limited LRCLIB is not saved to disk")
        guard case .synced = lrclibBusy.known(song) else { preconditionFailure("but it is remembered for this run") }
        // Kugou / NetEase lyrics: LRCLIB is asked again (recheck) when it was busy, and in a later run when it had none
        var lrclibStatus = 429
        let recheckDir = FileManager.default.temporaryDirectory.appendingPathComponent("pear-lyrics-recheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recheckDir) }
        func makeFinder() -> LyricsFinder {
            LyricsFinder(lrclib: lrclib { url in lrclibStatus == 429 ? (429, "") : url.path.hasSuffix("/get") ? (404, "") : (200, lrclibStatus == 200 ? synced : "[]") },
                         ytm: YTMusicProvider(transport: noTab), more: more(), disk: LyricsDiskCache(directory: recheckDir))
        }
        let rechecked = makeFinder()
        let standIn = try await rechecked.find(song)
        guard case .synced(_, "Kugou") = standIn, rechecked.shouldRecheck(song, standIn) else { preconditionFailure("stand-in while LRCLIB is busy") }
        moreAsked = []
        let stillBusy = try await rechecked.recheck(song)
        precondition(stillBusy == nil && rechecked.shouldRecheck(song, standIn), "still busy: the stand-in stays")
        lrclibStatus = 200
        guard case .synced(let back, let backSource)? = try await rechecked.recheck(song), backSource.hasPrefix("LRCLIB"), back.first?.text == "From LRCLIB"
        else { preconditionFailure("LRCLIB back: its lyrics replace the stand-in") }
        precondition(LyricsDiskCache(directory: recheckDir).load(song.videoId) != nil, "LRCLIB's lyrics saved")
        let laterSong = Song(title: "Song", artist: "Band", videoId: "audioVideo4", mediaType: "AUDIO", duration: 200)
        lrclibStatus = 429
        _ = try await rechecked.find(laterSong)
        lrclibStatus = 404
        guard case .synced(_, "Kugou")? = try await rechecked.recheck(laterSong) else { preconditionFailure("LRCLIB has none: Kugou's are final") }
        guard let saved = LyricsDiskCache(directory: recheckDir).load(laterSong.videoId), !rechecked.shouldRecheck(laterSong, saved) else { preconditionFailure("saved, not asked again this run") }
        let laterRun = makeFinder()
        guard let fromDisk = laterRun.known(laterSong), laterRun.shouldRecheck(laterSong, fromDisk) else { preconditionFailure("next run: LRCLIB asked again") }
        guard case .synced(_, "Kugou")? = try await laterRun.recheck(laterSong), !laterRun.shouldRecheck(laterSong, fromDisk) else { preconditionFailure("still none: kept") }
        lrclibStatus = 200
        let afterAdded = makeFinder()
        guard case .synced(_, let addedSource)? = try await afterAdded.recheck(laterSong), addedSource.hasPrefix("LRCLIB"),
              case .synced(_, let savedSource)? = LyricsDiskCache(directory: recheckDir).load(laterSong.videoId), savedSource.hasPrefix("LRCLIB")
        else { preconditionFailure("LRCLIB added it: replaced and saved") }
        precondition(moreAsked.isEmpty, "rechecks ask LRCLIB only: \(moreAsked)")
        moreAsked = []
        let kugouFailing = LyricsFinder(lrclib: lrclib { url in url.path.hasSuffix("/get") ? (404, "") : (200, "[]") }, ytm: YTMusicProvider(transport: noTab), more: more(kugouDown: true))
        let offSong = Song(title: "Nothing", artist: "Nobody", videoId: "audioVideo2", mediaType: "AUDIO", duration: 200)
        if case .notFound = try await kugouFailing.find(offSong) {} else { preconditionFailure("nothing to find") }
        let firstMore = moreAsked.count
        _ = try await kugouFailing.find(offSong)
        precondition(moreAsked.count > firstMore, "a miss while Kugou failed is asked again")
        kugouFailing.useMore = false; moreAsked = []
        _ = try await kugouFailing.find(Song(title: "Else", artist: "Nobody", videoId: "audioVideo3", mediaType: "AUDIO", duration: 200))
        precondition(moreAsked.isEmpty, "moreLyrics off: not asked")
        precondition(LyricsDiskCache.keeps(.synced([LyricLine(id: 0, time: 1, text: "x")], source: "NetEase · 원곡")))
        print("PASS: lookup order (YouTube Music, official audio, cover originals by link and by title, LRCLIB, Kugou / NetEase), caching rules, look-ahead misses and retries, busy LRCLIB, cover description in parallel, found lyrics on disk")
    } catch { fputs("Finder tests failed: \(error)\n", stderr); exit(1) }
}
