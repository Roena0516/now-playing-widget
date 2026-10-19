import Foundation
import Combine

@MainActor final class PearClient: ObservableObject {
    @Published var song = Song()
    @Published var status = "Pear Desktop 기다리는 중"
    @Published var lines: [LyricLine] = []
    @Published var lyricsStatus = "가사 대기 중"
    @Published var artwork: Data?
    /// Bumped when an album track's display title becomes known (see cardTitle).
    @Published var titleRevision = 0
    var onLyricsNotice: ((String?) -> Void)?
    @Published var settings = Settings.load()
    private var connection: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var anchor = Date()
    private var token: String?
    let lyrics = LyricsFinder(lrclib: LyricsProvider(log: LyricsLog.write), ytm: YTMusicProvider(log: LyricsLog.write),
                              disk: LyricsDiskCache(log: LyricsLog.write), log: LyricsLog.write)
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
    private func run() async {
        token = try? String(contentsOf: tokenFile, encoding: .utf8)
        while !Task.isCancelled {
            do {
                if token == nil {
                    status = "연결 시도 중 · Pear의 권한 창을 허용해 주세요"
                    var req = URLRequest(url: baseURL.appendingPathComponent("auth/pear-now-playing-macos"))
                    req.httpMethod = "POST"; req.httpBody = Data()
                    let (data, response) = try await session.data(for: req)
                    try Task.checkCancellation()
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 403 { status = "권한 거부됨 · 메뉴에서 연결 권한 다시 요청"; return }
                    guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = obj["accessToken"] as? String, !value.isEmpty else { throw URLError(.badServerResponse) }
                    token = value; try persistToken(value)
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
                        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] { status = "Pear Desktop 연결됨"; handle(obj) }
                    }
                } catch {
                    if ws.closeCode == .policyViolation || (ws.response as? HTTPURLResponse)?.statusCode == 401 { token = nil; try? FileManager.default.removeItem(at: tokenFile) }
                    throw error
                }
            } catch {
                if Task.isCancelled { return }
                status = "Pear 연결 실패 · 서버/연결 권한 확인 (\((error as NSError).code))"
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
            song.elapsed = (message["position"] as? NSNumber)?.doubleValue ?? song.elapsed; anchor = Date()
        default: break
        }
    }
    func control(_ action: String) {
        Task {
            do {
                var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/\(action)"))
                req.httpMethod = "POST"; req.httpBody = Data()
                if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (_, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 { retryAuth() }
                else if !(200...299).contains(code) { status = "재생 제어 실패 (\(code))" }
            } catch { status = "재생 제어 연결 실패" }
        }
    }
    private func fetchArtwork() {
        artTask?.cancel(); artwork = nil
        guard let url = URL(string: song.imageSrc), url.scheme == "https" else { return }
        let identity = song.identity
        artTask = Task {
            if let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled, song.identity == identity { artwork = data }
        }
    }
    func findLyrics(force: Bool = false) {
        lyricTask?.cancel(); prefetchTask?.cancel(); lines = []; lyricsStatus = "가사 검색 중"
        let track = song
        guard !track.title.isEmpty else { lyricsStatus = "가사 대기 중"; if force { onLyricsNotice?("재생 중인 곡이 없어요") }; return }
        if force { lyrics.forget(track); lyrics.ytm.resetPause(); onLyricsNotice?("가사를 다시 찾는 중이에요") }
        lyricTask = Task {
            // LRCLIB is sometimes slow or briefly down: retry a few times while the same song plays
            let delays = LyricsProvider.lookupRetryDelays
            for (attempt, delay) in delays.enumerated() {
                do {
                    if delay > 0 {
                        lyricsStatus = "가사 서버 연결 실패, 다시 시도 중 (\(attempt)/\(delays.count - 1))"
                        try await Task.sleep(for: .seconds(delay))
                    }
                    let result = try await lyrics.find(track)
                    try Task.checkCancellation()
                    guard song.identity == track.identity else { return }
                    switch result {
                    case .synced(let found, let source): lines = found; lyricsStatus = "싱크 가사 있음 · \(source) · \(found.count)줄"
                    case .instrumental: lyricsStatus = "연주곡 · 가사 없음"
                    case .plainOnly: lyricsStatus = "일반 가사만 있음 · 싱크 가사 없음"
                    case .notFound: lyricsStatus = "싱크 가사를 찾지 못함"
                    }
                    if force { onLyricsNotice?(LyricsNotice.message(for: result)) }
                    prefetchNext(after: track)
                    updateDisplayTitle(track)
                    return
                } catch {
                    if Task.isCancelled { return }
                    LyricsLog.write("WARN lyrics lookup failed (\(attempt + 1)/\(delays.count)) for \(track.artist) - \(track.title): \(error.localizedDescription)")
                }
            }
            guard song.identity == track.identity else { return }
            lyricsStatus = "가사 서버에 연결하지 못함 · 가사 진단 기록 확인"
            if force { onLyricsNotice?("가사 서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요") }
        }
    }

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
                    guard let next = try await nextSong(), next.videoId + "|" + next.title != current.videoId + "|" + current.title else { return }
                    try await lyrics.prefetch(next)
                    return
                } catch {
                    if Task.isCancelled { return }
                    LyricsLog.write("INFO fetching ahead failed (\(error.localizedDescription)), will try again while this song plays")
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
    /// from a cache without asking YouTube Music, ask for the title alone (once per video and session).
    private func updateDisplayTitle(_ track: Song) {
        guard track.mediaType == "AUDIO", !track.videoId.isEmpty else { return }
        if lyrics.ytm.known(track.videoId) != nil { titleRevision += 1; return }
        guard settings.ytmLyrics, !lyrics.ytm.paused else { return }
        Task {
            do { _ = try await lyrics.ytm.lookup(track.videoId, withLyrics: false) }
            catch { if !Task.isCancelled { LyricsLog.write("INFO title lookup failed for \(track.videoId): \(error.localizedDescription)") }; return }
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
        case .plainOnly: return "이 곡은 일반 가사만 있고 싱크 가사는 없어요"
        case .notFound: return "이 곡은 싱크 가사를 찾지 못했어요"
        }
    }
}
