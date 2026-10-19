import Foundation
import Combine

@MainActor final class PearClient: ObservableObject {
    @Published var song = Song()
    // status lines, worded as the Windows version's tray (TrayApp.StatusText and the lyrics line)
    static let starting = "연결 준비 중", waiting = "Pear Desktop 기다리는 중 (API 서버 확인)",
               authorizing = "Pear Desktop에서 허용 대기 중", denied = "Pear Desktop에서 연결 거부됨", connected = "Pear Desktop에 연결됨"
    @Published var status = PearClient.starting
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
    private var anchor = Date()
    private var token: String?
    let lyrics = LyricsFinder(lrclib: LyricsProvider(log: Log.write), ytm: YTMusicProvider(log: Log.write),
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
        lyrics.ytm.proxyBase = settings.ytmLyricsProxy
        lyrics.lrclib.baseURL = settings.lyricsServer
    }
    private var tokenFile: URL { directory.appendingPathComponent("token.txt") }
    var elapsed: Double { min(max(0, song.elapsed + (song.paused ? 0 : Date().timeIntervalSince(anchor))), max(0, song.duration)) }
    var baseURL: URL { URL(string: "http://\(settings.host):\(settings.port)")! }
    func start() {
        connection?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        connection = Task { await run() }
    }
    func retryAuth() { token = nil; try? FileManager.default.removeItem(at: tokenFile); start() }
    func stop() { connection?.cancel(); lyricTask?.cancel(); prefetchTask?.cancel(); artTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }
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

    private func run() async {
        token = try? String(contentsOf: tokenFile, encoding: .utf8)
        while !Task.isCancelled {
            var closeInfo = ""
            do {
                if token == nil {
                    var req = URLRequest(url: baseURL.appendingPathComponent("auth/pear-now-playing-macos"))
                    req.httpMethod = "POST"; req.httpBody = Data()
                    // A refused connection fails at once. If Pear holds the request open, it is showing its
                    // allow/deny dialog, and only then do we tell the user to click "허용".
                    let dialogHint = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        if !Task.isCancelled { status = PearClient.authorizing; onLyricsNotice?("Pear Desktop에서 '허용'을 눌러주세요") }
                    }
                    defer { dialogHint.cancel() }
                    let (data, response) = try await session.data(for: req)
                    dialogHint.cancel()
                    try Task.checkCancellation()
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 403 {
                        status = PearClient.denied; Log.info("auth denied by Pear (403)")
                        onLyricsNotice?("Pear Desktop에서 연결이 거부됐어요. 메뉴의 'Pear 연결 권한 다시 요청'으로 다시 시도할 수 있어요.")
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
                            let firstMessage = status != PearClient.connected
                            if firstMessage { Log.info("connected to Pear at \(baseURL.absoluteString)"); lastFailure = "" }
                            status = PearClient.connected; handle(obj)
                            if firstMessage && !everConnected {
                                everConnected = true
                                if song.title.isEmpty { onLyricsNotice?("Pear Desktop에 연결됐어요") }
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
                    }
                    throw error
                }
            } catch {
                if Task.isCancelled { return }
                let e = error as NSError
                noteFailure("WARN Pear connection failed: \(e.domain) \(e.code) \(e.localizedDescription)\(closeInfo)")
                status = PearClient.waiting
                if !song.paused { song.elapsed = elapsed; song.paused = true; anchor = Date() }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
    func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        switch type {
        case "PLAYER_INFO", "VIDEO_CHANGED":
            let previous = song.identity
            if let value = message["song"] as? [String: Any] { song = Song(value) }
            if let value = message["isPlaying"] as? Bool { song.paused = !value }
            if let value = message["position"] as? NSNumber { song.elapsed = value.doubleValue }
            anchor = Date()
            if song.identity != previous && loadRemoteAssets { fetchArtwork(); findLyrics() }
        case "PLAYER_STATE_CHANGED":
            song.elapsed = elapsed
            song.paused = !(message["isPlaying"] as? Bool ?? false)
            if let value = message["position"] as? NSNumber { song.elapsed = value.doubleValue }
            anchor = Date()
        case "POSITION_CHANGED":
            let position = (message["position"] as? NSNumber)?.doubleValue ?? song.elapsed
            // When a song ends Pear reports position 0 about 0.3s before VIDEO_CHANGED names the next song, so for a
            // moment the old song looks rewound (its lyrics scrolled back to the top). Not only in its last seconds:
            // the length Pear gives can be off, or songs overlap (crossfade). VIDEO_CHANGED brings the position itself;
            // a seek to the start or a repeated song gets it from the next tick. Same as src/PearClient.cs.
            if Self.isJumpToStart(position, last: elapsed) { break }
            song.elapsed = position; anchor = Date()
        default: break
        }
    }
    /// Back to 0 from well into the song: most likely the next song starting, so it waits a tick.
    nonisolated static func isJumpToStart(_ position: Double, last: Double) -> Bool {
        position < 1 && last >= 10
    }
    func control(_ action: String) {
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
        if !force, !track.title.isEmpty, wantsLyrics(track), let known = lyrics.known(track) { apply(known, for: track, force: false); return }
        lines = []; lyricsStatus = "가사: 찾는 중"; lyricsOutcome = nil; lyricsFailed = false
        guard !track.title.isEmpty else { lyricsStatus = "가사: -"; if force { onLyricsNotice?("재생 중인 곡이 없어요") }; return }
        if !wantsLyrics(track) {
            // "앨범 곡만 가사 표시": not an album track, so no lookup at all
            lyricsStatus = "가사: 앨범 곡이 아니라 찾지 않음"
            if force { onLyricsNotice?("앨범 곡이 아니라 가사를 표시하지 않아요") }
            prefetchNext(after: track)
            return
        }
        if force { lyrics.forget(track); lyrics.ytm.resetPause(); onLyricsNotice?("가사를 다시 찾는 중이에요") }
        lyricTask = Task {
            // LRCLIB is sometimes slow or briefly down: retry a few times while the same song plays
            let delays = LyricsProvider.lookupRetryDelays
            for (attempt, delay) in delays.enumerated() {
                do {
                    if delay > 0 {
                        lyricsStatus = "가사: 연결 실패, 다시 시도 중 (\(attempt)/\(delays.count - 1))"
                        try await Task.sleep(for: .seconds(delay))
                    }
                    let result = try await lyrics.find(track)
                    try Task.checkCancellation()
                    guard song.identity == track.identity else { return }
                    apply(result, for: track, force: force)
                    return
                } catch {
                    if Task.isCancelled { return }
                    Log.write("WARN lyrics lookup failed (\(attempt + 1)/\(delays.count)) for \(track.artist) - \(track.title): \(error.localizedDescription)")
                }
            }
            guard song.identity == track.identity else { return }
            lyricsStatus = "가사: 가사 서버에 연결하지 못함"; lyricsFailed = true
            if force { onLyricsNotice?("가사 서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요") }
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
        case .instrumental: return "연주곡이에요"
        case .plainOnly, .notFound: return "이 곡은 싱크 가사를 찾지 못했어요"
        }
    }
}
