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
    precondition(LyricsProvider.lookupRetryDelays == [0, 15, 45])
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
            if lrclibCalls <= 2 { return (503, "") }
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
        try Data(#"{"version":3,"videoId":"oldFormat01","title":"","artist":"","source":"LRCLIB · 원곡 검색","instrumental":false,"savedAt":"\#(ISO8601DateFormatter().string(from: Date()))","lines":[{"timeMs":1,"text":"x"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("oldFormat01.json"))
        precondition(small.load("oldFormat01") == nil, "entries of older formats are looked up again")
        small.save(Song(title: "x", artist: "y", videoId: "../../evil1"), .instrumental)
        precondition(small.load("../../evil1") == nil, "Invalid video IDs are not used as file names")
        for i in 0..<6 { small.save(Song(title: "t", artist: "a", videoId: "prune00000\(i)"), .synced([LyricLine(id: 0, time: 1, text: "x")], source: "LRCLIB")) }
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count
        precondition(kept <= 3, "Kept under the size limit (\(kept))")
        print("PASS: lookup order (YouTube Music, official audio, cover originals by link and by title, LRCLIB), caching rules, look-ahead misses and retries, busy LRCLIB, cover description in parallel, LRCLIB lyrics on disk")
    } catch { fputs("Finder tests failed: \(error)\n", stderr); exit(1) }
}
