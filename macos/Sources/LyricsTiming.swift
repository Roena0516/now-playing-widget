import Foundation

/// Lyrics timing set for one video (가사 타이밍 → 이 곡), added to the timing for all songs (lyricsOffsetMs). A cover gets
/// its original's lyrics, and its singing often starts a little earlier or later than the original's. Kept in
/// lyrics-timing.json next to config.json, oldest change first, so the oldest go when there are too many. Same format as
/// the Windows version (LyricsTiming.cs).
final class LyricsTiming {
    static let limit = 30000   // ms either way
    private struct File: Codable {
        struct Entry: Codable { var id: String; var ms: Int }
        var version: Int? = 1
        var videos: [Entry]
    }
    private let file: URL
    private let maxEntries: Int
    private var values: [String: Int] = [:]
    private var order: [String] = []   // oldest change first

    init(file: URL, maxEntries: Int = 5000) {
        self.file = file; self.maxEntries = maxEntries
        load()
    }

    static func canKeep(_ videoId: String) -> Bool {
        videoId.count == 11 && videoId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The timing for a video in ms (+ = lyrics earlier), 0 when none was set.
    func ms(for videoId: String) -> Int { values[videoId] ?? 0 }

    /// Sets a video's timing (0 forgets it) and saves the file. Returns the value kept (clamped).
    @discardableResult func set(_ videoId: String, _ ms: Int) -> Int {
        guard Self.canKeep(videoId) else { return 0 }
        let ms = max(-Self.limit, min(Self.limit, ms))
        order.removeAll { $0 == videoId }
        values[videoId] = nil
        if ms != 0 {
            values[videoId] = ms; order.append(videoId)
            trim()
        }
        save()
        return ms
    }

    private func trim() {
        while order.count > maxEntries { values[order.removeFirst()] = nil }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let stored = try? JSONDecoder().decode(File.self, from: data) else {
            Log.write("WARN lyrics timing file unreadable: \(file.lastPathComponent)"); return
        }
        for entry in stored.videos where Self.canKeep(entry.id) && entry.ms != 0 {
            if values[entry.id] != nil { order.removeAll { $0 == entry.id } }
            values[entry.id] = max(-Self.limit, min(Self.limit, entry.ms)); order.append(entry.id)
        }
        trim()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(videos: order.map { File.Entry(id: $0, ms: values[$0]!) })).write(to: file, options: .atomic)
        } catch { Log.write("WARN lyrics timing not saved: \(error.localizedDescription)") }
    }

    /// How a timing reads in the menu and messages: "기본", "0.3초 빠르게", "1초 늦게" (+ = lyrics earlier).
    static func text(_ ms: Int) -> String {
        if ms == 0 { return "기본" }
        var seconds = String(format: "%.2f", Double(abs(ms)) / 1000)
        while seconds.hasSuffix("0") { seconds.removeLast() }
        if seconds.hasSuffix(".") { seconds.removeLast() }
        return seconds + "초 " + (ms > 0 ? "빠르게" : "늦게")
    }
}
