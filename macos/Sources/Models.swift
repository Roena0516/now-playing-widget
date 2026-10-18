import Foundation

let appVersion = "1.5.1"

struct Settings: Codable {
    var host = "127.0.0.1"
    var port = 26538
    var position = "BottomLeft"
    var marginX: Double = 24
    var marginY: Double = 24
    var scale: Double = 1
    var panelWidth: Double = 420
    var monitor = 0
    var showSeconds: Double = 6
    var opacity: Double = 0.92
    var alwaysShow = false
    var showLyrics = true
    var lyricsOffsetMs: Double = 300
    var ytmLyrics = true
    var ytmLyricsProxy = YTMusicProvider.defaultProxy
    var lyricsServer = "https://lrclib.net"
    var positionLayoutVersion: Int? = 1
    init() {}
    // Keys missing from an older config.json keep their defaults instead of discarding the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        host = try value(.host, host); port = try value(.port, port); position = try value(.position, position)
        marginX = try value(.marginX, marginX); marginY = try value(.marginY, marginY)
        scale = try value(.scale, scale); panelWidth = try value(.panelWidth, panelWidth); monitor = try value(.monitor, monitor)
        showSeconds = try value(.showSeconds, showSeconds); opacity = try value(.opacity, opacity)
        alwaysShow = try value(.alwaysShow, alwaysShow); showLyrics = try value(.showLyrics, showLyrics)
        lyricsOffsetMs = try value(.lyricsOffsetMs, lyricsOffsetMs)
        ytmLyrics = try value(.ytmLyrics, ytmLyrics); ytmLyricsProxy = try value(.ytmLyricsProxy, ytmLyricsProxy)
        lyricsServer = try value(.lyricsServer, lyricsServer)
        positionLayoutVersion = try c.decodeIfPresent(Int.self, forKey: .positionLayoutVersion)
    }
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PearNowPlaying-macOS")
    static let file = directory.appendingPathComponent("config.json")
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: file), var settings = try? JSONDecoder().decode(Settings.self, from: data),
              (1...65535).contains(settings.port), settings.host == "127.0.0.1" || settings.host == "localhost",
              (0.5...3).contains(settings.scale), (260...800).contains(settings.panelWidth),
              (0.1...1).contains(settings.opacity), (1...3600).contains(settings.showSeconds), settings.marginX.isFinite, settings.marginY.isFinite else { return Settings() }
        // the lyric servers only make sense over HTTPS; a typo falls back to the default instead of breaking lookups
        if URL(string: settings.ytmLyricsProxy)?.scheme != "https" { settings.ytmLyricsProxy = YTMusicProvider.defaultProxy }
        if URL(string: settings.lyricsServer)?.scheme != "https" { settings.lyricsServer = "https://lrclib.net" }
        settings.migratePosition()
        return settings
    }
    mutating func migratePosition() {
        guard (positionLayoutVersion ?? 0) < 1 else { return }
        if marginX == 40 && marginY == 140 { marginX = 24; marginY = 24 }
        positionLayoutVersion = 1
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }
}
struct Song: Equatable {
    var title = "", alternativeTitle = "", artist = "", album = "", imageSrc = "", videoId = ""
    /// AUDIO, ORIGINAL_MUSIC_VIDEO, USER_GENERATED_CONTENT, PODCAST_EPISODE, OTHER_VIDEO (Pear's MediaType); UNKNOWN for queue entries
    var mediaType = ""
    var tags: [String] = []
    var duration: Double = 0, elapsed: Double = 0
    var paused = true
    init(_ d: [String: Any] = [:]) {
        alternativeTitle = d["alternativeTitle"] as? String ?? ""
        title = d["title"] as? String ?? ""
        if title.isEmpty { title = alternativeTitle }
        tags = d["tags"] as? [String] ?? []
        artist = d["artist"] as? String ?? ""; album = d["album"] as? String ?? ""
        imageSrc = d["imageSrc"] as? String ?? ""; videoId = d["videoId"] as? String ?? ""
        duration = (d["songDuration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (d["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0
        paused = d["isPaused"] as? Bool ?? true
        mediaType = d["mediaType"] as? String ?? ""
    }
    init(title: String, alternativeTitle: String = "", artist: String, album: String = "", videoId: String = "", mediaType: String = "", duration: Double = 0) {
        self.title = title; self.alternativeTitle = alternativeTitle; self.artist = artist; self.album = album
        self.videoId = videoId; self.mediaType = mediaType; self.duration = duration
    }
    var identity: String { videoId + "|" + title + "|" + artist }
}
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}
func parseLRC(_ source: String) -> [LyricLine] {
    let stamp = try! NSRegularExpression(pattern: #"^\[(\d+):(\d+)(?:[.:](\d+))?\]"#)
    let offsetTag = try! NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]$"#)
    var entries: [(Double, String)] = []
    var offset: Double = 0
    for raw in source.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var times: [Double] = []
        while let match = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            let ns = line as NSString
            let minute = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let second = Double(ns.substring(with: match.range(at: 2))) ?? 0
            var fraction: Double = 0
            if match.range(at: 3).location != NSNotFound {
                let digits = String(ns.substring(with: match.range(at: 3)).prefix(3))
                fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            }
            let time = minute * 60 + second + fraction
            if time.isFinite { times.append(time) }
            line = ns.substring(from: NSMaxRange(match.range))
        }
        if times.isEmpty {
            if let match = offsetTag.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) { offset = (Double(line[range]) ?? 0) / 1000 }
            continue
        }
        let text = line.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        entries += times.map { ($0, text.isEmpty ? "♪" : text) }
    }
    return entries.map { (max(0, $0.0 + offset), $0.1) }.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
}
func activeLyric(_ lines: [LyricLine], at time: Double) -> Int? { lines.lastIndex { $0.time <= time } }
