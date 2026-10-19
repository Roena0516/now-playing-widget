import Foundation

/// Lyrics found on LRCLIB, kept on disk between runs so songs played again don't ask LRCLIB again (its
/// uncached lookups are often refused as "busy"). One small JSON file per YouTube video ID, under
/// ~/Library/Caches/PearNowPlaying-macOS/lyrics. Only found lyrics are stored, never misses or failures;
/// "find lyrics again" removes the entry. Same format as the Windows version (src/LyricsDiskCache.cs).
@MainActor final class LyricsDiskCache {
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PearNowPlaying-macOS/lyrics")
    static let maxAge: TimeInterval = 90 * 86400
    /// Entries of older formats are dropped. 2 (1.7.1): 1.6–1.7 could save a same-name song's lyrics for a cover
    /// whose original didn't fit (see LyricsFinder.fromOriginal), so their entries are looked up again once.
    /// 3 (1.7.3): another version's "instrumental" mark could be saved for a remix (see LyricsProvider.pick).
    nonisolated static let formatVersion = 3

    private struct Entry: Codable {
        struct Line: Codable { var timeMs: Int; var text: String }
        var version = LyricsDiskCache.formatVersion
        var videoId: String, title: String, artist: String, source: String
        var instrumental: Bool
        var savedAt: String
        var lines: [Line]
    }

    let directory: URL
    private let maxEntries: Int
    private let log: (String) -> Void

    init(directory: URL = LyricsDiskCache.defaultDirectory, maxEntries: Int = 3000, log: @escaping (String) -> Void = { _ in }) {
        self.directory = directory; self.maxEntries = maxEntries; self.log = log
    }

    private static let videoId = Rx(#"^[A-Za-z0-9_-]{11}$"#)
    private static let dateFormat: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    private func file(_ videoId: String) -> URL? {
        Self.videoId.matches(videoId) ? directory.appendingPathComponent(videoId + ".json") : nil
    }

    /// Worth keeping: lyrics (or "instrumental") that came from LRCLIB.
    static func keeps(_ result: LyricsLookup) -> Bool {
        switch result {
        case .synced(let lines, let source): return !lines.isEmpty && source.hasPrefix("LRCLIB")
        case .instrumental: return true   // only LRCLIB reports instrumentals
        default: return false
        }
    }

    /// The stored lyrics for a video, or nil (none, expired or unreadable).
    func load(_ videoId: String) -> LyricsLookup? {
        guard let url = file(videoId), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            guard entry.version >= Self.formatVersion, let saved = Self.dateFormat.date(from: entry.savedAt), Date().timeIntervalSince(saved) <= Self.maxAge,
                  entry.instrumental || !entry.lines.isEmpty else {
                try? FileManager.default.removeItem(at: url); return nil
            }
            if entry.instrumental { return .instrumental }
            let lines = entry.lines.sorted { $0.timeMs < $1.timeMs }.enumerated()
                .map { LyricLine(id: $0.offset, time: Double($0.element.timeMs) / 1000, text: $0.element.text) }
            return .synced(lines, source: entry.source)
        } catch {
            log("INFO lyrics cache: couldn't read \(videoId) (\(error.localizedDescription))")
            return nil
        }
    }

    func save(_ song: Song, _ result: LyricsLookup) {
        guard let url = file(song.videoId), Self.keeps(result) else { return }
        var entry = Entry(videoId: song.videoId, title: song.title, artist: song.artist, source: "LRCLIB", instrumental: true,
                          savedAt: Self.dateFormat.string(from: Date()), lines: [])
        if case .synced(let lines, let source) = result {
            entry.source = source; entry.instrumental = false
            entry.lines = lines.map { Entry.Line(timeMs: Int(($0.time * 1000).rounded()), text: $0.text) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
            prune()
        } catch { log("INFO lyrics cache: couldn't save \(song.videoId) (\(error.localizedDescription))") }
    }

    func forget(_ videoId: String) {
        guard let url = file(videoId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Over the limit: drop the oldest entries, down to 90% of it.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter({ $0.pathExtension == "json" }), files.count > maxEntries else { return }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        for url in files.sorted(by: { modified($0) < modified($1) }).prefix(files.count - maxEntries * 9 / 10) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
