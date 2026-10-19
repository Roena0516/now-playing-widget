import Foundation
import CoreGraphics

@MainActor func runSelfTests() {
    let lyrics = parseLRC("[offset:200]\n[00:01.00][00:03.50]안녕 日本語\n[00:02.00]\n[ar:ignored]\n[bad]ignored")
    precondition(lyrics.count == 3 && lyrics[0].text == "안녕 日本語" && abs(lyrics[0].time - 1.2) < 0.001)
    precondition(lyrics[1].text == "♪" && abs(lyrics[2].time - 3.7) < 0.001)
    precondition(activeLyric(lyrics, at: 0) == nil && activeLyric(lyrics, at: 2.5) == 1 && activeLyric(lyrics, at: 100) == 2)
    let enhanced = parseLRC("[00:01:25]<00:01.250>hello\n[00:02.1234]second\n[offset:100]\n[offset:-200]")
    precondition(enhanced.count == 2 && enhanced[0].text == "hello" && abs(enhanced[0].time - 1.05) < 0.00001 && abs(enhanced[1].time - 1.923) < 0.00001)
    precondition(parseLRC("not a lyric [00:01]ignored").isEmpty)
    let client = PearClient(loadRemoteAssets: false)
    client.handle(["type": "PLAYER_INFO", "isPlaying": false, "position": 20, "song": ["alternativeTitle": "日本語", "songDuration": 200, "videoId": "test"]])
    precondition(client.song.title == "日本語" && client.song.paused && client.elapsed == 20)
    client.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": true, "position": 35])
    precondition(!client.song.paused && client.elapsed >= 35 && client.elapsed < 36)
    client.handle(["type": "POSITION_CHANGED", "position": 80])
    client.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": false])
    precondition(client.song.paused && client.elapsed >= 80 && client.elapsed < 81)
    precondition(parseLRC("[ar:Artist]\nplain text").isEmpty)
    client.stop()
    let socketRequest = makeWebSocketRequest(url: URL(string: "ws://127.0.0.1:26538/api/v1/ws")!, token: "test-token")
    precondition(socketRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    precondition(socketRequest.url?.query == "token=test-token", "Pear 3.12 reads the WebSocket token from the query only")
    precondition(makeWebSocketRequest(url: URL(string: "ws://127.0.0.1:26538/api/v1/ws")!, token: nil).url?.query == nil)
    testPlayerSetup()
    testOverlayPlacement()
    // a config.json written before the lyric source settings existed keeps the user's values
    let old = try! JSONDecoder().decode(Settings.self, from: Data(#"{"host":"127.0.0.1","port":26538,"scale":1.25,"position":"TopRight","showLyrics":false}"#.utf8))
    precondition(old.scale == 1.25 && old.position == "TopRight" && !old.showLyrics && old.ytmLyrics && old.ytmLyricsProxy == YTMusicProvider.defaultProxy && old.lyricsServer == "https://lrclib.net")
    precondition(Song(["mediaType": "USER_GENERATED_CONTENT", "title": "x"]).mediaType == "USER_GENERATED_CONTENT")
    print("PASS: LRC timestamps, multi-tags, offset, blank lines, lyric selection, Pear song/state/seek messages")
}

@MainActor func runIntegrationTest() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pear-integration-\(UUID().uuidString)")
    let client = PearClient(directory: directory, loadRemoteAssets: false)
    defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exercise rejection of an expired token before the successful authorization flow.
        try Data("expired-token".utf8).write(to: directory.appendingPathComponent("token.txt"))
        client.settings.port = Int(ProcessInfo.processInfo.environment["PEAR_TEST_PORT"] ?? "26539")!
        client.start()
        for _ in 0..<120 {
            if client.song.videoId == "integration-track" && client.song.paused && client.elapsed == 42 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(client.song.videoId == "integration-track", "No song received: \(client.status)")
        precondition(client.song.title == "모의 서버 日本語" && client.song.paused && client.elapsed == 42)
        let tokenFile = directory.appendingPathComponent("token.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: tokenFile.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for action in ["next", "previous", "toggle-play"] { client.control(action) }
        try await Task.sleep(for: .milliseconds(500))
        let (data, _) = try await URLSession.shared.data(from: client.baseURL.appendingPathComponent("test-controls"))
        let controls = try JSONSerialization.jsonObject(with: data) as! [String]
        precondition(Set(controls) == Set(["next", "previous", "toggle-play"]))
        let next = try await client.nextSong()
        precondition(next?.title == "다음 곡" && next?.artist == "다음 가수" && next?.videoId == "next-track01" && next?.duration == 185 && next?.mediaType == "UNKNOWN", "queue/next")
        print("PASS: expired-token reconnect, POST auth, WebSocket song/state/seek, bearer controls, token permissions, next song in the queue")
        client.stop(); try? FileManager.default.removeItem(at: directory)
        exit(0)
    } catch { fputs("Integration failed: \(error)\n", stderr); exit(1) }
}

func testPlayerSetup() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pear-setup-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        let original = Data(#"{"theme":"dark","plugins":{"unrelated":{"enabled":true},"api-server":{"enabled":false,"authStrategy":"AUTH_AT_FIRST","useHttps":true,"custom":"keep"}}}"#.utf8)
        try original.write(to: file)
        let result = try PlayerSetup.apply(to: file, port: 26538)
        precondition(result.changed && result.backup != nil)
        let backedUp = try Data(contentsOf: result.backup!)
        precondition(backedUp == original)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let plugins = updated["plugins"] as! [String: Any]
        let api = plugins["api-server"] as! [String: Any]
        precondition(updated["theme"] as? String == "dark" && plugins["unrelated"] != nil)
        precondition(api["enabled"] as? Bool == true && api["hostname"] as? String == "127.0.0.1" && api["port"] as? Int == 26538)
        precondition(api["authStrategy"] as? String == "AUTH_AT_FIRST" && api["custom"] as? String == "keep" && api["useHttps"] as? Bool == false)
        let second = try PlayerSetup.apply(to: file, port: 26538)
        precondition(!second.changed && second.backup == nil)
        let invalid = Data(#"{"plugins":[]}"#.utf8)
        try invalid.write(to: file)
        do {
            _ = try PlayerSetup.apply(to: file, port: 26538)
            preconditionFailure("Invalid config should not be replaced")
        } catch PlayerSetup.SetupError.invalidConfig { }
        let unchanged = try Data(contentsOf: file)
        precondition(unchanged == invalid)
        print("PASS: API setup preserves preferences/auth, creates exact backup, applies loopback settings, is idempotent and rejects invalid config")
    } catch { preconditionFailure("Player setup test failed: \(error)") }
}

func testOverlayPlacement() {
    // The lyric card stays on the bottom margin as the song card appears/disappears.
    // At the top, lyrics move into the space vacated by the song card.
    var legacy = Settings()
    legacy.position = "TopRight"; legacy.marginX = 40; legacy.marginY = 140; legacy.positionLayoutVersion = nil
    legacy.migratePosition()
    precondition(legacy.position == "TopRight" && legacy.marginX == 24 && legacy.marginY == 24)
    legacy.marginY = 140; legacy.marginX = 40; legacy.migratePosition()
    precondition(legacy.marginY == 140, "Migration must only run once")
    var custom = Settings(); custom.marginX = 60; custom.marginY = 80; custom.positionLayoutVersion = nil
    custom.migratePosition()
    precondition(custom.marginX == 60 && custom.marginY == 80, "Custom margins must survive migration")
    let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)
    var config = Settings()
    let bottom = NativePlacement.frames(screen: screen, config: config, cardHeight: 100, lyricHeight: 130, cardVisible: true, lyricsVisible: true)
    let bottomHidden = NativePlacement.frames(screen: screen, config: config, cardHeight: 100, lyricHeight: 130, cardVisible: false, lyricsVisible: true)
    precondition(bottom.lyrics == bottomHidden.lyrics && bottom.lyrics.minY == screen.minY + config.marginY)
    precondition(bottom.card.minY == bottom.lyrics.maxY + 10)
    let noLyrics = NativePlacement.frames(screen: screen, config: config, cardHeight: 100, lyricHeight: 130, cardVisible: true, lyricsVisible: false)
    precondition(noLyrics.card.minY == screen.minY + config.marginY)
    config.position = "TopRight"
    let top = NativePlacement.frames(screen: screen, config: config, cardHeight: 100, lyricHeight: 130, cardVisible: true, lyricsVisible: true)
    let topHidden = NativePlacement.frames(screen: screen, config: config, cardHeight: 100, lyricHeight: 130, cardVisible: false, lyricsVisible: true)
    precondition(top.card.maxY == screen.maxY - config.marginY && top.lyrics.maxY == top.card.minY - 10)
    precondition(topHidden.lyrics.maxY == top.card.maxY && top.card.maxX == screen.maxX - config.marginX)
    config.position = "BottomCenter"; config.scale = 1.5
    let scaled = NativePlacement.frames(screen: screen, config: config, cardHeight: 150, lyricHeight: 195, cardVisible: true, lyricsVisible: true)
    precondition(scaled.card.midX == screen.midX && scaled.card.minY == scaled.lyrics.maxY + 15)
    print("PASS: macOS margin migration, custom placement preservation, bottom/top/center anchoring, independent card dismissal and scaled gap")
}
