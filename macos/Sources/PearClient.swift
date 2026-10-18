import Foundation
import Combine

@MainActor final class PearClient: ObservableObject {
    @Published var song = Song()
    @Published var status = "Pear Desktop 기다리는 중"
    @Published var lines: [LyricLine] = []
    @Published var lyricsStatus = "가사 대기 중"
    @Published var artwork: Data?
    var onLyricsNotice: ((String?) -> Void)?
    @Published var settings = Settings.load()
    private var connection: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var anchor = Date()
    private var token: String?
    private let lyricsProvider = LyricsProvider(log: LyricsLog.write)
    private let ytMusicProvider = YTMusicProvider(log: LyricsLog.write)
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
    }
    private var tokenFile: URL { directory.appendingPathComponent("token.txt") }
    var elapsed: Double { min(max(0, song.elapsed + (song.paused ? 0 : Date().timeIntervalSince(anchor))), max(0, song.duration)) }
    var baseURL: URL { URL(string: "http://\(settings.host):\(settings.port)")! }
    func start() {
        connection?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        connection = Task { await run() }
    }
    func retryAuth() { token = nil; try? FileManager.default.removeItem(at: tokenFile); start() }
    func stop() { connection?.cancel(); lyricTask?.cancel(); artTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }
    func reload() { settings = Settings.load(); settings.save(); start() }
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
        lyricTask?.cancel(); lines = []; lyricsStatus = "가사 검색 중"
        let track = song
        guard !track.title.isEmpty else { lyricsStatus = "가사 대기 중"; if force { onLyricsNotice?("재생 중인 곡이 없어요") }; return }
        if force { lyricsProvider.forget(track); ytMusicProvider.forget(track); onLyricsNotice?("가사를 다시 찾는 중이에요") }
        lyricTask = Task {
            for (attempt, delay) in LyricsProvider.lookupRetryDelays.enumerated() {
                do {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    var youtubePlain = false
                    do {
                        let youtube = try await ytMusicProvider.find(track)
                        try Task.checkCancellation()
                        if case .synced(let found, _) = youtube {
                            guard song.identity == track.identity else { return }
                            lines = found; lyricsStatus = "싱크 가사 있음 · YTMusic · \(found.count)줄"; if force { onLyricsNotice?(nil) }; return
                        }
                        if case .plainOnly = youtube { youtubePlain = true }
                    } catch {
                        if Task.isCancelled { return }
                        LyricsLog.write("YTMusic 조회 실패, LRCLIB 시도: \(error.localizedDescription)")
                    }
                    let result = try await lyricsProvider.find(track)
                    try Task.checkCancellation()
                    guard song.identity == track.identity else { return }
                    switch result {
                    case .synced(let found, _): lines = found; lyricsStatus = "싱크 가사 있음 · LRCLIB · \(found.count)줄"
                    case .instrumental: lyricsStatus = "연주곡 · 가사 없음"
                    case .plainOnly: lyricsStatus = "일반 가사만 있음 · 싱크 가사 없음"
                    case .notFound: lyricsStatus = youtubePlain ? "YTMusic 일반 가사만 있음 · 싱크 가사 없음" : "싱크 가사를 찾지 못함"
                    }
                    if force { onLyricsNotice?(LyricsNotice.message(for: result)) }
                    return
                } catch {
                    if Task.isCancelled { return }
                    LyricsLog.write("가사 검색 실패 (\(attempt + 1)/\(LyricsProvider.lookupRetryDelays.count)): \(track.artist) - \(track.title): \(error.localizedDescription)")
                    lyricsStatus = "가사 서버 연결 재시도 중 (\(attempt + 1)/\(LyricsProvider.lookupRetryDelays.count))"
                }
            }
            lyricsStatus = "가사 서버 연결 실패 · 가사 진단 기록 확인"
            if force && song.identity == track.identity { onLyricsNotice?("가사 서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요") }
        }
    }

}

// Pear versions using Hono JWT middleware authenticate the WebSocket HTTP upgrade
// with a bearer header. A token query parameter alone is not accepted.
func makeWebSocketRequest(url: URL, token: String?) -> URLRequest {
    var request = URLRequest(url: url)
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
