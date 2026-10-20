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
    // lines sharing a stamp (a romanization under each line): only the first is kept
    let doubled = parseLRC("[00:03.78]知りたいその秘密\n[00:00.87]無敵の笑顔で\n[00:00.87]Muteki no egao de\n[00:03.78]Shiritai sono himitsu\n[00:05.00](You're my savior)\n[00:05.00](You're my savior)")
    precondition(doubled.map(\.text) == ["無敵の笑顔で", "知りたいその秘密", "(You're my savior)"] && doubled.map(\.id) == [0, 1, 2], "first line per stamp: \(doubled.map(\.text))")
    let savedDir = FileManager.default.temporaryDirectory.appendingPathComponent("pear-lyrics-doubled-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: savedDir) }
    let saved = LyricsDiskCache(directory: savedDir)
    saved.save(Song(title: "アイドル", artist: "YOASOBI", videoId: "doubledVid1", duration: 215),
               .synced([LyricLine(id: 0, time: 0.87, text: "無敵の笑顔で"), LyricLine(id: 1, time: 0.87, text: "Muteki no egao de"), LyricLine(id: 2, time: 3.78, text: "知りたい")], source: "LRCLIB"))
    guard case .synced(let reloaded, _)? = saved.load("doubledVid1"), reloaded.map(\.text) == ["無敵の笑顔で", "知りたい"] else { preconditionFailure("saved lines sharing a stamp: first only") }
    let client = PearClient(loadRemoteAssets: false)
    client.handle(["type": "PLAYER_INFO", "isPlaying": false, "position": 20, "song": ["alternativeTitle": "日本語", "songDuration": 200, "videoId": "test"]])
    precondition(client.song.title == "日本語" && client.song.paused && client.elapsed == 20)
    client.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": true, "position": 35])
    precondition(!client.song.paused && client.elapsed >= 35 && client.elapsed < 36)
    client.handle(["type": "POSITION_CHANGED", "position": 80])
    client.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": false])
    precondition(client.song.paused && client.elapsed >= 80 && client.elapsed < 81)
    // Pear's position 0 just before VIDEO_CHANGED (recorded 0.3s apart) isn't a rewind of the ending song
    client.handle(["type": "POSITION_CHANGED", "position": 198])
    client.handle(["type": "POSITION_CHANGED", "position": 0])
    precondition(client.elapsed >= 198, "position 0 at the end waits for the next song")
    client.handle(["type": "VIDEO_CHANGED", "position": 0, "song": ["title": "next", "songDuration": 180, "videoId": "next"]])
    precondition(client.song.title == "next" && client.elapsed < 1)
    // recorded 2026-10-20: 190, then 115 (about the next song's length), then 0, then VIDEO_CHANGED
    client.handle(["type": "POSITION_CHANGED", "position": 150])
    client.handle(["type": "POSITION_CHANGED", "position": 115])
    precondition(client.elapsed >= 150, "a jump back waits a tick")
    client.handle(["type": "POSITION_CHANGED", "position": 0])
    precondition(client.elapsed >= 150, "and 0 right after it doesn't carry on from it either")
    client.handle(["type": "VIDEO_CHANGED", "position": 0, "song": ["title": "after", "songDuration": 114, "videoId": "after"]])
    precondition(client.song.title == "after" && client.elapsed < 1)
    client.handle(["type": "POSITION_CHANGED", "position": 100])
    client.handle(["type": "POSITION_CHANGED", "position": 60])
    client.handle(["type": "POSITION_CHANGED", "position": 61])
    precondition(client.elapsed >= 61 && client.elapsed < 62, "a seek back shows once the next tick carries on from it")
    client.handle(["type": "POSITION_CHANGED", "position": 50])
    client.handle(["type": "POSITION_CHANGED", "position": 0])
    precondition(client.elapsed >= 50, "position 0 from mid-song also waits a tick (the length can be off, or songs overlap)")
    client.handle(["type": "POSITION_CHANGED", "position": 1])
    precondition(client.elapsed >= 1 && client.elapsed < 2, "a seek to the start shows on the next tick")
    client.handle(["type": "POSITION_CHANGED", "position": 0])
    precondition(client.elapsed < 1, "near the start, 0 is taken at once")
    precondition(parseLRC("[ar:Artist]\nplain text").isEmpty)
    client.stop()
    browserSourceTests()
    coverSearchTests()
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
    precondition(view.carried == 4 && view.entries[0].text == "♪" && view.carriedCurrent == 0, "near the end the rest of the song stays too, never older carried lines")
    // the next song's lines wait below this song's last line, and after the change sit exactly there
    view.setLines(first, width: 420)
    view.setNext(second)
    precondition(view.entries.count == 9 && view.ownEnd == 5 && view.entries[5].text == "♪", "the next song's lines follow the last one")
    precondition(view.entry(at: 999, lines: first) == 4, "the highlight never moves into the next song's lines")
    let waiting = view.entries[5].y - view.entries[3].y
    view.setLines(second, width: 420, carryFrom: 3)
    precondition(view.carried == 3 && view.carriedCurrent == 1 && view.entries[3].text == "♪", "the change keeps what was in view")
    precondition(abs((view.entries[3].y - view.entries[1].y) - waiting) < 0.001, "the next song's lines don't move when its turn comes")
    view.setNext([])
    precondition(view.entries.count == 7, "taking the next song's lines away")
    // a song ending on "♪" and the next opening with one: one "♪" line, which the next song starts on
    let closing = [LyricLine(id: 0, time: 0, text: "a"), LyricLine(id: 1, time: 10, text: "b"), LyricLine(id: 2, time: 20, text: "")]
    view.setLines(closing, width: 420); view.setNext(second)
    precondition(view.entries.count == 6 && view.entries[2].gap && view.entries[3].text == "second 0", "no two \"♪\" in a row while waiting")
    let gapToFirst = view.entries[3].y - view.entries[2].y
    view.setLines(second, width: 420, carryFrom: view.entry(at: 25, lines: closing))
    precondition(view.entries.count == 5 && view.entries[1].gap && view.entries[2].text == "second 0" && view.carriedCurrent == 1, "nor after the change")
    precondition(view.entry(at: 0, lines: second) == 1 && view.entry(at: 6, lines: second) == 2, "the new song starts on the shared \"♪\"")
    precondition(abs((view.entries[2].y - view.entries[1].y) - gapToFirst) < 0.001, "and its lines stay where they were")
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
    // each widget has its own size and transparency; 1.7 configs start every widget from the shared scale
    let old = try! JSONDecoder().decode(Settings.self, from: Data(#"{"scale":1.25,"widgets":[{"monitor":0,"position":"BottomLeft","customX":24,"customY":24,"customFromBottom":true},{"monitor":1,"position":"TopRight","customX":24,"customY":24,"customFromBottom":true}]}"#.utf8))
    precondition(old.widgets.allSatisfy { old.placed($0).scale == 1.25 && $0.opacity == 1 }, "1.7 widgets keep the shared size and stay opaque")
    var sized = old; sized.widgets[1].scale = 0.8; sized.widgets[1].transparency = 0.4
    let round = try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(sized))
    precondition(round.placed(round.widgets[0]).scale == 1.25 && round.placed(round.widgets[1]).scale == 0.8 && abs(round.widgets[1].opacity - 0.6) < 0.001, "per-widget size and transparency saved and read back")
    var faint = WidgetSetting(); faint.transparency = 5
    precondition(abs(faint.opacity - 0.2) < 0.001, "transparency is capped so a widget never disappears")
    precondition(old.savedWidgetIndex(monitor: 0, screenCount: 1) == 0 && old.savedWidgetIndex(monitor: 1, screenCount: 2) == 1, "menu choices find their widget")
    // a widget turned off keeps its settings, and comes back with them
    var off = round; off.widgets[1].hidden = true
    let offRound = try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off))
    precondition(offRound.shownWidgets(screenCount: 2).map(\.monitor) == [0] && offRound.widgets.count == 2 && offRound.placed(offRound.widgets[1]).scale == 0.8, "a widget turned off is kept, not shown")
    precondition(offRound.savedWidgetIndex(monitor: 0, screenCount: 2) == 0 && offRound.onWidgets.map(\.monitor) == [0], "menus reach the widgets that are on")
    var allOff = off; allOff.widgets[0].hidden = true
    precondition(try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(allOff)).shownWidgets(screenCount: 2).map(\.monitor) == [0], "at least one widget stays on")
    var away = old; away.widgets = [old.widgets[1]]
    precondition(away.savedWidgetIndex(monitor: 0, screenCount: 1) == 0, "the widget standing in on the main screen is the saved first one")
    print("PASS: dragged position (screen choice, top/bottom anchor, clamping), custom placement, new defaults, one widget per screen with its own position, size and transparency")
}

/// The browser source: which source is shown, and reading tabs, addresses and YouTube's answers.
@MainActor func browserSourceTests() {
    // the song shown is the one whose source started playing last
    let both = PearClient(loadRemoteAssets: false)
    both.handle(["type": "PLAYER_INFO", "isPlaying": true, "position": 10, "song": ["title": "pear song", "songDuration": 200, "videoId": "pearVideo01"]])
    precondition(both.source == .pear && both.song.title == "pear song")
    both.handle(["type": "VIDEO_CHANGED", "isPlaying": false, "position": 0, "song": ["title": "browser song", "songDuration": 180, "videoId": "browserVid1"]], from: .browser)
    precondition(both.source == .pear && both.song.title == "pear song", "a paused browser song doesn't take over a playing one")
    both.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": true, "position": 5], from: .browser)
    precondition(both.source == .browser && both.song.title == "browser song" && both.elapsed >= 5 && both.elapsed < 6, "the browser started playing")
    both.handle(["type": "POSITION_CHANGED", "position": 30])
    precondition(both.source == .browser && both.song.title == "browser song", "Pear playing on doesn't take it back")
    both.handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": false, "position": 6], from: .browser)
    precondition(both.source == .browser && both.song.paused)
    both.handle(["type": "POSITION_CHANGED", "position": 31])
    precondition(both.source == .pear && both.song.title == "pear song" && both.elapsed >= 31, "a playing source takes over from a paused one")
    both.handle(["type": "VIDEO_CHANGED", "isPlaying": true, "position": 0, "song": ["title": "browser next", "songDuration": 180, "videoId": "browserVid2"]], from: .browser)
    precondition(both.source == .browser && both.song.title == "browser next", "a new song playing takes over")
    both.stop()

    // addresses and tab titles
    precondition(BrowserSource.watchParameters("https://music.youtube.com/watch?v=qFeKKGDoF2E&list=OLAK5uy_k4cm") == ("qFeKKGDoF2E", "OLAK5uy_k4cm"))
    precondition(BrowserSource.watchParameters("https://music.youtube.com/watch?v=short").videoId.isEmpty)
    precondition(BrowserSource.watchParameters("https://music.youtube.com/playlist?list=OLAK5uy_k4cm").videoId.isEmpty)
    precondition(BrowserSource.watchParameters("https://www.youtube.com/watch?v=qFeKKGDoF2E").videoId.isEmpty, "YouTube Music tabs only")
    precondition(BrowserSource.tabSongTitle("アイドル - Idol | YouTube Music") == "アイドル - Idol" && BrowserSource.tabSongTitle("YouTube Music") == "")
    let tabs = [BrowserTabs.Tab(url: "https://music.youtube.com/", title: "YouTube Music"),
                BrowserTabs.Tab(url: "https://music.youtube.com/watch?v=ZRtdQ81jPUQ", title: "アイドル - Idol | YouTube Music"),
                BrowserTabs.Tab(url: "https://music.youtube.com/watch?v=8GfDq1osBLM&list=OLAK5uy_k4cm", title: "ハルジオン | YouTube Music")]
    precondition(BrowserSource.playingTab(tabs, title: "Idol")?.url.contains("ZRtdQ81jPUQ") == true, "the tab named like what macOS reports")
    precondition(BrowserSource.playingTab(tabs, title: "ハルジオン (Halzion)")?.url.contains("8GfDq1osBLM") == true, "a tab named with part of the title")
    precondition(BrowserSource.playingTab(tabs, title: "群青") == nil, "two video tabs, neither named like it")
    precondition(BrowserSource.playingTab(Array(tabs.prefix(2)), title: "something else")?.url.contains("ZRtdQ81jPUQ") == true, "the only video tab")
    precondition(BrowserSource.sameSong("Idol", title: "アイドル - Idol", tabTitle: "") && !BrowserSource.sameSong("ハルジオン (Halzion)", title: "Epilogue", tabTitle: ""))
    precondition(BrowserSource.mediaType("MUSIC_VIDEO_TYPE_ATV") == "AUDIO" && BrowserSource.mediaType("MUSIC_VIDEO_TYPE_OMV") == "ORIGINAL_MUSIC_VIDEO"
                 && BrowserSource.mediaType("MUSIC_VIDEO_TYPE_UGC") == "USER_GENERATED_CONTENT" && BrowserSource.mediaType("MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC") == "OTHER_VIDEO")
    // osascript's output: url<TAB>title lines; the separators are set outside the tell block ("tab" is Chrome's class there)
    precondition(BrowserTabs.parse("https://music.youtube.com/watch?v=ZRtdQ81jPUQ\tアイドル - Idol | YouTube Music\nhttps://music.youtube.com/\tYouTube Music\n")
                 == [BrowserTabs.Tab(url: "https://music.youtube.com/watch?v=ZRtdQ81jPUQ", title: "アイドル - Idol | YouTube Music"), BrowserTabs.Tab(url: "https://music.youtube.com/", title: "YouTube Music")])
    let script = BrowserTabs.script(for: "com.google.Chrome") ?? ""
    precondition(script.contains("set sep to character id 9") && script.contains("whose URL starts with \"https://music.youtube.com/\"") && !script.contains("& tab &"))
    precondition(BrowserTabs.script(for: "com.apple.Safari")?.contains("name of t") == true && BrowserTabs.script(for: "org.mozilla.firefox") == nil)

    // an album entry that is a music video names its official audio in its watch parameters (recorded 2026-10-20)
    precondition(YTMusicProvider.counterpart("OAHyAQIIAaIDC3FGZUtLR0RvRjJF") == "qFeKKGDoF2E" && YTMusicProvider.counterpart("OAHKAQRNVsw%3D") == nil)
    func entry(_ id: String, params: String = "", title: String = "", length: String = "") -> [String: Any] {
        ["playlistPanelVideoRenderer": ["videoId": id, "title": ["runs": [["text": title]]], "lengthText": ["runs": [["text": length]]],
                                        "navigationEndpoint": ["watchEndpoint": ["videoId": id, "params": params]]]]
    }
    let queue = YTMusicProvider.queueEntries(["contents": ["playlistPanelRenderer": ["contents": [
        entry("k_Z-mAvkCbM"), entry("vcGbefQBvJ4", params: "OAHyAQIIAaIDC3FGZUtLR0RvRjJF"),
        ["playlistPanelVideoWrapperRenderer": ["primaryRenderer": entry("kzdJkT4kp-A", title: "ハルジオン", length: "3:22")]],
        ["automixPreviewVideoRenderer": [:]]]]]])
    precondition(queue.map(\.videoId) == ["k_Z-mAvkCbM", "vcGbefQBvJ4", "kzdJkT4kp-A"] && queue[1].counterpartId == "qFeKKGDoF2E"
                 && queue[2].title == "ハルジオン" && queue[2].duration == 202, "queue order, counterparts, wrapped entries")
    precondition(YTMusicProvider.coverURL([["url": "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", "width": 60]]) == "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
    precondition(YTMusicProvider.coverURL([["url": "https://i.ytimg.com/vi/a/sd.jpg", "width": 400], ["url": "https://i.ytimg.com/vi/a/hq720.jpg", "width": 800]]) == "https://i.ytimg.com/vi/a/hq720.jpg")

    // YouTube's search for a song known by title only: the same length, and its own title or the artist's channel
    func result(_ id: String, _ title: String, _ owner: String, _ length: String, official: Bool = false) -> [String: Any] {
        ["videoRenderer": ["videoId": id, "title": ["runs": [["text": title]]], "ownerText": ["runs": [["text": owner]]], "lengthText": ["simpleText": length],
                           "ownerBadges": official ? [["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_VERIFIED_ARTIST"]]] : [] as [Any]]]
    }
    let search: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": [
        result("tyW4QFqUasU", "YOASOBI「ハルジオン」(Halzion) [日本語 | Romaji | Eng ] 歌詞", "YoshYoshYosh", "3:19"),
        result("Pv9BgqukAb4", "YOASOBI Halzion / ハルジオン Live Compilation", "YoAdoBy", "3:22"),
        result("kzdJkT4kp-A", "YOASOBI「ハルジオン」Official Music Video", "YOASOBI", "3:23"),
        result("M5FqUyIVaVo", "ドラマツルギー / Eve(covered by 犬山たまき)", "Tamaki Ch. 犬山たまき / 佃煮のりお", "4:02")]]]]]]]
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(search), title: "ハルジオン (Halzion)", artist: "YOASOBI", duration: 202) == "kzdJkT4kp-A",
                 "the artist's video of that length, not a fan upload of the same length")
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(search), title: "ドラマツルギー / Eve(covered by 犬山たまき)", artist: "Tamaki Ch. 犬山たまき / 佃煮のりお", duration: 242) == "M5FqUyIVaVo")
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(search), title: "ハルジオン (Halzion)", artist: "YOASOBI", duration: 230) == nil, "no video of that length")
    // the browser names the song and artist in the player's language (recorded 2026-10-20, "요아소비 Idol", hl=ko)
    let localized: [String: Any] = ["contents": ["sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": [
        result("mEZqJ65ra08", "🔥해외 차트 점령 중인 화제의 애니 OST : YOASOBI - 아이돌(アイドル)", "쏘플 soso playlist", "3:34"),
        result("IvMFMA89Yi8", "YOASOBI「アイドル」from『劇場版YOASOBI 5th ANNIVERSARY", "YOASOBI 및 Echoes", "5:36", official: true),
        result("ZRtdQ81jPUQ", "YOASOBI「アイドル」 Official Music Video", "YOASOBI 및 Echoes", "3:46", official: true),
        result("qxB7mbtu7Rw", "스타데이즈 Stardays", "스타데이즈 Stardays", "3:46")]]]]]]]
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(localized), title: "Idol", artist: "요아소비", duration: 226) == "ZRtdQ81jPUQ", "the one official video of that length")
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(localized), title: "アイドル - Idol", artist: "요아소비", duration: 226) == "ZRtdQ81jPUQ", "an official channel naming the song")
    precondition(YTMusicProvider.pickVideo(YTMusicProvider.searchHits(localized), title: "Idol", artist: "요아소비", duration: 230) == nil)
}

/// A cover's original from YouTube's search for the song's name (results recorded 2026-10-20, hl=ja).
@MainActor func coverSearchTests() {
    func hit(_ id: String, _ length: Double, _ official: Bool, _ owner: String, _ title: String) -> SearchHit {
        SearchHit(videoId: id, title: title, owner: owner, length: length, official: official)
    }
    let kimi = [hit("jpV5jeFlt_E", 356, true, "ryo (supercell)", "supercell - 君の知らない物語"),
                hit("rZZzlY8vUf8", 90, false, "アニプレックス チャンネル", "『君の知らない物語』supercell｜『化物語』ノンクレジットED映像"),
                hit("caF6nJxTejc", 338, false, "high_note Music Lounge", "君の知らない物語 - supercell"),
                hit("46CUBRHdZA4", 347, true, "AZKi Channel", "【SorAZ】君の知らない物語 / AZKi ときのそら【歌ってみた】")]
    let enel = Song(title: "君の知らない物語 歌ってみた；【Enel】", artist: "Enel ;", videoId: "XMomcatLNAI", mediaType: "USER_GENERATED_CONTENT", duration: 338)
    precondition(CoverLyrics.pickOriginal(kimi, songName: "君の知らない物語", cover: enel)?.videoId == "jpV5jeFlt_E",
                 "the official video (18 s longer: an intro), not a reupload of the right length or another cover")
    let propose = [hit("VDdLF1YubI0", 179, true, "なとり / natori", "なとり - プロポーズ"),
                   hit("XPLkkdMFmco", 234, true, "9Lana", "【MV】プロポーズ/ 9Lana cover"),
                   hit("ST_AJmY_Tcc", 234, true, "内緒のピアス", "プロポーズ / 可不"),
                   hit("zdPtgoB_B0I", 234, true, "そらる / soraru", "プロポーズ -cover / そらる")]
    let lana = Song(title: "プロポーズ - propose", artist: "9Lana", videoId: "XPLkkdMFmco", mediaType: "ORIGINAL_MUSIC_VIDEO", duration: 234)
    precondition(CoverLyrics.pickOriginal(propose, songName: "プロポーズ", cover: lana)?.videoId == "ST_AJmY_Tcc", "two songs of that name: the one of the cover's length")
    let melancholic = [hit("86_kvUqhY-A", 220, true, "Junky // Clover lab.", "メランコリック / Junky feat.鏡音リン"),
                       hit("HvzaOKUzjk4", 222, true, "Meychan", "メランコリック Cover / めいちゃん"),
                       hit("TBVecP6BWPA", 220, true, "MORE MORE JUMP! - Topic", "メランコリック (feat. 花里みのり & 桐谷遥 & 桃井愛莉 & 日野森雫 &...")]
    let mey = Song(title: "メランコリック Cover / めいちゃん", artist: "Meychan", videoId: "HvzaOKUzjk4", mediaType: "ORIGINAL_MUSIC_VIDEO", duration: 222)
    precondition(CoverLyrics.pickOriginal(melancholic, songName: "メランコリック", cover: mey) == nil, "two artists of that length: no guess")
    precondition(CoverLyrics.pickOriginal(Array(melancholic.prefix(2)), songName: "メランコリック", cover: mey)?.videoId == "86_kvUqhY-A", "the singer's own upload doesn't count")
    precondition(CoverLyrics.pickOriginal(kimi, songName: "君", cover: enel) == nil, "a one-letter name is no evidence")
    print("PASS: a cover's original from YouTube's search (official channel, one artist, not a cover)")
}
