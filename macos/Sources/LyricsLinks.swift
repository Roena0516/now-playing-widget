import Foundation

/// Which YouTube Music track's timed lyrics a video got: a cover's original (" · 원곡") or a music video's official audio
/// (" · 공식 음원"). Finding that track takes 5–10 requests, 3–12 s; with the link kept, the next time the video plays
/// only that track's lyrics are asked for (about 1 s; user's request 2026-11-20). The lyrics themselves aren't kept.
/// Kept in lyrics-links.json in the caches folder, oldest first; links older than 90 days are dropped. Same format as
/// the Windows version (src/LyricsLinks.cs).
final class LyricsLinks {
    struct Link: Codable { var id: String; var from: String; var source: String; var day: Int }
    private struct File: Codable { var version: Int? = 1; var videos: [Link] }
    static let maxDays = 90, maxEntries = 10000

    static let defaultFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PearNowPlaying-macOS", isDirectory: true).appendingPathComponent("lyrics-links.json")

    private let file: URL
    private let log: (String) -> Void
    private var links: [Link] = []   // oldest first

    init(file: URL = LyricsLinks.defaultFile, log: @escaping (String) -> Void = { _ in }) {
        self.file = file; self.log = log
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(File.self, from: data) else { return }
        for l in decoded.videos where LyricsTiming.canKeep(l.id) && LyricsTiming.canKeep(l.from) && l.source.hasPrefix("YouTube Music · ") {
            links.removeAll { $0.id == l.id }
            links.append(l)
        }
    }

    private static var today: Int { Int(Date().timeIntervalSince1970 / 86400) }

    /// Only another video's lyrics from YouTube Music are worth a link.
    static func keeps(_ videoId: String, from: String, source: String) -> Bool {
        !from.isEmpty && from != videoId && LyricsTiming.canKeep(videoId) && LyricsTiming.canKeep(from) && source.hasPrefix("YouTube Music · ")
    }

    func get(_ videoId: String) -> Link? { links.first { $0.id == videoId && Self.today - $0.day <= Self.maxDays } }

    func set(_ videoId: String, from: String, source: String) {
        guard Self.keeps(videoId, from: from, source: source) else { return }
        links.removeAll { $0.id == videoId || Self.today - $0.day > Self.maxDays }
        links.append(Link(id: videoId, from: from, source: source, day: Self.today))
        if links.count > Self.maxEntries { links.removeFirst(links.count - Self.maxEntries) }
        save()
    }

    func forget(_ videoId: String) {
        let before = links.count
        links.removeAll { $0.id == videoId }
        if links.count != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(videos: links)).write(to: file, options: .atomic)
        } catch { log("WARN lyrics links not saved: \(error.localizedDescription)") }
    }
}
