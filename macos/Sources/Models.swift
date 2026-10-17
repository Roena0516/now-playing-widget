import Foundation

struct Settings: Codable {
    var host = "127.0.0.1"
    var port = 26538
    var position = "BottomLeft"
    var marginX: Double = 40
    var marginY: Double = 140
    var scale: Double = 1
    var panelWidth: Double = 420
    var monitor = 0
    var showSeconds: Double = 6
    var opacity: Double = 0.92
    var alwaysShow = false
    var showLyrics = true
    var lyricsOffsetMs: Double = 300
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PearNowPlaying-macOS")
    static let file = directory.appendingPathComponent("config.json")
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: file), let settings = try? JSONDecoder().decode(Settings.self, from: data),
              (1...65535).contains(settings.port), settings.host == "127.0.0.1" || settings.host == "localhost",
              (0.5...3).contains(settings.scale), (260...800).contains(settings.panelWidth),
              (0.1...1).contains(settings.opacity), (1...3600).contains(settings.showSeconds), settings.marginX.isFinite, settings.marginY.isFinite else { return Settings() }
        return settings
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }
}
struct Song: Equatable {
    var title = "", artist = "", album = "", imageSrc = "", videoId = ""
    var duration: Double = 0, elapsed: Double = 0
    var paused = true
    init(_ d: [String: Any] = [:]) {
        title = d["title"] as? String ?? d["alternativeTitle"] as? String ?? ""
        artist = d["artist"] as? String ?? ""; album = d["album"] as? String ?? ""
        imageSrc = d["imageSrc"] as? String ?? ""; videoId = d["videoId"] as? String ?? ""
        duration = (d["songDuration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (d["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0
        paused = d["isPaused"] as? Bool ?? true
    }
    var identity: String { videoId + "|" + title + "|" + artist }
}
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}
func parseLRC(_ source: String) -> [LyricLine] {
    let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
    var result: [(Double, String)] = []
    var offset: Double = 0
    let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#)
    if let match = offsetPattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
       let range = Range(match.range(at: 1), in: source) { offset = (Double(source[range]) ?? 0) / 1000 }
    for line in source.components(separatedBy: .newlines) {
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard let last = matches.last, let textRange = Range(NSRange(location: NSMaxRange(last.range), length: (line as NSString).length - NSMaxRange(last.range)), in: line) else { continue }
        let text = String(line[textRange]).replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for match in matches {
            let minute = Double((line as NSString).substring(with: match.range(at: 1))) ?? 0
            let second = Double((line as NSString).substring(with: match.range(at: 2))) ?? 0
            result.append((max(0, minute * 60 + second + offset), text.isEmpty ? "♪" : text))
        }
    }
    return result.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
}
func activeLyric(_ lines: [LyricLine], at time: Double) -> Int? { lines.lastIndex { $0.time <= time } }
