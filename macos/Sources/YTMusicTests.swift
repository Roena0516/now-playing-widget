import Foundation

@MainActor func runYTMusicTests() async {
    let next: [String: Any] = ["contents": ["tabs": [["tabRenderer": ["endpoint": ["browseEndpoint": ["browseId": "lyrics-test", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"]]]]]]]]]
    let timed: [String: Any] = ["contents": ["timedLyricsModel": ["lyricsData": ["timedLyricsData": [["lyricLine": "First test line", "cueRange": ["startTimeMilliseconds": "1250", "endTimeMilliseconds": "2000"]], ["lyricLine": "♪", "cueRange": ["startTimeMilliseconds": "2500", "endTimeMilliseconds": "3000"]]]]]]]
    precondition(YTMusicProvider.lyricsBrowseID(in: next) == "lyrics-test")
    if case .synced(let lines, let source) = YTMusicProvider.parse(timed) {
        precondition(source == "YTMusic" && lines.count == 2 && lines[0].time == 1.25 && lines[1].text == "♪")
    } else { preconditionFailure("Timed YTMusic data did not parse") }
    let unavailable: [String: Any] = ["contents": ["musicMessageModel": ["text": "Lyrics not available at this time."]]]
    if case .notFound = YTMusicProvider.parse(unavailable) {} else { preconditionFailure("Unavailable message is not lyrics") }
    let plain: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": ["description": ["runs": [["text": "Plain test line"]]]]]]]]]
    if case .plainOnly = YTMusicProvider.parse(plain) {} else { preconditionFailure("Plain lyrics must not be treated as timed") }
    do {
        var requests = 0
        let provider = YTMusicProvider(transport: { request in
            requests += 1
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(!request.httpShouldHandleCookies)
            let url = request.url!
            let response: [String: Any]
            if url.path.hasSuffix("/next") { response = next }
            else if url.host == "music.youtube.com" { response = unavailable }
            else {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(Set(body.keys) == Set(["browseId", "context"]), "Proxy must not receive account tokens, metadata or cookies")
                response = timed
            }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let song = Song(["videoId": "test-video", "title": "Test"])
        if case .synced(let lines, _) = try await provider.find(song) { precondition(lines.count == 2) } else { preconditionFailure("Provider fallback failed") }
        precondition(requests == 3)
        _ = try await provider.find(song); precondition(requests == 3)
        provider.forget(song); _ = try await provider.find(song); precondition(requests == 6)
        let task = Task { try await provider.find(song) }; task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled YTMusic results must be suppressed") } catch { }
        print("PASS: YTMusic lyric-tab discovery, timed/plain/unavailable parsing, direct-to-Pear-provider fallback, credential isolation, cache eviction and cancellation")
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
