import Foundation

/// Canned YouTube Music / YouTube answers for the tests. Nothing here talks to the network.
enum FakeYouTube {
    static func endpoint(_ id: String, _ pageType: String, params: String? = nil) -> [String: Any] {
        var be: [String: Any] = ["browseId": id, "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": pageType]]]
        if let params { be["params"] = params }
        return ["browseEndpoint": be]
    }
    /// /next for a video: its queue entry (title, artist, length, type, artist page) and, optionally, a lyrics tab.
    static func next(_ videoId: String, title: String = "", artist: String = "", artistId: String = "", length: String = "",
                     type: String = "", lyricsId: String? = nil) -> [String: Any] {
        var tabs: [Any] = []
        if let lyricsId { tabs.append(["tabRenderer": ["endpoint": endpoint(lyricsId, "MUSIC_PAGE_TYPE_TRACK_LYRICS")]]) }
        var byline: [Any] = [["text": artist]]
        if !artistId.isEmpty { byline = [["text": artist, "navigationEndpoint": endpoint(artistId, "MUSIC_PAGE_TYPE_ARTIST")]] }
        let entry: [String: Any] = ["videoId": videoId, "title": ["runs": [["text": title]]], "shortBylineText": ["runs": byline],
                                    "lengthText": ["runs": [["text": length]]],
                                    "navigationEndpoint": ["watchEndpoint": ["watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]]]
        return ["contents": ["tabs": tabs], "queue": [["playlistPanelVideoRenderer": entry]]]
    }
    static func timed(_ lines: [(Int, String)]) -> [String: Any] {
        ["contents": ["timedLyricsModel": ["lyricsData": ["timedLyricsData": lines.map { ["lyricLine": $0.1, "cueRange": ["startTimeMilliseconds": String($0.0)]] }]]]]
    }
    static let unavailable: [String: Any] = ["contents": ["musicMessageModel": ["text": "Lyrics not available at this time."]]]
    static func artistPage(_ releases: [(String, String)]) -> [String: Any] {
        ["contents": ["items": releases.map { ["musicTwoRowItemRenderer": ["title": ["runs": [["text": $0.1]]],
                                                                         "navigationEndpoint": endpoint($0.0, "MUSIC_PAGE_TYPE_ALBUM")]] }]]
    }
    static func album(_ tracks: [(String, String, String)]) -> [String: Any] {
        ["contents": ["items": tracks.map { ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": $0.0],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": $0.1]]]]]],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": $0.2]]]]]]]] }]]
    }
    static func ok(_ request: URLRequest, _ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }
}

@MainActor func runYTMusicTests() async {
    let next = FakeYouTube.next("test-video", title: "Test Song", artist: "Tester", artistId: "UCtest", length: "3:21", type: "MUSIC_VIDEO_TYPE_ATV", lyricsId: "lyrics-test")
    let timed = FakeYouTube.timed([(1250, "First test line"), (2500, "♪")])
    precondition(YTMusicProvider.lyricsBrowseID(in: next) == "lyrics-test")
    var info = TrackInfo(videoId: "test-video")
    YTMusicProvider.readQueueEntry(next, into: &info)
    precondition(info.title == "Test Song" && info.artist == "Tester" && info.duration == 201 && info.videoType == "MUSIC_VIDEO_TYPE_ATV" && info.artistId == "UCtest")
    if case .synced(let lines, let source) = YTMusicProvider.parse(timed) {
        precondition(source == "YouTube Music" && lines.count == 2 && lines[0].time == 1.25 && lines[1].text == "♪")
    } else { preconditionFailure("Timed YTMusic data did not parse") }
    if case .notFound = YTMusicProvider.parse(FakeYouTube.unavailable) {} else { preconditionFailure("Unavailable message is not lyrics") }
    let plain: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Plain test line"]]]]]]]]]
    if case .plainOnly = YTMusicProvider.parse(plain) {} else { preconditionFailure("Plain lyrics must not be treated as timed") }
    precondition(YTMusicProvider.webRemixVersion.range(of: #"^1\.\d{8}\.01\.00$"#, options: .regularExpression) != nil, "WEB_REMIX version follows the dated format")
    precondition(YTMusicProvider.parseClock("1:02:03") == 3723 && YTMusicProvider.parseClock("4:x") == 0)
    do {
        var requests: [URLRequest] = []
        let provider = YTMusicProvider(transport: { request in
            requests.append(request)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(!request.httpShouldHandleCookies && request.httpMethod == "POST")
            let url = request.url!
            if url.path.hasSuffix("/next") { return try FakeYouTube.ok(request, next) }
            precondition(url.host != "music.youtube.com", "Lyrics come through Pear's relay only (direct browse never has them)")
            let body = FakeYouTube.body(request)
            precondition(Set(body.keys) == Set(["browseId", "context"]), "Relay must not receive account tokens, metadata or cookies")
            // the relay redirects; the POST and its body must survive the hop
            if url.host == "ytmbrowseproxy.zvz.be" {
                return (Data(), HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://b-ytmbrowseproxy.zvz.be/browse"])!)
            }
            precondition(url.host == "b-ytmbrowseproxy.zvz.be" && body["browseId"] as? String == "lyrics-test")
            return try FakeYouTube.ok(request, timed)
        })
        let found = try await provider.lookup("test-video")
        precondition(found.lines.count == 2 && found.title == "Test Song")
        precondition(requests.count == 3, "next + relay + redirected relay")
        _ = try await provider.lookup("test-video"); precondition(requests.count == 3, "Lookups are remembered for the session")
        provider.forget("test-video"); _ = try await provider.lookup("test-video"); precondition(requests.count == 6)
        let task = Task { try await provider.lookup("other-video") }; task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled YTMusic results must be suppressed") } catch { }

        // the relay is skipped for a while after three failures in a row, and a manual retry lifts that
        var failing = 0
        let down = YTMusicProvider(transport: { request in
            failing += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        for id in ["a", "b", "c"] { do { _ = try await down.lookup(id); preconditionFailure("500 must throw") } catch { } }
        precondition(down.paused && failing == 3)
        down.resetPause(); precondition(!down.paused)

        // MV -> artist page -> single -> official audio track of the same length
        let mv = TrackInfo(videoId: "mv", title: "Song (Official Music Video)", artist: "Band", artistId: "UCband", videoType: "MUSIC_VIDEO_TYPE_OMV", duration: 200)
        var pages: [String] = []
        let catalog = YTMusicProvider(transport: { request in
            let id = FakeYouTube.body(request)["browseId"] as? String ?? ""
            pages.append(id)
            switch id {
            case "UCband": return try FakeYouTube.ok(request, FakeYouTube.artistPage([("MPREb_other", "Other"), ("MPREb_song", "Song")]))
            case "MPREb_song": return try FakeYouTube.ok(request, FakeYouTube.album([("wrongLength", "Song", "4:10"), ("atvSong0001", "Song", "3:21")]))
            default: preconditionFailure("unexpected page \(id)")
            }
        })
        let audio = try await catalog.findAudioTrack(mv)
        precondition(audio == "atvSong0001" && pages == ["UCband", "MPREb_song"], "Official audio found by name and length")
        _ = try await catalog.findAudioTrack(mv); precondition(pages.count == 2, "Audio tracks are remembered")

        // the closest title, not the first that matches: サツキ's 「メズマライザー」 also has an English version single of
        // about the same length ("Mesmerizer" matched once the brackets were left out, and its English lyrics were shown)
        let original = TrackInfo(videoId: "19y8YTbvri8", title: "メズマライザー - Mesmerizer", artist: "サツキ", artistId: "UCsatsuki", videoType: "MUSIC_VIDEO_TYPE_OMV", duration: 157)
        func versions(_ releases: [(String, String)]) -> (YTMusicProvider, () -> [String]) {
            var asked: [String] = []
            let provider = YTMusicProvider(transport: { request in
                let id = FakeYouTube.body(request)["browseId"] as? String ?? ""
                asked.append(id)
                switch id {
                case "UCsatsuki": return try FakeYouTube.ok(request, FakeYouTube.artistPage(releases))
                case "MPREb_en": return try FakeYouTube.ok(request, FakeYouTube.album([("englishVer1", "Mesmerizer (Official English Version)", "2:38")]))
                case "MPREb_ja": return try FakeYouTube.ok(request, FakeYouTube.album([("japanese001", "メズマライザー", "2:37"), ("instrumenta", "メズマライザー (Instrumental)", "2:37")]))
                default: preconditionFailure("unexpected page \(id)")
                }
            })
            return (provider, { asked })
        }
        let both = versions([("MPREb_en", "Mesmerizer (Official English Version)"), ("MPREb_ja", "メズマライザー")])
        let closest = try await both.0.findAudioTrack(original)
        precondition(closest == "japanese001" && both.1() == ["UCsatsuki", "MPREb_ja"], "The release and track named exactly come first")
        let englishOnly = versions([("MPREb_en", "Mesmerizer (Official English Version)")])
        let fallback = try await englishOnly.0.findAudioTrack(original)
        precondition(fallback == "englishVer1", "Another version still serves when it is all there is")
        precondition(CoverLyrics.titleCloseness("心を刺す言葉だけ (feat. 初音ミク & 可不)", ["心を刺す言葉だけ", "Only Words"]) == 0
                     && CoverLyrics.titleCloseness("メズマライザー (Instrumental)", ["メズマライザー"]) == 1
                     && CoverLyrics.titleCloseness("メズマライザーズ", ["メズマライザー"]) == 2)
        print("PASS: YTMusic lyric-tab discovery, queue entry, timed/plain/unavailable parsing, relay-only browse with redirect, credential isolation, memo and eviction, relay pause, official audio track search (closest title first), cancellation")
        exit(0)
    } catch { fputs("YTMusic tests failed: \(error)\n", stderr); exit(1) }
}
@MainActor func auditYTMusic(_ file: String) throws {
    let response = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
    switch YTMusicProvider.parse(response) {
    case .synced(let lines, _): print("YTMusic live response: \(lines.count) timed lines parsed")
    case .plainOnly: print("YTMusic live response: plain lyrics only")
    default: print("YTMusic live response: no lyrics")
    }
}
