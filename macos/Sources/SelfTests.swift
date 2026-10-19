import Foundation
import Carbon
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
    testCustomPlacement()
    // a config.json written before the lyric source settings existed keeps the user's values
    let old = try! JSONDecoder().decode(Settings.self, from: Data(#"{"host":"127.0.0.1","port":26538,"scale":1.25,"position":"TopRight","showLyrics":false}"#.utf8))
    precondition(old.scale == 1.25 && old.position == "TopRight" && !old.showLyrics && old.ytmLyrics && old.ytmLyricsProxy == YTMusicProvider.defaultProxy && old.lyricsServer == "https://lrclib.net")
    precondition(Song(["mediaType": "USER_GENERATED_CONTENT", "title": "x"]).mediaType == "USER_GENERATED_CONTENT")
    // updates: the same version comparison and release file choice as the Windows version (src/Updater.cs)
    precondition(Updater.isNewer("1.6.0", than: "1.5.2") && Updater.isNewer("v2.0", than: "1.9.9") && !Updater.isNewer("1.5.2", than: "1.5.2"))
    precondition(!Updater.isNewer("1.5.10", than: "1.6.0") && Updater.isNewer("1.5.10", than: "1.5.9") && !Updater.isNewer("abc", than: "1.0.0"))
    let release: [String: Any] = ["tag_name": "v2.0.0", "html_url": "page", "assets": [
        ["name": "PearNowPlaying-Windows-2.0.0.zip", "browser_download_url": "w", "digest": "sha256:aa"],
        ["name": "PearNowPlaying-macOS-2.0.0.dmg", "browser_download_url": "m", "digest": "sha256:BB"]]]
    precondition(Updater.info(from: release, current: "1.5.2") == UpdateInfo(version: "2.0.0", assetName: "PearNowPlaying-macOS-2.0.0.dmg", url: "m", sha256: "bb", pageURL: "page"))
    precondition(Updater.info(from: release, current: "2.0.0") == nil, "up to date")
    precondition(Updater.info(from: ["tag_name": "v2.0.0", "assets": [["name": "PearNowPlaying-macOS-2.0.0.dmg", "browser_download_url": "m"]]], current: "1.5.2") == nil,
                 "a release without a SHA-256 is not offered")
    precondition(Settings().checkUpdates, "update checks are on by default")
    // hotkeys use the Windows config format
    precondition(Hotkeys.parse("Ctrl+Alt+Up")! == (UInt32(kVK_UpArrow), UInt32(controlKey | optionKey)))
    precondition(Hotkeys.parse("ctrl + shift + F9")! == (UInt32(kVK_F9), UInt32(controlKey | shiftKey)))
    precondition(Hotkeys.parse("Win+1")! == (UInt32(kVK_ANSI_1), UInt32(cmdKey)) && Hotkeys.parse("Alt+D1")! == (UInt32(kVK_ANSI_1), UInt32(optionKey)))
    precondition(Hotkeys.parse("Ctrl+Alt") == nil && Hotkeys.parse("Ctrl+A+B") == nil && Hotkeys.parse("Ctrl++P") == nil && Hotkeys.parse("Ctrl+Nope") == nil)
    // "앨범 곡만 가사 표시": off by default; when on, only album tracks are looked up
    let albums = PearClient(loadRemoteAssets: false)
    precondition(!Settings().lyricsAlbumOnly)
    albums.settings.lyricsAlbumOnly = false
    precondition(albums.wantsLyrics(Song(title: "x", artist: "y", mediaType: "USER_GENERATED_CONTENT")))
    albums.settings.lyricsAlbumOnly = true
    precondition(albums.wantsLyrics(Song(title: "x", artist: "y", mediaType: "AUDIO")) && !albums.wantsLyrics(Song(title: "x", artist: "y", mediaType: "ORIGINAL_MUSIC_VIDEO")))
    albums.song = Song(["title": "MV", "mediaType": "ORIGINAL_MUSIC_VIDEO", "videoId": "mv"])
    albums.findLyrics()
    precondition(albums.lyricsStatus == "가사: 앨범 곡이 아니라 찾지 않음" && albums.lines.isEmpty, "non-album track: no lookup")
    albums.stop()
    let fresh = Settings()
    precondition(fresh.showOnPause && fresh.showAlbumArt && fresh.lyricsOffsetMs == 300 && fresh.hotkeyLyrics == "Ctrl+Alt+L" && fresh.hotkeyShow == "Ctrl+Alt+Up")
    let olderConfig = try! JSONDecoder().decode(Settings.self, from: Data(#"{"hotkeyNext":"","showAlbumArt":false}"#.utf8))
    precondition(olderConfig.hotkeyNext.isEmpty && !olderConfig.showAlbumArt && olderConfig.hotkeyToggle == "Ctrl+Alt+Down")
    // the card's title for videos: the song title by default, the video's own title (as Pear's Discord status) if chosen
    let titled = PearClient(loadRemoteAssets: false)
    precondition(titled.settings.videoTitle == "song" || Settings().videoTitle == "song")
    titled.settings.videoTitle = "song"
    titled.handle(["type": "PLAYER_INFO", "song": ["title": "デビルじゃないもん", "alternativeTitle": "HIMEHINA『데빌이 아닌걸』Cover【일인이역】", "mediaType": "USER_GENERATED_CONTENT", "videoId": "cover"]])
    precondition(titled.cardTitle == "デビルじゃないもん")
    titled.settings.videoTitle = "video"
    precondition(titled.cardTitle == "HIMEHINA『데빌이 아닌걸』Cover【일인이역】")
    titled.handle(["type": "PLAYER_INFO", "song": ["title": "Only Words", "alternativeTitle": "心を刺す言葉だけ (feat. 初音ミク & 可不)", "mediaType": "AUDIO", "videoId": "album"]])
    precondition(titled.cardTitle == "Only Words", "album tracks don't follow the video title setting")
    titled.handle(["type": "PLAYER_INFO", "song": ["title": "Lemon", "mediaType": "ORIGINAL_MUSIC_VIDEO", "videoId": "mv"]])
    precondition(titled.cardTitle == "Lemon", "no video title: the song title")
    titled.stop()
    // the next song's lyrics scroll on from the last song's line instead of restarting at the top
    let view = NativeLyricsLayout()
    let first = (0..<5).map { LyricLine(id: $0, time: Double($0 * 10), text: "first \($0)") }
    let second = (0..<3).map { LyricLine(id: $0, time: Double(5 + $0 * 10), text: "second \($0)") }
    view.setLines(first, width: 420)
    precondition(view.carried == 0 && view.entry(at: 45, lines: first) == 4)
    view.setLines(second, width: 420, carryFrom: 4)
    precondition(view.carried == 2 && view.entries.count == 6 && view.entries[1].text == "first 4" && view.entries[0].text == "first 3")
    precondition(abs(view.entries[1].y + view.entries[1].height + 8) < 0.001 && view.entries[2].y == 0, "the kept lines sit right above the new song")
    precondition(view.entry(at: 0, lines: second) == 2 && view.entry(at: 6, lines: second) == 3, "new lines count after the kept ones")
    view.setLines(first, width: 420, carryFrom: 2)
    precondition(view.carried == 1 && view.entries[0].text == "♪", "only this song's lines are kept, never older carried ones")
    view.setLines(second, width: 500, carryFrom: 3)
    precondition(view.carried == 0, "a new width lays out from scratch")
    print("PASS: LRC timestamps, multi-tags, offset, blank lines, lyric selection, scrolling on into the next song, Pear song/state/seek messages")
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

/// The dragged ("Custom") position: which screen and anchor a drop picks, and where the panels then go.
/// Same cases as the Windows version's Placement.FromDrop, in AppKit coordinates (origin at the bottom left).
func testCustomPlacement() {
    let one = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    let two = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: -160, width: 2560, height: 1440)]
    func check(_ column: CGRect, _ screens: [CGRect], _ expected: (Int, Double, Double, Bool), _ what: String) {
        let d = NativePlacement.fromDrop(column: column, screens: screens)
        precondition(d.monitor == expected.0 && d.x == expected.1 && d.y == expected.2 && d.fromBottom == expected.3, "\(what): \(d)")
    }
    check(CGRect(x: 100, y: 730, width: 420, height: 300), one, (0, 100, 50, false), "upper left")
    check(CGRect(x: 300, y: 80, width: 420, height: 300), one, (0, 300, 80, true), "lower half anchors to the bottom")
    check(CGRect(x: 2500, y: 980, width: 420, height: 300), two, (1, 580, 0, false), "dragged onto the second monitor (top edge clamped)")
    check(CGRect(x: 1800, y: 680, width: 420, height: 300), one, (0, 1500, 100, false), "pulled off the right edge stays on screen")
    check(CGRect(x: -500, y: 380, width: 420, height: 300), two, (0, 0, 380, true), "off every screen picks the nearest")

    var custom = Settings()
    precondition(custom.alwaysShow && custom.showLyrics && custom.ytmLyrics, "new defaults: always show, lyrics on, YouTube Music first")
    custom.position = "Custom"; custom.customX = 300; custom.customY = 80; custom.customFromBottom = true
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let low = NativePlacement.frames(screen: screen, config: custom, cardHeight: 100, lyricHeight: 200, cardVisible: true, lyricsVisible: true)
    precondition(low.lyrics.minX == 300 && low.lyrics.minY == 80 && low.card.minY == 80 + 200 + 10, "bottom-anchored custom: lyrics on the spot, card above")
    custom.customFromBottom = false; custom.customY = 50
    let high = NativePlacement.frames(screen: screen, config: custom, cardHeight: 100, lyricHeight: 200, cardVisible: false, lyricsVisible: true)
    precondition(high.lyrics.maxY == 1080 - 50, "top-anchored custom: lyrics move up when the card is gone")
    let decoded = try! JSONDecoder().decode(Settings.self, from: Data(#"{"position":"Custom","customX":12,"customY":34,"customFromBottom":false}"#.utf8))
    precondition(decoded.position == "Custom" && decoded.customX == 12 && decoded.customY == 34 && !decoded.customFromBottom)
    // widgets, one per screen
    let legacy16 = try! JSONDecoder().decode(Settings.self, from: Data(#"{"position":"Custom","monitor":1,"customX":120,"customY":80,"customFromBottom":false}"#.utf8))
    precondition(legacy16.widgets == [WidgetSetting(monitor: 1, position: "Custom", customX: 120, customY: 80, customFromBottom: false)], "1.6 widget carried over")
    let many = try! JSONDecoder().decode(Settings.self, from: Data(#"{"widgets":[{"monitor":2,"position":"TopRight","customX":0,"customY":0,"customFromBottom":true},{"monitor":0,"position":"BottomLeft","customX":24,"customY":24,"customFromBottom":true},{"monitor":2,"position":"TopLeft","customX":0,"customY":0,"customFromBottom":true}]}"#.utf8))
    precondition(many.widgets.map(\.monitor) == [0, 2] && many.widgets[1].position == "TopRight", "sorted by screen, one widget per screen")
    precondition(many.shownWidgets(screenCount: 3).count == 2 && many.shownWidgets(screenCount: 1).map(\.monitor) == [0], "widgets on missing screens are hidden")
    var orphan = Settings(); orphan.widgets = [WidgetSetting(monitor: 3, position: "TopCenter")]
    precondition(orphan.shownWidgets(screenCount: 2) == [WidgetSetting(monitor: 0, position: "TopCenter")], "no widget on a connected screen: the first one on the main screen")
    let roundTrip = try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(many))
    precondition(roundTrip.widgets == many.widgets)
    let wide = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let left = NativePlacement.frames(screen: wide, config: many.placed(many.widgets[0]), cardHeight: 100, lyricHeight: 0, cardVisible: true, lyricsVisible: false)
    let right = NativePlacement.frames(screen: wide, config: many.placed(many.widgets[1]), cardHeight: 100, lyricHeight: 0, cardVisible: true, lyricsVisible: false)
    precondition(left.card.minX < 100 && left.card.minY < 100 && right.card.maxX > 1800 && right.card.maxY > 1000, "each widget follows its own position")
    print("PASS: dragged position (screen choice, top/bottom anchor, clamping), custom placement, new defaults, one widget per screen with its own position")
}
