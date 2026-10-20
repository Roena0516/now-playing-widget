import Foundation
import Combine

/// Where songs come from: Pear Desktop's API server, or YouTube Music in a web browser (BrowserSource).
enum SongSource { case pear, browser }

/// One source's player: its song, and when its position was last set.
struct PlayerState {
    var song = Song()
    var anchor = Date()
    var jumps = BackwardJumps()
    var elapsed: Double { min(max(0, song.elapsed + (song.paused ? 0 : Date().timeIntervalSince(anchor))), max(0, song.duration)) }

    /// One message in Pear's WebSocket format (the browser source speaks it too).
    mutating func apply(_ message: [String: Any]) {
        switch message["type"] as? String ?? "" {
        case "PLAYER_INFO", "VIDEO_CHANGED":
            if let value = message["song"] as? [String: Any] { song = Song(value) }
            if let value = message["isPlaying"] as? Bool { song.paused = !value }
            if let value = message["position"] as? NSNumber { song.elapsed = value.doubleValue }
            anchor = Date()
            jumps.reset()
        case "PLAYER_STATE_CHANGED":
            jumps.reset()
            song.elapsed = elapsed
            song.paused = !(message["isPlaying"] as? Bool ?? false)
            if let value = message["position"] as? NSNumber { song.elapsed = value.doubleValue }
            anchor = Date()
        case "POSITION_CHANGED":
            let position = (message["position"] as? NSNumber)?.doubleValue ?? song.elapsed
            if !jumps.accept(position, last: elapsed, now: Date()) { break }
            song.elapsed = position; anchor = Date()
        default: break
        }
    }
    mutating func pause() { if !song.paused { song.elapsed = elapsed; song.paused = true; anchor = Date() } }
}

@MainActor final class PearClient: ObservableObject {
    @Published var song = Song()
    // status lines, worded as the Windows version's tray (TrayApp.StatusText and the lyrics line)
    static let starting = "연결 준비 중", waiting = "Pear Desktop 기다리는 중 (API 서버 확인)",
               authorizing = "Pear Desktop에서 허용 대기 중", denied = "Pear Desktop에서 연결 거부됨", connected = "Pear Desktop에 연결됨",
               waitingAny = "YouTube Music 기다리는 중 (브라우저, Pear Desktop)", waitingBrowser = "브라우저의 YouTube Music 기다리는 중",
               notLinked = "Pear Desktop 연결 안 됨 (메뉴에서 연결 요청)",
               browserPrefix = "브라우저 YouTube Music에 연결됨"
    static func browserConnected(_ name: String) -> String { browserPrefix + " (\(name))" }
    @Published var status = PearClient.starting
    /// Pear's connection state (one of the lines above); `status` is this or the browser's.
    private var pearStatus = PearClient.starting { didSet { updateStatus() } }
    /// The source of the song shown: the one that started playing last.
    @Published private(set) var source = SongSource.pear
    private var players: [SongSource: PlayerState] = [.pear: PlayerState(), .browser: PlayerState()]
    private(set) lazy var browser = BrowserSource(ytm: lyrics.ytm)
    let discord = DiscordPresence()
    private var browserRunning = false
    @Published var lines: [LyricLine] = []
    /// The next song's lyrics (fetched ahead), shown below this song's last line.
    @Published var nextLines: [LyricLine] = []
    @Published var lyricsStatus = "가사: -"
    /// How the last lyrics lookup ended (nil while looking), for the "가사 표시" toggle's message.
    private(set) var lyricsOutcome: LyricsLookup?
    private(set) var lyricsFailed = false
    private var everConnected = false
    @Published var artwork: Data?
    /// Bumped when an album track's display title becomes known (see cardTitle).
    @Published var titleRevision = 0
    /// Show a message card (nil = show the song card), like the Windows version's ShowInfo.
    var onLyricsNotice: ((String?) -> Void)?
    @Published var settings = Settings.load()
    private var connection: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var token: String?
    let lyrics = LyricsFinder(lrclib: LyricsProvider(log: Log.write), ytm: YTMusicProvider(log: Log.write), more: MoreLyrics(log: Log.write),
                              disk: LyricsDiskCache(log: Log.write), log: Log.write)
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 180
        return URLSession(configuration: cfg)
    }()
    private let directory: URL
    private let loadRemoteAssets: Bool
    init(directory: URL = Settings.directory, loadRemoteAssets: Bool = true) {
        self.directory = directory; self.loadRemoteAssets = loadRemoteAssets
        applyLyricsSources()
    }
    func applyLyricsSources() {
        lyrics.useYtm = settings.ytmLyrics
        lyrics.useMore = settings.moreLyrics
        lyrics.ytm.proxyBase = settings.ytmLyricsProxy
        lyrics.lrclib.baseURL = settings.lyricsServer
    }
    private var tokenFile: URL { directory.appendingPathComponent("token.txt") }
    var elapsed: Double { players[source]?.elapsed ?? 0 }
    var baseURL: URL { URL(string: "http://\(settings.host):\(settings.port)")! }
    /// Whether a player is connected (the card says "재생 중인 곡이 없습니다" then, not the connection state).
    var isConnected: Bool { status == PearClient.connected || status.hasPrefix(PearClient.browserPrefix) }
    func start() {
        connection?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        pearStatus = PearClient.starting
        if settings.source != "browser" {
            connection = Task { await run() }
            pearSilenceWatch?.cancel()
            pearSilenceWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.checkPearSilence()
                }
            }
        }
        else { players[.pear]!.pause(); if source == .pear { show() } }
        if settings.source != "pear" { startBrowser() } else { stopBrowser() }
        updateStatus()
        syncDiscord()
    }
    private func startBrowser() {
        guard !browserRunning, loadRemoteAssets else { return }
        browserRunning = true
        browser.onMessage = { [weak self] message in self?.handle(message, from: .browser) }
        browser.onBrowser = { [weak self] _ in self?.updateStatus() }
        browser.onNotice = { [weak self] text in self?.onLyricsNotice?(text) }
        browser.start()
    }
    private func stopBrowser() {
        guard browserRunning else { return }
        browserRunning = false; browser.stop()
        players[.browser]!.pause()
        if source == .browser { show() }
    }
    /// The status line: the browser while its song is shown (or Pear isn't connected), else Pear's state.
    private func updateStatus() {
        let next: String
        if browserRunning, let name = browser.browser, source == .browser || pearStatus != PearClient.connected { next = PearClient.browserConnected(name) }
        else if settings.source == "browser" { next = PearClient.waitingBrowser }
        else if settings.source == "auto" && pearStatus == PearClient.waiting { next = PearClient.waitingAny }
        else if settings.source == "auto" && pearStatus == PearClient.notLinked { next = PearClient.waitingBrowser }
        else { next = pearStatus }
        if status != next { status = next }
    }
    /// "Pear Desktop 연결 요청": ask Pear for a token now (Pear shows its allow dialog the first time).
    func retryAuth() { token = nil; try? FileManager.default.removeItem(at: tokenFile); linkRequested = true; start() }
    /// Pear is asked for a token only when the user picks "Pear Desktop 연결 요청", or when a token Pear gave before
    /// was rejected (it expired): never on its own at first start, so Pear's allow dialog doesn't pop up for users of
    /// the browser alone, and nothing is asked again and again while Pear isn't there.
    private var linkRequested = false
    func stop() { discord.show(nil); pearSilenceWatch?.cancel(); connection?.cancel(); lyricTask?.cancel(); prefetchTask?.cancel(); artTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil); stopBrowser() }
    func reload() { settings = Settings.load(); settings.save(); applyLyricsSources(); start() }
    private func persistToken(_ value: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(value.utf8).write(to: tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
    }
    /// The last connection problem written to the log: a stopped Pear is retried every 3 seconds, so the same
    /// failure is logged once, and again only when it changes or after the connection worked.
    private var lastFailure = ""
    private func noteFailure(_ text: String) { if text != lastFailure { lastFailure = text; Log.write(text) } }

    /// Whether Pear's API server answers at all (any HTTP status will do).
    func apiReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/song"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    private func run() async {
        token = try? String(contentsOf: tokenFile, encoding: .utf8)
        while !Task.isCancelled {
            var closeInfo = ""
            do {
                if token == nil {
                    guard linkRequested else { pearStatus = PearClient.notLinked; return }
                    linkRequested = false
                    // Pear not there (not running, or its API server plugin off): say so once instead of waiting on it
                    guard await apiReachable() else {
                        Log.info("Pear link requested, but its API server doesn't answer at \(baseURL.absoluteString)")
                        pearStatus = PearClient.notLinked
                        onLyricsNotice?("Pear Desktop에 연결하지 못했습니다. Pear Desktop이 실행 중이고 API 서버 플러그인이 켜져 있는지 확인해 주십시오")
                        return
                    }
                    // the name Pear shows in its allow dialog; kept from the app's old name so updating doesn't ask again
                    var req = URLRequest(url: baseURL.appendingPathComponent("auth/pear-now-playing-macos"))
                    req.httpMethod = "POST"; req.httpBody = Data()
                    // A refused connection fails at once. If Pear holds the request open, it is showing its
                    // allow/deny dialog, and only then do we tell the user to click "허용".
                    let dialogHint = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        if !Task.isCancelled { pearStatus = PearClient.authorizing; onLyricsNotice?("Pear Desktop에서 '허용'을 눌러 주십시오") }
                    }
                    defer { dialogHint.cancel() }
                    let (data, response) = try await session.data(for: req)
                    dialogHint.cancel()
                    try Task.checkCancellation()
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 403 {
                        pearStatus = PearClient.denied; Log.info("auth denied by Pear (403)")
                        onLyricsNotice?("Pear Desktop에서 연결이 거부되었습니다. 메뉴의 'Pear Desktop 연결 요청'으로 다시 시도할 수 있습니다.")
                        return
                    }
                    guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = obj["accessToken"] as? String, !value.isEmpty else {
                        noteFailure("WARN Pear auth returned \(code)")
                        throw URLError(.badServerResponse)
                    }
                    token = value; try persistToken(value)
                    Log.info("got a token from Pear")
                }
                var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/ws"), resolvingAgainstBaseURL: false)!
                components.scheme = "ws"
                let request = makeWebSocketRequest(url: components.url!, token: token)
                let ws = session.webSocketTask(with: request); socket = ws; ws.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        try Task.checkCancellation()
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let firstMessage = pearStatus != PearClient.connected
                            if firstMessage { Log.info("connected to Pear at \(baseURL.absoluteString)"); lastFailure = "" }
                            pearStatus = PearClient.connected; handle(obj)
                            if firstMessage && !everConnected {
                                everConnected = true
                                if song.title.isEmpty && source == .pear { onLyricsNotice?("Pear Desktop에 연결되었습니다") }
                            }
                        }
                    }
                } catch {
                    let http = (ws.response as? HTTPURLResponse)?.statusCode ?? 0
                    if ws.closeCode != .invalid {
                        closeInfo = ", closed with \(ws.closeCode.rawValue)" + (ws.closeReason.flatMap { String(data: $0, encoding: .utf8) }.map { " " + $0 } ?? "")
                    }
                    if http != 0 && http != 101 { closeInfo += ", HTTP \(http)" }
                    if ws.closeCode == .policyViolation || http == 401 {
                        Log.info("token rejected by Pear\(closeInfo), requesting a new one")
                        token = nil; try? FileManager.default.removeItem(at: tokenFile)
                        linkRequested = true   // linked before: a new token is asked for at once
                    }
                    throw error
                }
            } catch {
                if Task.isCancelled { return }
                let e = error as NSError
                noteFailure("WARN Pear connection failed: \(e.domain) \(e.code) \(e.localizedDescription)\(closeInfo)")
                pearStatus = PearClient.waiting
                players[.pear]!.pause()
                if source == .pear { show() }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
    /// A message from Pear (or, in the same format, from the browser source). The song shown is the source's that
    /// started playing last: a source that starts playing (or plays a new song) takes over, and one that plays
    /// takes over from a paused one.
    func handle(_ message: [String: Any], from origin: SongSource = .pear) {
        if origin == .pear && notePearMessage(message) { return }
        var state = players[origin]!
        let wasPlaying = !state.song.paused, before = state.song.identity
        state.apply(message)
        players[origin] = state
        let current = players[source]!
        let started = !state.song.paused && (!wasPlaying || state.song.identity != before)
        if origin != source, !state.song.title.isEmpty, started || current.song.title.isEmpty || (current.song.paused && !state.song.paused) {
            Log.info(origin == .browser ? "showing the song playing in \(browser.browser ?? "the browser")" : "showing the song playing in Pear")
            source = origin
            updateStatus()
        }
        if origin == source { show() }
        syncDiscord()
    }

    /// Discord's "Listening to": the song shown while it plays (from the browser or Pear Desktop; with Pear's own
    /// Discord plugin on too, Discord gets two and picks one), nothing otherwise. DiscordPresence sends only real changes (a new song, play / pause, a
    /// seek), so this runs on every message. Same as TrayApp.SyncDiscord in src/TrayApp.cs.
    func syncDiscord() {
        guard loadRemoteAssets, settings.discordPresence, !song.title.isEmpty, !song.paused, song.duration > 0 else {
            discord.show(nil); return
        }
        let start = Date().addingTimeInterval(-elapsed)
        discord.show(DiscordPresence.Activity(title: cardTitle, artist: song.artist, album: song.album, imageURL: song.imageSrc, videoId: song.videoId,
                                              start: start, end: start.addingTimeInterval(song.duration), button: settings.discordButton))
    }
    // Pear 3.12.0 sends no PLAYER_STATE_CHANGED when the song is paused or played again, and its own song info keeps
    // saying it plays (isPaused stays false, also in PLAYER_INFO and /api/v1/song; seen 2026-10-20). It does stop
    // sending the position every second while paused, so that silence is taken for a pause, and a position coming
    // after it for playing again. A Pear that does send the state is followed as before.
    private var pearLastTick = Date.distantPast
    private var pearPauseGuessed = false
    private var pearSilenceWatch: Task<Void, Never>?
    static let pearSilence: TimeInterval = 2.5

    /// Bookkeeping for each Pear message; true when it was handled here (a position resuming a guessed pause).
    private func notePearMessage(_ message: [String: Any]) -> Bool {
        switch message["type"] as? String ?? "" {
        case "PLAYER_STATE_CHANGED": pearPauseGuessed = false
        case "PLAYER_INFO", "VIDEO_CHANGED": pearLastTick = Date(); pearPauseGuessed = false
        case "POSITION_CHANGED":
            pearLastTick = Date()
            if pearPauseGuessed && players[.pear]!.song.paused {
                pearPauseGuessed = false
                handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": true, "position": message["position"] ?? players[.pear]!.song.elapsed])
                return true
            }
        default: break
        }
        return false
    }

    /// Pear's song plays but no position came for a while: paused at the last position Pear sent.
    func checkPearSilence(now: Date = Date()) {
        let pear = players[.pear]!
        guard !pear.song.paused, !pear.song.title.isEmpty, pearLastTick != .distantPast, now.timeIntervalSince(pearLastTick) > Self.pearSilence else { return }
        handle(["type": "PLAYER_STATE_CHANGED", "isPlaying": false, "position": pear.song.elapsed])
        pearPauseGuessed = true
    }

    /// The shown source's song; a new one gets its cover and lyrics.
    private func show() {
        let previous = song.identity
        song = players[source]!.song
        if song.identity != previous && loadRemoteAssets { fetchArtwork(); findLyrics() }
    }
    func control(_ action: String) {
        if source == .browser && browserRunning { browser.control(action); return }
        Task {
            do {
                var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/\(action)"))
                req.httpMethod = "POST"; req.httpBody = Data()
                if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (_, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 { Log.info("control \(action): token rejected (401), requesting a new one"); retryAuth() }
                else if !(200...299).contains(code) { Log.info("control \(action) returned \(code)") }
            } catch { Log.error("control \(action)", error) }
        }
    }
    private func fetchArtwork() {
        artTask?.cancel(); artwork = nil
        guard let url = URL(string: song.imageSrc), url.scheme == "https" else { return }
        let identity = song.identity
        artTask = Task {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { Log.info("album art returned \((response as? HTTPURLResponse)?.statusCode ?? 0)"); return }
                if !Task.isCancelled, song.identity == identity { artwork = data }
            } catch { if !Task.isCancelled { Log.error("album art", error) } }
        }
    }
    func findLyrics(force: Bool = false) {
        lyricTask?.cancel(); prefetchTask?.cancel()
        nextLines = []
        let track = song
        // already known (fetched ahead, cached): swap the lyrics in place, so the lyrics card doesn't close and
        // reopen (which made the song card drop down and come back up)
        if !force, !track.title.isEmpty, wantsLyrics(track), let known = lyrics.known(track) {
            apply(known, for: track, force: false)
            // found on Kugou / NetEase: LRCLIB was busy then, or may have the song by now
            if lyrics.shouldRecheck(track, known) { lookUp(track, force: false, shown: known) }
            return
        }
        lines = []; lyricsStatus = "가사: 찾는 중"; lyricsOutcome = nil; lyricsFailed = false
        guard !track.title.isEmpty else { lyricsStatus = "가사: -"; if force { onLyricsNotice?("재생 중인 곡이 없습니다") }; return }
        if !wantsLyrics(track) {
            // "앨범 곡만 가사 표시": not an album track, so no lookup at all
            lyricsStatus = "가사: 앨범 곡이 아니라 찾지 않음"
            if force { onLyricsNotice?("앨범 곡이 아니어서 가사를 표시하지 않습니다") }
            prefetchNext(after: track)
            return
        }
        if force { lyrics.forget(track); lyrics.ytm.resetPause(); lyrics.more?.resetPause(); onLyricsNotice?("가사를 다시 찾고 있습니다") }
        lookUp(track, force: force, shown: nil)
    }

    /// Look up the song's lyrics, and while it plays retry when LRCLIB was busy (or unreachable). Lyrics found on
    /// Kugou / NetEase are shown at once when LRCLIB should be asked again (it was busy, or it may have the song by
    /// now: shouldRecheck), and LRCLIB alone is asked: its lyrics replace them, its "none" keeps them.
    /// `shown`: Kugou / NetEase lyrics already on screen to ask LRCLIB about at once.
    private func lookUp(_ track: Song, force: Bool, shown: LyricsLookup?) {
        lyricTask = Task {
            // LRCLIB is sometimes busy or briefly down: keep asking while the same song plays, as often as its
            // Retry-After allows (up to 10 minutes, e.g. while paused)
            let until = Date().addingTimeInterval(LyricsProvider.lookupRetryFor)
            var shown = shown
            var attempt = 0
            while attempt == 0 || Date() < until {
                defer { attempt += 1 }
                do {
                    if attempt > 0 {
                        if shown == nil { lyricsStatus = "가사: 연결 실패, 다시 시도 중 (\(attempt))" }
                        try await Task.sleep(for: .seconds(lyrics.lrclib.retryWait))
                    }
                    if let before = shown {
                        guard let result = try await lyrics.recheck(track) else { continue }   // LRCLIB still busy
                        try Task.checkCancellation()
                        guard song.identity == track.identity else { return }
                        // LRCLIB has none: the lyrics shown stay (no need to lay them out again)
                        if case .synced(let a, _) = before, case .synced(let b, _) = result, a == b { return }
                        apply(result, for: track, force: false)
                        return
                    }
                    let result = try await lyrics.find(track)
                    try Task.checkCancellation()
                    guard song.identity == track.identity else { return }
                    if lyrics.shouldRecheck(track, result) {
                        // a stand-in for a busy LRCLIB: shown now, LRCLIB asked again later
                        Log.info("LRCLIB busy: showing \(result.sourceName) lyrics meanwhile, asking LRCLIB again later")
                        apply(result, for: track, force: force)
                        shown = result
                        continue
                    }
                    apply(result, for: track, force: force)
                    return
                } catch {
                    if Task.isCancelled { return }
                    Log.write("WARN lyrics lookup failed (\(attempt + 1)) for \(track.artist) - \(track.title): \(error.localizedDescription)")
                }
            }
            guard shown == nil else { return }   // LRCLIB still busy: keep the stand-in
            guard song.identity == track.identity else { return }
            lyricsStatus = "가사: 가사 서버에 연결하지 못함"; lyricsFailed = true
            if force { onLyricsNotice?("가사 서버에 연결하지 못했습니다. 잠시 뒤에 다시 시도해 주십시오") }
        }
    }

    /// A lookup's result for the current song: lines, status line, look-ahead and title.
    private func apply(_ result: LyricsLookup, for track: Song, force: Bool) {
        lyricsOutcome = result; lyricsFailed = false
        switch result {
        case .synced(let found, let source): lines = found; lyricsStatus = "가사: 싱크 가사 있음 (\(source))"
        case .instrumental: lines = []; lyricsStatus = "가사: 연주곡"
        case .plainOnly, .notFound: lines = []; lyricsStatus = "가사: 찾지 못함"
        }
        if force { onLyricsNotice?(LyricsNotice.message(for: result)) }
        prefetchNext(after: track)
        updateDisplayTitle(track)
    }

    /// Whether this song's lyrics are wanted ("앨범 곡만 가사 표시" skips everything but album tracks).
    func wantsLyrics(_ track: Song) -> Bool { !settings.lyricsAlbumOnly || track.mediaType == "AUDIO" }

    /// While this song plays, look up the next one in Pear's queue so its lyrics are ready when it starts.
    /// Waits a little first so quickly skipped songs don't trigger lookups. LRCLIB's "busy" answers usually clear
    /// within seconds, so a failed look-ahead is tried again later in the song instead of when the next one starts.
    private func prefetchNext(after current: Song) {
        guard settings.showLyrics, loadRemoteAssets else { return }
        prefetchTask?.cancel()
        prefetchTask = Task {
            for wait in Self.prefetchWaits {
                do {
                    try await Task.sleep(for: .seconds(wait))
                    // asked each time: the queue may have changed
                    guard var next = try await nextSong(), next.videoId + "|" + next.title != current.videoId + "|" + current.title else { return }
                    if settings.lyricsAlbumOnly {
                        // the queue doesn't say whether it's an album track; YouTube Music does (this is the
                        // lookup's first request anyway, remembered for when the song starts)
                        guard settings.ytmLyrics, !lyrics.ytm.paused,
                              try await lyrics.ytm.lookup(next.videoId).videoType == "MUSIC_VIDEO_TYPE_ATV" else { return }
                        next.mediaType = "AUDIO"
                    }
                    try await lyrics.prefetch(next)
                    if !Task.isCancelled, case .synced(let found, _)? = lyrics.ahead(next) { nextLines = found }
                    return
                } catch {
                    if Task.isCancelled { return }
                    Log.write("INFO fetching ahead failed (\(error.localizedDescription)), will try again while this song plays")
                }
            }
        }
    }
    static var prefetchWaits: [Double] = [10, 30, 90]

    /// The title the card shows: an album track whose title Pear gives only as a translation is shown as
    /// "original - translation" (see CoverLyrics.displayTitle), once YouTube Music's queue entry is known.
    var cardTitle: String {
        // videos (MVs, covers, uploads): the song title, or the video's own title if the user prefers it
        if song.mediaType != "AUDIO" {
            return settings.videoTitle == "video" && !song.alternativeTitle.trimmed.isEmpty ? song.alternativeTitle : song.title
        }
        guard let track = lyrics.ytm.known(song.videoId) else { return song.title }
        return CoverLyrics.displayTitle(song.title, queueTitle: track.title)
    }

    /// After the lyrics lookup: its YouTube Music answer carries the queue title, so show it. If the lyrics came
    /// from a cache without asking YouTube Music, or the relay was paused, ask for the title alone (once per video
    /// and session). The title comes from music.youtube.com itself, not the relay, so the pause doesn't apply.
    private func updateDisplayTitle(_ track: Song) {
        guard track.mediaType == "AUDIO", !track.videoId.isEmpty else { return }
        if lyrics.ytm.known(track.videoId) != nil { titleRevision += 1; return }
        guard settings.ytmLyrics else { return }
        Task {
            do { _ = try await lyrics.ytm.lookup(track.videoId, withLyrics: false) }
            catch { if !Task.isCancelled { Log.write("INFO title lookup failed for \(track.videoId): \(error.localizedDescription)") }; return }
            if song.videoId == track.videoId { titleRevision += 1 }
        }
    }

    /// The next song in Pear's queue (GET /api/v1/queue/next): title, artist, video ID and length only.
    /// Nil when there is no next song or Pear can't be asked.
    func nextSong() async throws -> Song? {
        if source == .browser { return try await browser.nextSong() }
        guard let token else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/queue/next"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,   // 204 = nothing queued
              let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func firstRun(_ key: String) -> String {
            if let simple = YTMusicProvider.path(d[key], "simpleText") as? String { return simple }
            for run in YTMusicProvider.path(d[key], "runs") as? [Any] ?? [] {
                if let t = YTMusicProvider.path(run, "text") as? String, !t.trimmed.isEmpty { return t.trimmed }
            }
            return ""
        }
        // the queue doesn't say the media type; cover detection goes by the title only
        let next = Song(title: d["title"] as? String ?? "", artist: firstRun("shortBylineText"), videoId: d["videoId"] as? String ?? "",
                        mediaType: "UNKNOWN", duration: YTMusicProvider.parseClock(firstRun("lengthText")))
        return next.videoId.isEmpty || next.title.isEmpty ? nil : next
    }

}

// Pear versions differ in where they look for the WebSocket token: some check a bearer header on the
// HTTP upgrade (Hono JWT middleware), others (3.12) only the `token` query parameter and close the socket
// with 1008 otherwise. Send both, as the Windows version sends the query parameter.
func makeWebSocketRequest(url: URL, token: String?) -> URLRequest {
    guard let token else { return URLRequest(url: url) }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
    var request = URLRequest(url: components.url ?? url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
}

enum LyricsNotice {
    static func message(for result: LyricsLookup) -> String? {
        switch result {
        case .synced: return nil
        case .instrumental: return "연주곡입니다"
        case .plainOnly, .notFound: return "이 곡의 싱크 가사를 찾지 못했습니다"
        }
    }
}

/// When a song ends Pear reports a position for the old song just before VIDEO_CHANGED names the next one: usually
/// 0 (about 0.3-0.7s before), sometimes first another value (2026-10-20: 115 after 190, the next song being 114s
/// long). Taken as is, the old song looks rewound: its lyrics scroll back, then the next song's start. So a position
/// that goes back is held for a tick and applied only when the next one carries on from it (a seek back, a song on
/// repeat); VIDEO_CHANGED brings the new song's position itself. Same as PositionFilter in src/PearClient.cs.
struct BackwardJumps {
    private var held: (position: Double, at: Date)?
    mutating func reset() { held = nil }
    /// Whether to apply this position now. `last`: the position shown so far.
    mutating func accept(_ position: Double, last: Double, now: Date) -> Bool {
        if position >= last - 2 { held = nil; return true }   // playing on, or a seek forward
        if let held, position >= held.position - 0.5, position <= held.position + now.timeIntervalSince(held.at) + 2 {
            self.held = nil; return true
        }
        held = (position, now)
        return false
    }
}
