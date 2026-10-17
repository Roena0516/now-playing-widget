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
