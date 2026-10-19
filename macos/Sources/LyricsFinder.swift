import Foundation

/// An LRCLIB lookup that failed (busy, timeout, server error) while looking for a cover's original.
/// Ends the whole lookup so it is retried later, instead of being taken for "no original found".
struct LrclibFailed: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// The whole order of finding lyrics for a song, as LyricsProvider.Find in src/Lyrics.cs:
///   cache -> fetched ahead -> YouTube Music (the video, then its official audio track)
///   -> covers: the original's lyrics -> LRCLIB.
/// Throws when the lookup failed (LRCLIB busy / unreachable); failures are never cached as "no lyrics".
@MainActor final class LyricsFinder {
    let lrclib: LyricsProvider
    let ytm: YTMusicProvider
    var useYtm = true
    private let log: (String) -> Void
    private var cache: [String: LyricsLookup] = [:]
    private var prefetched: [String: LyricsLookup] = [:]

    init(lrclib: LyricsProvider, ytm: YTMusicProvider, log: @escaping (String) -> Void = { _ in }) {
        self.lrclib = lrclib; self.ytm = ytm; self.log = log
    }

    private static func key(_ song: Song) -> String { song.videoId + "|" + song.title }

    /// `cacheMisses`: false for a look-ahead, where a "not found" from the queue's sparser song info
    /// shouldn't stop the song from being looked up again with Pear's full info when it starts.
    func find(_ song: Song, cacheMisses: Bool = true) async throws -> LyricsLookup {
        let key = Self.key(song)
        if let hit = cache[key] { return hit }
        // fetched ahead while the previous song played (the queue's title can differ slightly, so by video ID)
        if !song.videoId.isEmpty, let hit = prefetched.removeValue(forKey: song.videoId) {
            cache[key] = hit
            log("INFO lyrics ready (fetched ahead): \(song.artist) - \(song.title)")
            return hit
        }
        log("INFO looking up lyrics: \(song.artist) - \(song.title) [\(song.mediaType.isEmpty ? "type?" : song.mediaType), \(song.videoId), \(Int(song.duration))s]")

        // A cover's description is only needed when YouTube Music has no lyrics for the video itself, which is
        // the usual case for covers: ask for it alongside the first lookups instead of after them.
        let coverCandidate = !ytm.paused && !song.videoId.isEmpty && song.duration > 0 && CoverLyrics.mayBeCover(song)
        let description = coverCandidate && !CoverLyrics.looksArranged(song.title) && !CoverLyrics.looksArranged(song.alternativeTitle)
            ? descriptionTask(song.videoId) : nil
        defer { description?.cancel() }

        // 1) YouTube Music's own synced lyrics; on any failure (relay down, rate limit) fall back to LRCLIB
        var ytmError = false, ytmPlain = false
        if useYtm && !song.videoId.isEmpty {
            if ytm.paused { ytmError = true; log("INFO YouTube Music skipped (relay paused after repeated failures) -> LRCLIB") }
            else {
                do {
                    let info = try await ytm.lookup(song.videoId)
                    if !info.lines.isEmpty {
                        log("INFO lyrics found via YouTube Music: \(song.artist) - \(song.title) (\(Int(song.duration))s)")
                        return remember(key, .synced(info.lines, source: "YouTube Music"))
                    }
                    ytmPlain = info.plainOnly
                    // a music video: YouTube Music has timed lyrics only on the official audio track
                    if let audio = try await audioTrackLyrics(info) {
                        log("INFO lyrics found via the official audio track on YouTube Music: \(song.artist) - \(song.title)")
                        return remember(key, .synced(audio, source: "YouTube Music · 공식 음원"))
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    ytmError = true
                    log("WARN YouTube Music lyrics failed for \(song.artist) - \(song.title): \(error.localizedDescription) -> LRCLIB")
                }
            }
        }

        // 2) covers: the original song linked in the description, if the music wasn't changed
        // (uses YouTube only for the description and the original's title/length, so it runs even with ytmLyrics off)
        if coverCandidate && !ytm.paused, let original = try await fromOriginal(song, description) {
            return remember(key, original)
        }

        // 3) LRCLIB
        var result = try await lrclib.find(song)
        if case .notFound = result, ytmPlain { result = .plainOnly }
        // a "not found" is only final when YouTube Music answered too; otherwise ask again next time
        if result.isFound || (cacheMisses && !ytmError) { cache[key] = result }
        return result
    }

    private func remember(_ key: String, _ result: LyricsLookup) -> LyricsLookup { cache[key] = result; return result }

    /// The video's description in the background; nil when it can't be read (logged).
    private func descriptionTask(_ videoId: String) -> Task<VideoDescription?, Never> {
        Task {
            do { return try await ytm.description(videoId) }
            catch {
                if !Task.isCancelled { log("INFO cover: description unavailable (\(error.localizedDescription)), using the title only") }
                return nil
            }
        }
    }

    /// Look the next song up ahead of time. Only a found result is kept for it; if nothing turns up, the song
    /// is looked up again normally when it starts (with Pear's fuller song info).
    func prefetch(_ next: Song) async throws {
        if cache[Self.key(next)] != nil || prefetched[next.videoId] != nil { return }
        log("INFO fetching lyrics ahead for the next song: \(next.artist) - \(next.title)")
        let result = try await find(next, cacheMisses: false)
        if result.isFound {
            if prefetched.count > 20 { prefetched.removeAll() }
            prefetched[next.videoId] = result
        }
    }

    /// Drop the cached result for a song so the next find asks again.
    func forget(_ song: Song) {
        cache.removeValue(forKey: Self.key(song)); prefetched.removeValue(forKey: song.videoId)
        ytm.forget(song.videoId)
    }

    /// Synced lyrics of the original song for a cover: follow the YouTube links in the cover's description, take
    /// the first linked video whose length is within a few seconds of the cover, and use its YouTube Music
    /// lyrics (or LRCLIB with the original's title/artist). Covers that say they are remixes/arrangements and
    /// candidates whose length differs are skipped, since the timing would drift. Nil = not usable.
    private func fromOriginal(_ song: Song, _ description: Task<VideoDescription?, Never>?) async throws -> LyricsLookup? {
        if CoverLyrics.looksArranged(song.title) || CoverLyrics.looksArranged(song.alternativeTitle) {
            log("INFO cover: title says arranged/remixed, original's lyrics not used: \(song.title)")
            return nil
        }
        do {
            let desc = await description?.value
            try Task.checkCancellation()
            let (ids, hinted) = CoverLyrics.originalCandidates(desc, ownId: song.videoId)
            if ids.isEmpty { log("INFO cover: no YouTube links in the description of \(song.videoId)") }
            for id in ids {
                let orig = try await ytm.lookup(id, withLyrics: useYtm)
                let label = "\(id) (\(orig.artist) - \(orig.title), \(Int(orig.duration))s)"
                if orig.duration <= 0 { log("INFO cover: original candidate \(id) has no known length, skipped"); continue }
                if CoverLyrics.looksArranged(orig.title) { log("INFO cover: candidate \(label) is an arrangement, skipped"); continue }
                // links without an "原曲 / original" label are often the singer's other videos: the title must fit
                if !hinted.contains(id) && !CoverLyrics.titleMatchesCover(song, orig) { log("INFO cover: candidate \(label) is a different song, skipped"); continue }
                let diff = abs(orig.duration - song.duration)
                if diff > CoverLyrics.maxLengthDiff { log("INFO cover: candidate \(label) differs from the cover by \(Int(diff))s, skipped"); continue }
                if !orig.lines.isEmpty {
                    log("INFO lyrics found via original \(label) on YouTube Music: \(song.artist) - \(song.title)")
                    return .synced(orig.lines, source: "YouTube Music · 원곡")
                }
                if useYtm {
                    // the link is usually the original's music video; its official audio track has the timed lyrics
                    // the cover may call it differently ("帝国少女" for "Imperial Girl")
                    let coverName = CoverLyrics.guessOriginal(song, description: desc?.text).title
                    if let audio = try await audioTrackLyrics(orig, otherNames: [coverName]) {
                        log("INFO lyrics found via original \(label)'s official audio on YouTube Music: \(song.artist) - \(song.title)")
                        return .synced(audio, source: "YouTube Music · 원곡")
                    }
                }
                if !orig.title.isEmpty {
                    // "ビノミ - Binomi": also try the title without the romanized/translated half
                    let primary = CoverLyrics.primaryTitle(orig.title, artist: orig.artist)
                    let l = try await lrclibFind(Song(title: orig.title, alternativeTitle: primary != orig.title ? primary : "",
                                                      artist: orig.artist, videoId: id, duration: orig.duration))
                    if case .synced(let lines, _) = l {
                        log("INFO lyrics found via original \(label) on LRCLIB: \(song.artist) - \(song.title)")
                        return .synced(lines, source: "LRCLIB · 원곡")
                    }
                }
                log("INFO cover: original \(label) has no synced lyrics on LRCLIB under that name")
                break   // the first usable link decides; don't wander through unrelated links
            }

            // no usable link: work out the song from the title / description and look it up on LRCLIB
            return try await fromSearch(song, desc)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is LrclibFailed { throw error }   // LRCLIB busy: retried later, not cached
            log("WARN cover -> original lookup failed for \(song.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// No usable link: read the song title (and original artist, if given) from the cover's title or description
    /// and look the original up on LRCLIB. (YouTube Music's own search doesn't list songs without signing in,
    /// so it can't be used for this.) The original must be within a few seconds of the cover's length.
    private func fromSearch(_ song: Song, _ desc: VideoDescription?) async throws -> LyricsLookup? {
        let (title, artist) = CoverLyrics.guessOriginal(song, description: desc?.text)
        if title.isEmpty { log("INFO cover: couldn't tell the song title from \"\(song.title)\""); return nil }
        log("INFO cover: looking up the original on LRCLIB: \"\(title)\"" + (artist.isEmpty ? " (artist unknown)" : " by \"\(artist)\""))
        let l = try await lrclibFind(Song(title: title, artist: artist, videoId: song.videoId + "#original", duration: song.duration),
                                     titleTolerance: CoverLyrics.maxLengthDiff)
        guard case .synced(let lines, _) = l else { return nil }
        log("INFO lyrics found via original \"\(title)\" on LRCLIB: \(song.artist) - \(song.title)")
        return .synced(lines, source: "LRCLIB · 원곡 검색")
    }

    private func lrclibFind(_ song: Song, titleTolerance: Double = 3) async throws -> LyricsLookup {
        do { return try await lrclib.find(song, titleTolerance: titleTolerance) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw LrclibFailed(underlying: error)
        }
    }

    /// For a music video / upload: find the official audio track (artist page -> single/album) and get its
    /// YouTube Music lyrics. Nil when there is none or it has no timed lyrics. Failures are logged, not thrown.
    private func audioTrackLyrics(_ video: TrackInfo, otherNames: [String] = []) async throws -> [LyricLine]? {
        if video.videoType == "MUSIC_VIDEO_TYPE_ATV" { return nil }
        do {
            guard let audioId = try await ytm.findAudioTrack(video, otherNames: otherNames), audioId != video.videoId else { return nil }
            let audio = try await ytm.lookup(audioId)
            return audio.lines.isEmpty ? nil : audio.lines
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log("INFO official audio lookup failed for \(video.videoId): \(error.localizedDescription)")
            return nil
        }
    }
}
