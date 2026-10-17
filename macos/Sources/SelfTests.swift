import Foundation

@MainActor func runSelfTests() {
    let lyrics = parseLRC("[offset:200]\n[00:01.00][00:03.50]안녕 日本語\n[00:02.00]\n[ar:ignored]\n[bad]ignored")
    precondition(lyrics.count == 3 && lyrics[0].text == "안녕 日本語" && abs(lyrics[0].time - 1.2) < 0.001)
    precondition(lyrics[1].text == "♪" && abs(lyrics[2].time - 3.7) < 0.001)
    precondition(activeLyric(lyrics, at: 0) == nil && activeLyric(lyrics, at: 2.5) == 1 && activeLyric(lyrics, at: 100) == 2)
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
    precondition(socketRequest.url?.query == nil)
    testPlayerSetup()
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
        print("PASS: expired-token reconnect, POST auth, WebSocket song/state/seek, bearer controls, token permissions")
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
