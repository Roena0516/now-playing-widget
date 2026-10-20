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
    let updater = Updater()
    var update: UpdateInfo?         // a newer release found on GitHub
    var announcedUpdate = ""        // told the user about this version already
    var installing = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.migrate()
        Log.info("start \(appVersion)\(Log.buildStamp)")
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
            DispatchQueue.main.async {
                guard let self else { return }
                let identity = self.client.song.identity
                if identity != self.lastIdentity { self.lastIdentity = identity; if !self.client.song.title.isEmpty { self.overlay.show() } }
                else { self.overlay.playStateChanged() }
                self.updateMenu()
            }
        }.store(in: &subscriptions)
        client.$lines.sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.overlay.refresh() } }.store(in: &subscriptions)
        client.$nextLines.sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.refresh() } }.store(in: &subscriptions)
        client.$titleRevision.sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.refresh() } }.store(in: &subscriptions)
        client.$artwork.sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.refresh() } }.store(in: &subscriptions)
        registerHotkeys()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.overlay.rebuildWidgets(); self?.updateMenu() } }
        updateMenu()
        if preview {
            client.handle(["type": "PLAYER_INFO", "isPlaying": true, "song": ["title": "Pear Now Playing · macOS", "artist": "오버레이 미리보기", "album": "한국어 · 日本語 · English", "songDuration": 240, "elapsedSeconds": 42, "isPaused": false]])
            client.lines = parseLRC("[00:00.00]음악과 함께하는 시간\n[00:40.00]macOS에서도 만나는 싱크 가사\n[00:46.00]クリックを通すオーバーレイ\n[00:52.00]Your music, always nearby")
            overlay.show(temporary: false)
        } else { client.start(); overlay.show(); startUpdateChecks() }
    }

    // GitHub's latest release is checked 30 s after start and then daily ("checkUpdates"); installing happens
    // only when the user picks it from the menu, never mid-game on its own. Same as the Windows version.
    func startUpdateChecks() {
        Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if client.settings.checkUpdates { await checkForUpdate(manual: false) }
                try? await Task.sleep(for: .seconds(86400))
            }
        }
    }

    func checkForUpdate(manual: Bool) async {
        do {
            let found = try await updater.check()
            update = found; updateMenu()
            if let found {
                Log.info("update available: \(found.version) (\(found.assetName))")
                if manual || found.version != announcedUpdate {
                    announcedUpdate = found.version
                    overlay.showInfo("새 버전 \(found.version)이 나왔습니다. 메뉴에서 업데이트할 수 있습니다")
                }
            } else if manual { overlay.showInfo("최신 버전입니다 (\(appVersion))") }
        } catch {
            Log.write("INFO update check failed: \(error.localizedDescription)")
            if manual { overlay.showInfo("업데이트를 확인하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오") }
        }
    }

    @objc func updateClicked() {
        guard let target = update else {
            overlay.showInfo("업데이트를 확인하고 있습니다")
            Task { await checkForUpdate(manual: true) }
            return
        }
        guard !installing else { return }
        installing = true
        overlay.showInfo("업데이트를 받고 있습니다 (\(target.version))")
        Task {
            var dmg: URL?
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PearNowPlaying-update-\(target.version)")
                dmg = try await updater.download(target, into: dir)
                let app = Bundle.main.bundleURL, id = Bundle.main.bundleIdentifier ?? "", file = dmg!
                try await Task.detached { try Updater.install(dmg: file, version: target.version, into: app, bundleId: id) }.value
                Log.info("updated to \(target.version), restarting")
                Updater.relaunch(app)
            } catch {
                // e.g. no permission to replace the app (another user's install, run from the DMG): install by hand
                Log.write("WARN update to \(target.version) failed: \(error.localizedDescription)")
                installing = false
                overlay.showInfo(dmg != nil ? "업데이트하지 못했습니다. 받은 파일을 엽니다" : "업데이트하지 못했습니다. 릴리스 페이지를 엽니다")
                if let dmg { NSWorkspace.shared.open(dmg) } else if let page = URL(string: target.pageURL) { NSWorkspace.shared.open(page) }
            }
        }
    }
    func registerFonts() { NativeTheme.registerFonts() }
    var lastIdentity = ""

    /// Hotkeys from the config (Windows format, "Ctrl+Alt+Up"); unregistered ones are reported like on Windows.
    func registerHotkeys() {
        hotkeys.unregisterAll()
        let s = client.settings
        let errors = [
            hotkeys.register(s.hotkeyShow) { [weak self] in self?.show() },
            hotkeys.register(s.hotkeyToggle) { [weak self] in self?.client.control("toggle-play") },
            hotkeys.register(s.hotkeyNext) { [weak self] in self?.client.control("next") },
            hotkeys.register(s.hotkeyPrevious) { [weak self] in self?.client.control("previous") },
            hotkeys.register(s.hotkeyAlwaysShow) { [weak self] in self?.togglePinned() },
            hotkeys.register(s.hotkeyLyrics) { [weak self] in self?.toggleLyrics() },
        ].compactMap { $0 }
        if !errors.isEmpty {
            Log.write("WARN hotkeys not registered: " + errors.joined(separator: ", "))
            overlay?.showInfo("단축키를 등록하지 못했습니다: " + errors.joined(separator: ", "))
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("exit"); overlay?.stop(); setupTask?.cancel(); client.stop(); hotkeys.unregister(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, state: Bool = false, represented: Any? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self
        entry.state = state ? .on : .off; entry.representedObject = represented; menu.addItem(entry)
    }
    func updateMenu() {
        guard item != nil else { return }
        let menu = NSMenu()
        // at the top, so a new version ("업데이트 설치 (x.y.z)") is seen first (like the Windows version)
        add(menu, update.map { "업데이트 설치 (\($0.version))" } ?? "업데이트 확인", #selector(updateClicked))
        menu.addItem(.separator())
        add(menu, preview ? "미리보기 모드" : client.status, nil)
        add(menu, client.lyricsStatus, nil)
        menu.addItem(.separator())
        add(menu, "지금 곡 보기", #selector(show))
        menu.addItem(.separator())
        add(menu, "이전 곡", #selector(previous))
        add(menu, "재생 / 일시정지", #selector(togglePlay))
        add(menu, "다음 곡", #selector(next))
        menu.addItem(.separator())

        // widget (song card, where and how big) and lyrics settings live in separate submenus
        let widget = NSMenu()
        add(widget, "곡 정보 계속 표시", #selector(togglePinned), state: client.settings.alwaysShow)
        let titles = NSMenu()
        add(titles, "곡 제목", #selector(videoTitle(_:)), state: client.settings.videoTitle != "video", represented: "song")
        add(titles, "영상 제목", #selector(videoTitle(_:)), state: client.settings.videoTitle == "video", represented: "video")
        submenu(widget, "영상 곡 제목", titles)
        // like the Windows version: 표시 picks the screens with a widget; 위치 / 크기 / 투명도 are set per widget, one
        // submenu per screen with a widget, or the choices directly when there is one widget
        let screens = NSScreen.screens
        func screenTitle(_ index: Int) -> String {
            guard index < screens.count else { return "모니터 \(index + 1)" }
            let size = screens[index].frame.size
            return "모니터 \(index + 1) (\(index == 0 ? "주 모니터, " : "")\(Int(size.width))×\(Int(size.height)))"
        }
        // 표시: which screens have a widget (only with several screens)
        if screens.count > 1 {
            let display = NSMenu()
            for index in screens.indices {
                let on = client.settings.onWidgets.contains { $0.monitor == index }
                let entry = NSMenuItem(title: screenTitle(index), action: !on || client.settings.onWidgets.count > 1 ? #selector(toggleMonitor(_:)) : nil, keyEquivalent: "")
                entry.target = self; entry.state = on ? .on : .off; entry.representedObject = index
                display.addItem(entry)   // the last widget can't be turned off (no action = greyed out)
            }
            submenu(widget, "표시", display)
        }
        let shown = client.settings.shownWidgets(screenCount: screens.count)
        /// Each shown widget's items: one submenu per screen, or the items directly for a single widget.
        func perWidget(_ title: String, _ fill: (NSMenu, WidgetSetting) -> Void) {
            let menu = NSMenu()
            for w in shown {
                let target = shown.count == 1 ? menu : NSMenu()
                fill(target, w)
                if shown.count > 1 { let entry = NSMenuItem(title: screenTitle(w.monitor), action: nil, keyEquivalent: ""); entry.submenu = target; menu.addItem(entry) }
            }
            submenu(widget, title, menu)
        }
        perWidget("위치") { menu, w in
            for (value, label) in [("TopLeft", "왼쪽 위"), ("TopCenter", "가운데 위"), ("TopRight", "오른쪽 위"), ("BottomLeft", "왼쪽 아래"), ("BottomCenter", "가운데 아래"), ("BottomRight", "오른쪽 아래"), ("Custom", "직접 옮긴 위치")] {
                if value == "Custom" { menu.addItem(.separator()) }
                add(menu, label, #selector(widgetPosition(_:)), state: w.position == value, represented: "\(w.monitor)|\(value)")
            }
        }
        func choices(_ list: [(Double, String)], _ action: Selector, _ value: @escaping (WidgetSetting) -> Double) -> (NSMenu, WidgetSetting) -> Void {
            { [unowned self] menu, w in for (v, label) in list { self.add(menu, label, action, state: abs(value(w) - v) < 0.01, represented: "\(w.monitor)|\(v)") } }
        }
        let settings = client.settings
        perWidget("크기", choices([(0.8, "작게"), (1.0, "보통"), (1.25, "크게"), (1.5, "아주 크게")], #selector(size(_:))) { settings.placed($0).scale })
        perWidget("투명도", choices([(0, "없음"), (0.2, "20%"), (0.4, "40%"), (0.6, "60%")], #selector(transparency(_:))) { $0.transparency ?? 0 })
        widget.addItem(.separator())
        add(widget, "위젯 끌어서 옮기기", #selector(toggleMoveMode), state: overlay?.moveMode ?? false)
        submenu(menu, "위젯", widget)

        let lyrics = NSMenu()
        add(lyrics, "가사 표시", #selector(toggleLyrics), state: client.settings.showLyrics)
        add(lyrics, "앨범 곡만 가사 표시", #selector(toggleAlbumOnly), state: client.settings.lyricsAlbumOnly)
        add(lyrics, "가사 다시 찾기", #selector(findLyrics))
        let timing = NSMenu()
        for (title, value) in [("1초 빠르게", 1300), ("0.5초 빠르게", 800), ("기본", 300), ("0.5초 늦게", -200), ("1초 늦게", -700)] {
            add(timing, title, #selector(offset(_:)), state: Int(client.settings.lyricsOffsetMs) == value, represented: value)
        }
        submenu(lyrics, "가사 타이밍", timing)
        submenu(menu, "가사", lyrics)
        let sources = NSMenu()
        for (value, label) in [("auto", "자동 (브라우저, Pear Desktop)"), ("browser", "브라우저"), ("pear", "Pear Desktop")] {
            add(sources, label, #selector(songSource(_:)), state: client.settings.source == value, represented: value)
        }
        submenu(menu, "재생 앱", sources)
        menu.addItem(.separator())
        if client.settings.source != "browser" { add(menu, "Pear 연결 권한 다시 요청", #selector(retry)) }
        add(menu, "설정 파일 열기", #selector(openConfig))
        add(menu, "설정 다시 불러오기", #selector(reload))
        add(menu, "오류 기록 열기", #selector(openLog))
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
    @objc func toggleAlbumOnly() {
        client.settings.lyricsAlbumOnly.toggle(); client.settings.save(); updateMenu()
        overlay.showInfo(client.settings.lyricsAlbumOnly ? "앨범 곡에서만 가사를 표시합니다" : "모든 곡에서 가사를 표시합니다")
        client.findLyrics()   // decide again for the current song
    }
    @objc func toggleLyrics() {
        client.settings.showLyrics.toggle(); client.settings.save(); updateMenu()
        // the same messages as the Windows version's ToggleLyrics
        if !client.settings.showLyrics { overlay.refresh(); overlay.showInfo("가사 표시를 껐습니다"); return }
        overlay.refresh()
        if client.lyricsFailed { overlay.showInfo("가사 서버에 연결하지 못했습니다"); return }
        guard let outcome = client.lyricsOutcome else { return }   // still looking
        if case .synced = outcome { return }
        overlay.showInfo("이 곡의 싱크 가사를 찾지 못했습니다")
    }
    @objc func findLyrics() { client.findLyrics(force: true) }
    @objc func videoTitle(_ sender: NSMenuItem) { client.settings.videoTitle = sender.representedObject as! String; save() }
    @objc func toggleMoveMode() { overlay.setMoveMode(!overlay.moveMode); updateMenu() }
    @objc func toggleMonitor(_ sender: NSMenuItem) {
        let index = sender.representedObject as! Int
        if let found = client.settings.widgets.firstIndex(where: { $0.monitor == index }) {
            if client.settings.widgets[found].isOn {
                guard client.settings.onWidgets.count > 1 else { return }
                client.settings.widgets[found].hidden = true   // kept: turning it on again brings its settings back
            } else {
                client.settings.widgets[found].hidden = nil
            }
        } else {
            // a new widget starts where the first one is (as a preset or the same dragged offsets)
            var widget = client.settings.onWidgets.first ?? WidgetSetting(); widget.monitor = index
            client.settings.widgets.append(widget); client.settings.widgets.sort { $0.monitor < $1.monitor }
        }
        client.settings.save(); overlay.rebuildWidgets(); overlay.show(); updateMenu()
    }
    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: Log.file.path) { Log.info("log opened") }
        NSWorkspace.shared.open(Log.file)
    }
    @objc func widgetPosition(_ sender: NSMenuItem) {
        let parts = (sender.representedObject as! String).split(separator: "|").map(String.init)
        guard let monitor = Int(parts[0]), let index = client.settings.savedWidgetIndex(monitor: monitor, screenCount: NSScreen.screens.count) else { return }
        client.settings.widgets[index].position = parts[1]
        client.settings.save(); overlay.rebuildWidgets(); overlay.show(); updateMenu()
    }
    /// "monitor|value" from the 크기 / 투명도 menus: change that widget and lay the widgets out again.
    private func setWidget(_ sender: NSMenuItem, _ change: (inout WidgetSetting, Double) -> Void) {
        let parts = (sender.representedObject as! String).split(separator: "|").map(String.init)
        guard let monitor = Int(parts[0]), let value = Double(parts[1]),
              let index = client.settings.savedWidgetIndex(monitor: monitor, screenCount: NSScreen.screens.count) else { return }
        change(&client.settings.widgets[index], value)
        client.settings.save(); overlay.rebuildWidgets(); overlay.show(); updateMenu()
    }
    @objc func size(_ sender: NSMenuItem) { setWidget(sender) { $0.scale = $1 } }
    @objc func transparency(_ sender: NSMenuItem) { setWidget(sender) { $0.transparency = $1 } }
    @objc func offset(_ sender: NSMenuItem) { client.settings.lyricsOffsetMs = Double(sender.representedObject as! Int); save() }
    @objc func songSource(_ sender: NSMenuItem) {
        let value = sender.representedObject as! String
        guard client.settings.source != value else { return }
        client.settings.source = value; client.settings.save(); client.start(); updateMenu()
        overlay.showInfo(value == "browser" ? "브라우저에서 재생하는 YouTube Music을 표시합니다" : value == "pear" ? "Pear Desktop에서 재생하는 곡을 표시합니다" : "브라우저와 Pear Desktop 중에서 재생 중인 곡을 표시합니다")
    }
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
                Log.error("player setup", error)
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
            guard running.terminate() else { throw NSError(domain: "PlayerSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "음악 앱을 종료할 수 없습니다. 직접 종료한 뒤에 다시 실행해 주십시오."]) }
            for _ in 0..<50 {
                if running.isTerminated { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard running.isTerminated else { throw NSError(domain: "PlayerSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "음악 앱이 아직 종료되지 않았습니다. 직접 종료한 뒤에 다시 실행해 주십시오."]) }
        }
        // Some versions save in-memory preferences on quit; reapply after termination.
        _ = try PlayerSetup.apply(to: PlayerSetup.configURL(), port: client.settings.port)
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func openConfig() { NSWorkspace.shared.open(Settings.file) }
    @objc func reload() { client.reload(); registerHotkeys(); overlay.rebuildWidgets(); overlay.show(); updateMenu() }
    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
// test and audit runs log to a scratch file, not the user's error.log
if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") && $0 != "--preview" }) {
    Log.file = FileManager.default.temporaryDirectory.appendingPathComponent("pear-now-playing-test-\(ProcessInfo.processInfo.processIdentifier).log")
}
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
} else if let index = CommandLine.arguments.firstIndex(of: "--update-test"), CommandLine.arguments.count > index + 2 {
    // the whole update against a given releases URL, installing into the given app instead of this one
    let target = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task {
        let updater = Updater(); updater.apiURL = URL(string: CommandLine.arguments[index + 1])!
        let plist = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) ?? [:]
        do {
            guard let info = try await updater.check(current: plist["CFBundleShortVersionString"] as? String ?? "0") else { print("UP TO DATE"); exit(0) }
            let dmg = try await updater.download(info, into: FileManager.default.temporaryDirectory.appendingPathComponent("pnp-update-test-\(UUID().uuidString)"))
            try Updater.install(dmg: dmg, version: info.version, into: target, bundleId: plist["CFBundleIdentifier"] as? String ?? "")
            print("UPDATED to \(info.version)"); exit(0)
        } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--browser-probe") {
    // what the browser source sends, for a number of seconds (default 60): for trying it against a real browser
    let seconds = Double(CommandLine.arguments.dropFirst(index + 1).first ?? "") ?? 60
    Log.echo = true
    let ytm = YTMusicProvider(log: { print($0) })
    let source = BrowserSource(ytm: ytm)
    func line(_ text: String) { print(ISO8601DateFormatter().string(from: Date()), text); fflush(stdout) }
    source.onMessage = { message in
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        line(String(decoding: data, as: UTF8.self))
    }
    source.onBrowser = { line("browser: \($0 ?? "none")") }
    source.onNotice = { line("notice: \($0)") }
    source.start()
    let forward = source.reader.onInfo
    source.reader.onInfo = { info in
        let app = NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier ?? "?"
        line("now playing: \(app) \(info.playing ? "playing" : "paused") \(Int(info.position(at: Date())))/\(Int(info.duration)) \(info.artist) - \(info.title)")
        forward?(info)
    }
    Task {
        try? await Task.sleep(for: .seconds(15))
        line("playing \(source.videoId) in \(source.playlist.isEmpty ? "no playlist" : source.playlist)")
        if !source.playlist.isEmpty, let entries = try? await ytm.playlistEntries(source.videoId, playlist: source.playlist) {
            for e in entries { line("  entry \(e.videoId) / \(e.counterpartId) \(e.title)") }
        }
        do {
            if let next = try await source.nextSong() { line("next: \(next.videoId) \(next.artist) - \(next.title) [\(next.mediaType)]") } else { line("next: none") }
        } catch { line("next: failed: \(error)") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { source.stop(); exit(0) }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--lookup"), CommandLine.arguments.count > index + 1 {
    // the whole lyrics lookup for one video, as the browser source would hand it over (no caches), with the log
    let id = CommandLine.arguments[index + 1]
    Log.echo = true
    let ytm = YTMusicProvider(log: Log.write)
    let finder = LyricsFinder(lrclib: LyricsProvider(log: Log.write), ytm: ytm, more: MoreLyrics(log: Log.write), disk: nil, log: Log.write)
    Task {
        do {
            let track = try await ytm.lookup(id, withLyrics: false)
            let song = Song(title: track.title, artist: track.artist, videoId: id, mediaType: BrowserSource.mediaType(track.videoType), duration: track.duration)
            switch try await finder.find(song) {
            case .synced(let lines, let source): print("RESULT synced \(lines.count) lines from \(source); first: \(lines.first(where: { $0.text != "♪" })?.text ?? "")")
            case .instrumental: print("RESULT instrumental")
            case .plainOnly: print("RESULT plain only")
            case .notFound: print("RESULT not found")
            }
            exit(0)
        } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
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
