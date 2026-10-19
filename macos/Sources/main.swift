import AppKit
import Combine
import CoreText

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = PearClient()
    let hotkeys = Hotkeys()
    var overlay: OverlayController!
    var item: NSStatusItem!
    var subscriptions = Set<AnyCancellable>()
    var screenObserver: NSObjectProtocol?
    var setupTask: Task<Void, Never>?
    let preview = CommandLine.arguments.contains("--preview")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerFonts()
        client.settings.save()
        overlay = OverlayController(client: client, preview: preview)
        client.onLyricsNotice = { [weak self] message in
            guard let self else { return }
            if let message { self.overlay.showInfo(message) } else { self.overlay.show() }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NativeTheme.trayIcon()
        item.button?.setAccessibilityLabel("Pear Now Playing")
        client.$status.combineLatest(client.$lyricsStatus).sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateMenu(); self?.overlay?.refresh() } }.store(in: &subscriptions)
        client.$song.map { $0.identity + "|" + String($0.paused) }.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; if !self.client.song.title.isEmpty { self.overlay.show() }; self.updateMenu() }
        }.store(in: &subscriptions)
        client.$lines.sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.overlay.refresh() } }.store(in: &subscriptions)
        client.$titleRevision.sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.refresh() } }.store(in: &subscriptions)
        client.$artwork.sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.refresh() } }.store(in: &subscriptions)
        hotkeys.action = { [weak self] id in
            guard let self else { return }
            switch id { case 0: self.show(); case 1: self.client.control("toggle-play"); case 2: self.client.control("next"); case 3: self.client.control("previous"); case 4: self.togglePinned(); case 5: self.toggleLyrics(); default: break }
        }
        if !hotkeys.register() { NSLog("일부 단축키 등록 실패: 다른 앱의 Ctrl+Option 단축키를 확인하세요.") }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.overlay.layout(); self?.updateMenu() } }
        updateMenu()
        if preview {
            client.handle(["type": "PLAYER_INFO", "isPlaying": true, "song": ["title": "Pear Now Playing · macOS", "artist": "오버레이 미리보기", "album": "한국어 · 日本語 · English", "songDuration": 240, "elapsedSeconds": 42, "isPaused": false]])
            client.lines = parseLRC("[00:00.00]음악과 함께하는 시간\n[00:40.00]macOS에서도 만나는 싱크 가사\n[00:46.00]クリックを通すオーバーレイ\n[00:52.00]Your music, always nearby")
            overlay.show(temporary: false)
        } else { client.start(); overlay.show() }
    }
    func registerFonts() { NativeTheme.registerFonts() }
    func applicationWillTerminate(_ notification: Notification) { overlay?.stop(); setupTask?.cancel(); client.stop(); hotkeys.unregister(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, state: Bool = false, represented: Any? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self
        entry.state = state ? .on : .off; entry.representedObject = represented; menu.addItem(entry)
    }
    func updateMenu() {
        guard item != nil else { return }
        let menu = NSMenu()
        add(menu, preview ? "미리보기 모드" : client.status, nil)
        add(menu, client.lyricsStatus, nil)
        menu.addItem(.separator())
        add(menu, "지금 곡 다시 보기    ⌃⌥↑", #selector(show))
        menu.addItem(.separator())
        add(menu, "이전 곡    ⌃⌥←", #selector(previous))
        add(menu, "재생 / 일시정지    ⌃⌥↓", #selector(togglePlay))
        add(menu, "다음 곡    ⌃⌥→", #selector(next))
        menu.addItem(.separator())

        // widget (song card, where and how big) and lyrics settings live in separate submenus
        let widget = NSMenu()
        add(widget, "곡 정보 계속 표시    ⌃⌥P", #selector(togglePinned), state: client.settings.alwaysShow)
        let position = NSMenu()
        for (value, label) in [("TopLeft", "왼쪽 위"), ("TopCenter", "가운데 위"), ("TopRight", "오른쪽 위"), ("BottomLeft", "왼쪽 아래"), ("BottomCenter", "가운데 아래"), ("BottomRight", "오른쪽 아래")] {
            add(position, label, #selector(position(_:)), state: client.settings.position == value, represented: value)
        }
        position.addItem(.separator())
        add(position, "직접 옮긴 위치", #selector(position(_:)), state: client.settings.position == "Custom", represented: "Custom")
        submenu(widget, "위치", position)
        let monitors = NSMenu()
        let current = min(max(0, client.settings.monitor), max(0, NSScreen.screens.count - 1))
        for (index, screen) in NSScreen.screens.enumerated() {
            let size = screen.frame.size
            add(monitors, "모니터 \(index + 1) · \(screen.localizedName)\(index == 0 ? " (주 모니터)" : "") \(Int(size.width))×\(Int(size.height))",
                #selector(monitor(_:)), state: index == current, represented: index)
        }
        submenu(widget, "모니터", monitors)
        let sizes = NSMenu(); for (scale, label) in [(0.8, "작게"), (1.0, "보통"), (1.25, "크게"), (1.5, "아주 크게")] { add(sizes, label, #selector(size(_:)), state: client.settings.scale == scale, represented: scale) }
        submenu(widget, "크기", sizes)
        widget.addItem(.separator())
        add(widget, "위젯 끌어서 옮기기", #selector(toggleMoveMode), state: overlay?.moveMode ?? false)
        submenu(menu, "위젯", widget)

        let lyrics = NSMenu()
        add(lyrics, "가사 표시    ⌃⌥L", #selector(toggleLyrics), state: client.settings.showLyrics)
        add(lyrics, "가사 다시 찾기", #selector(findLyrics))
        let timing = NSMenu(); for delta in [-1000, -500, -100, 0, 100, 500, 1000] {
            let title = delta == 0 ? "보정 초기화" : (delta > 0 ? "\(delta)ms 빠르게" : "\(-delta)ms 늦게")
            add(timing, title, #selector(offset(_:)), represented: delta)
        }
        submenu(lyrics, "가사 타이밍 (\(Int(client.settings.lyricsOffsetMs))ms)", timing)
        add(lyrics, "가사 진단 기록 열기", #selector(openLyricsLog))
        submenu(menu, "가사", lyrics)
        menu.addItem(.separator())
        add(menu, "Pear 연결 권한 다시 요청", #selector(retry))
        add(menu, "YouTube Music 열기", #selector(openPlayer))
        add(menu, "설정 파일 열기", #selector(openConfig))
        add(menu, "설정 다시 불러오기", #selector(reload))
        menu.addItem(.separator())
        add(menu, "종료", #selector(quit))
        item.menu = menu
        item.button?.toolTip = client.status
    }
    func submenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = sub; menu.addItem(entry)
    }
    func save() { client.settings.save(); client.applyLyricsSources(); overlay.show(); updateMenu() }
    @objc func show() { overlay.show() }
    @objc func togglePinned() { client.settings.alwaysShow.toggle(); save() }
    @objc func toggleLyrics() { client.settings.showLyrics.toggle(); save() }
    @objc func findLyrics() { client.findLyrics(force: true) }
    @objc func toggleMoveMode() { overlay.setMoveMode(!overlay.moveMode); updateMenu() }
    @objc func monitor(_ sender: NSMenuItem) { client.settings.monitor = sender.representedObject as! Int; save() }
    @objc func openLyricsLog() { LyricsLog.write("진단 기록 열기"); NSWorkspace.shared.open(LyricsLog.file) }
    @objc func position(_ sender: NSMenuItem) { client.settings.position = sender.representedObject as! String; save() }
    @objc func size(_ sender: NSMenuItem) { client.settings.scale = sender.representedObject as! Double; save() }
    @objc func offset(_ sender: NSMenuItem) { let delta = sender.representedObject as! Int; client.settings.lyricsOffsetMs = delta == 0 ? 0 : client.settings.lyricsOffsetMs + Double(delta); save() }
    @objc func previous() { client.control("previous") }
    @objc func togglePlay() { client.control("toggle-play") }
    @objc func next() { client.control("next") }
    @objc func retry() {
        guard setupTask == nil else { return }
        setupTask = Task {
            defer { setupTask = nil }
            do {
                let configURL = try PlayerSetup.configURL()
                let result = try PlayerSetup.apply(to: configURL, port: client.settings.port)
                client.retryAuth()
                // Give the running player a chance to observe the external config change.
                for _ in 0..<8 {
                    if await apiAvailable() { return }
                    try await Task.sleep(for: .milliseconds(500))
                }
                let alert = NSAlert()
                alert.messageText = result.changed ? "API 서버 설정을 저장했습니다" : "음악 앱의 API 서버가 응답하지 않습니다"
                alert.informativeText = "설정을 반영하려면 YouTube Music/Pear Desktop을 다시 시작해야 합니다. 재생 중인 음악이 잠시 멈춥니다."
                alert.addButton(withTitle: "음악 앱 다시 시작")
                alert.addButton(withTitle: "나중에")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    try await restartPlayer()
                    client.retryAuth()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Pear 연결 설정을 적용하지 못했습니다"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
    func apiAvailable() async -> Bool {
        var request = URLRequest(url: client.baseURL.appendingPathComponent("api/v1/song"))
        request.timeoutInterval = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), let response = response as? HTTPURLResponse else { return false }
        return [200, 401, 403].contains(response.statusCode)
    }
    func restartPlayer() async throws {
        let names = ["YouTube Music", "Pear Desktop", "Pear Desktop Music", "pear-desktop"]
        let running = NSWorkspace.shared.runningApplications.first { names.contains($0.localizedName ?? "") }
        let candidates = ["/Applications/YouTube Music.app", "/Applications/Pear Desktop.app", NSHomeDirectory() + "/Applications/YouTube Music.app", NSHomeDirectory() + "/Applications/Pear Desktop.app"]
        guard let url = running?.bundleURL ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else { throw PlayerSetup.SetupError.configNotFound }
        if let running {
            guard running.terminate() else { throw NSError(domain: "PlayerSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "음악 앱을 종료할 수 없습니다. 직접 종료 후 다시 실행해 주세요."]) }
            for _ in 0..<50 {
                if running.isTerminated { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard running.isTerminated else { throw NSError(domain: "PlayerSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "음악 앱이 아직 종료되지 않았습니다. 직접 종료 후 다시 실행해 주세요."]) }
        }
        // Some versions save in-memory preferences on quit; reapply after termination.
        _ = try PlayerSetup.apply(to: PlayerSetup.configURL(), port: client.settings.port)
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func openPlayer() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/YouTube Music.app")) }
    @objc func openConfig() { NSWorkspace.shared.open(Settings.file) }
    @objc func reload() { client.reload(); overlay.show(); updateMenu() }
    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
if CommandLine.arguments.contains("--ytmusic-tests") {
    Task { await runYTMusicTests() }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--audit-ytmusic"), CommandLine.arguments.count > index + 1 {
    do { try auditYTMusic(CommandLine.arguments[index + 1]) }
    catch { fputs("YTMusic audit failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--lyrics-tests") {
    Task { await runLyricsTests() }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--audit-lyrics"), CommandLine.arguments.count > index + 2 {
    do { try auditLyricCandidates(songFile: CommandLine.arguments[index + 1], resultsFile: CommandLine.arguments[index + 2]) }
    catch { fputs("Lyrics audit failed: \(error)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    do { try renderNativePreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--integration-test") {
    Task { await runIntegrationTest() }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

}
