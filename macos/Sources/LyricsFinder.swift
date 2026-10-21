import Foundation

/// An LRCLIB lookup that failed (busy, timeout, server error) while looking for a cover's original.
/// Ends the whole lookup so it is retried later, instead of being taken for "no original found".
struct LrclibFailed: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// Set (for the task under LyricsFinder.recheck only) while LRCLIB is asked again: no Kugou / NetEase, no YouTube Music lyrics.
enum LrclibRecheck { @TaskLocal static var only = false }

/// The whole order of finding lyrics for a song, as LyricsProvider.Find in src/Lyrics.cs:
///   cache -> fetched ahead -> YouTube Music (the video, then its official audio track)
///   -> covers: the original's lyrics -> LRCLIB.
/// Throws when the lookup failed (LRCLIB busy / unreachable); failures are never cached as "no lyrics".
@MainActor final class LyricsFinder {
    let lrclib: LyricsProvider
    let ytm: YTMusicProvider
    var useYtm = true
    /// Kugou / NetEase, asked when LRCLIB has no synced lyrics (when useMore is on); nil = not at all.
    let more: MoreLyrics?
    var useMore = true
    /// Lyrics found on LRCLIB, Kugou or NetEase kept between runs; nil = memory only.
    let disk: LyricsDiskCache?
    private let log: (String) -> Void
    private var cache: [String: LyricsLookup] = [:]
    private var prefetched: [String: LyricsLookup] = [:]
    /// Songs (by videoId) whose lyrics this run are a stand-in: found on Kugou / NetEase because LRCLIB was busy.
    private var standIns: Set<String> = []
    /// When LRCLIB was last asked about a song whose lyrics came from Kugou / NetEase (by videoId, this run).
    private var lrclibChecked: [String: Date] = [:]

    init(lrclib: LyricsProvider, ytm: YTMusicProvider, more: MoreLyrics? = nil, disk: LyricsDiskCache? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.lrclib = lrclib; self.ytm = ytm; self.more = more; self.disk = disk; self.log = log
    }

    private static func key(_ song: Song) -> String { song.videoId + "|" + song.title }
    /// By videoId, as a result fetched ahead (the queue's title can differ slightly); the key when there is none.
    private static func id(_ song: Song) -> String { song.videoId.isEmpty ? key(song) : song.videoId }

    /// `cacheMisses`: false for a look-ahead, where a "not found" from the queue's sparser song info
    /// shouldn't stop the song from being looked up again with Pear's full info when it starts.
    /// A result known without asking anyone: this run's cache, the one fetched ahead, or the disk cache. Nil when
    /// a lookup is needed. Lets a song change swap the lyrics in place instead of closing the card first.
    func known(_ song: Song) -> LyricsLookup? {
        let key = Self.key(song)
        if let hit = cache[key] { return hit }
        // fetched ahead while the previous song played (the queue's title can differ slightly, so by video ID)
        if !song.videoId.isEmpty, let hit = prefetched.removeValue(forKey: song.videoId) {
            cache[key] = hit
            log("INFO lyrics ready (fetched ahead): \(song.artist) - \(song.title)")
            return hit
        }
        // found on LRCLIB in an earlier run
        if let stored = disk?.load(song.videoId) {
            cache[key] = stored
            log("INFO lyrics from the disk cache: \(song.artist) - \(song.title)")
            return stored
        }
        return nil
    }

    func find(_ song: Song, cacheMisses: Bool = true) async throws -> LyricsLookup {
        if let hit = known(song) { return hit }
        return try await lookup(song, cacheMisses: cacheMisses)
    }

    /// find past the caches: asks the lyrics servers.
    private func lookup(_ song: Song, cacheMisses: Bool) async throws -> LyricsLookup {
        let key = Self.key(song)
        if !LrclibRecheck.only { standIns.remove(Self.id(song)) }
        log("INFO \(LrclibRecheck.only ? "asking LRCLIB again: " : "")looking up lyrics: \(song.artist) - \(song.title) [\(song.mediaType.isEmpty ? "type?" : song.mediaType), \(song.videoId), \(Int(song.duration))s]")

        // A cover's description is only needed when YouTube Music has no lyrics for the video itself, which is
        // the usual case for covers: ask for it alongside the first lookups instead of after them.
        // (not tied to the lyrics relay: the description and the original's title/length come from YouTube directly)
        let coverCandidate = !song.videoId.isEmpty && song.duration > 0 && CoverLyrics.mayBeCover(song)
        let description = coverCandidate && !CoverLyrics.looksArranged(song.title) && !CoverLyrics.looksArranged(song.alternativeTitle)
            ? descriptionTask(song.videoId) : nil
        defer { description?.cancel() }

        // 1) YouTube Music's own synced lyrics; on any failure (relay down, rate limit) fall back to LRCLIB
        var ytmError = false, ytmPlain = false
        if useYtm && !song.videoId.isEmpty && !LrclibRecheck.only {
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
        if coverCandidate, let original = try await fromOriginal(song, description) {
            if original.standIn { standIns.insert(Self.id(song)) }
            return original.standIn ? remember(key, original.lookup) : keep(key, song, original.lookup)
        }

        // 3) LRCLIB. A cover's own title can only match by title (the uploader isn't the original artist), which
        // picks songs that merely share the name: covers take artist matches only.
        let found = try await findSynced(withOriginalTitle(song), titleOnly: !CoverLyrics.mayBeCover(song))
        var result = found.lookup
        if case .notFound = result, ytmPlain { result = .plainOnly }
        // a "not found" is only final when YouTube Music (and Kugou / NetEase) answered too; otherwise ask again next time
        if result.isFound {
            if found.standIn { standIns.insert(Self.id(song)) }
            _ = found.standIn ? remember(key, result) : keep(key, song, result)
        }
        else if cacheMisses && !ytmError && !found.unsure { cache[key] = result }
        return result
    }

    private func remember(_ key: String, _ result: LyricsLookup) -> LyricsLookup { cache[key] = result; return result }

    /// A lookup's outcome. `unsure`: nothing was found and Kugou / NetEase couldn't be asked, so the miss isn't final.
    /// `standIn`: found on Kugou / NetEase only because LRCLIB rate-limited us (429); remembered for this run but not saved to
    /// disk, so the next run asks LRCLIB again (it may have the song).
    struct Synced {
        var lookup: LyricsLookup
        var unsure = false
        var standIn = false
    }

    /// Remembered for this run, and on disk when it came from LRCLIB, Kugou or NetEase.
    private func keep(_ key: String, _ song: Song, _ result: LyricsLookup) -> LyricsLookup {
        if Self.fromMore(result) { lrclibChecked[Self.id(song)] = Date(); standIns.remove(Self.id(song)) }   // LRCLIB just said it has none
        if LyricsDiskCache.keeps(result) { disk?.save(song, result) }
        return remember(key, result)
    }

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
    /// What prefetch has for the next song, without taking it (known does that when the song starts).
    func ahead(_ next: Song) -> LyricsLookup? { prefetched[next.videoId] ?? cache[Self.key(next)] }

    func prefetch(_ next: Song) async throws {
        if cache[Self.key(next)] != nil || prefetched[next.videoId] != nil { return }
        log("INFO fetching lyrics ahead for the next song: \(next.artist) - \(next.title)")
        let result = try await find(next, cacheMisses: false)
        if result.isFound {
            if prefetched.count > 20 { prefetched.removeAll() }
            prefetched[next.videoId] = result
        }
    }

    private static func fromMore(_ result: LyricsLookup) -> Bool {
        guard case .synced(_, let source) = result else { return false }
        return source.hasPrefix("Kugou") || source.hasPrefix("NetEase")
    }

    /// Whether LRCLIB should be asked again about lyrics found on Kugou / NetEase: a stand-in for a busy LRCLIB, or
    /// a song LRCLIB didn't have (it may have been added since), once per play but not again within a day in the
    /// same run (LRCLIB caches its answers for a day).
    func shouldRecheck(_ song: Song, _ result: LyricsLookup) -> Bool {
        guard Self.fromMore(result) else { return false }
        if standIns.contains(Self.id(song)) { return true }
        guard let at = lrclibChecked[Self.id(song)] else { return true }
        return Date().timeIntervalSince(at) > 24 * 3600
    }

    /// Ask LRCLIB (only) again about a song whose lyrics came from Kugou / NetEase. Returns LRCLIB's lyrics (kept, on
    /// disk too), or the lyrics already known when LRCLIB has none (a stand-in then becomes final and is saved), or
    /// nil when LRCLIB couldn't answer (busy): the known lyrics stay, ask again later. Throws only when cancelled.
    func recheck(_ song: Song) async throws -> LyricsLookup? {
        guard let known = known(song), Self.fromMore(known) else { return known(song) }
        let result: LyricsLookup
        do { result = try await LrclibRecheck.$only.withValue(true) { try await lookup(song, cacheMisses: false) } }
        catch {
            if Task.isCancelled { throw CancellationError() }
            log("INFO asking LRCLIB again failed (\(error.localizedDescription)), keeping the lyrics shown")
            return nil
        }
        lrclibChecked[Self.id(song)] = Date()
        if result.isFound {
            log("INFO LRCLIB has lyrics now (\(result.sourceName)), replacing \(known.sourceName): \(song.artist) - \(song.title)")
            standIns.remove(Self.id(song))
            return result
        }
        if standIns.contains(Self.id(song)) { _ = keep(Self.key(song), song, known) }
        log("INFO LRCLIB still has no lyrics, keeping \(known.sourceName): \(song.artist) - \(song.title)")
        return known
    }

    /// Drop the cached result for a song so the next find asks again.
    func forget(_ song: Song) {
        cache.removeValue(forKey: Self.key(song)); prefetched.removeValue(forKey: song.videoId); standIns.remove(Self.id(song))
        ytm.forget(song.videoId)
        disk?.forget(song.videoId)
    }

    /// Synced lyrics of the original song for a cover: follow the YouTube links in the cover's description, take
    /// the first linked video whose length is within a few seconds of the cover, and use its YouTube Music
    /// lyrics (or LRCLIB with the original's title/artist). Covers that say they are remixes/arrangements and
    /// candidates whose length differs are skipped, since the timing would drift. Nil = not usable.
    private func fromOriginal(_ song: Song, _ description: Task<VideoDescription?, Never>?) async throws -> Synced? {
        if CoverLyrics.looksArranged(song.title) || CoverLyrics.looksArranged(song.alternativeTitle) {
            log("INFO cover: title says arranged/remixed, original's lyrics not used: \(song.title)")
            return nil
        }
        do {
            let desc = await description?.value
            try Task.checkCancellation()
            let (ids, hinted) = CoverLyrics.originalCandidates(desc, ownId: song.videoId)
            if ids.isEmpty { log("INFO cover: no YouTube links in the description of \(song.videoId)") }
            // the original's YouTube Music lyrics need the relay; while it is down (paused or failing) the original
            // is still identified (music.youtube.com) and looked up on LRCLIB
            var ytmLyrics = useYtm && !ytm.paused
            var originalTooLong = false, used = false
            for id in ids {
                switch try await tryOriginal(id, song, desc, hinted: hinted.contains(id), ytmLyrics: &ytmLyrics) {
                case .skipped: continue
                case .tooLong: originalTooLong = true; continue
                case .used(let found): if let found { return found }; used = true
                }
                break   // the first usable link decides; don't wander through unrelated links
            }

            // No usable link: the original's video from YouTube's search for the song's name (official channels only,
            // and only when the results agree on the artist). Taken like a link that says it is the original.
            if !used && !originalTooLong, let hit = try await searchOriginal(song, desc) {
                switch try await tryOriginal(hit.videoId, song, desc, hinted: true, ytmLyrics: &ytmLyrics) {
                case .used(let found): if let found { return found }
                case .tooLong(let orig):
                    // its music video is longer than the recording: that artist's lyrics within the cover's length only
                    return try await fromSearch(song, desc, byArtist: true, original: orig)
                case .skipped: break
                }
            }

            // The original's video is known but its length doesn't fit (it often has an intro or outro the recording
            // doesn't). A title guess alone would find that video's song out of sync or another song of the same name,
            // so only an artist the description names may look it up: same artist, and a length within the cover's
            // tolerance. No lyrics beats wrong lyrics. Same as src/Lyrics.cs.
            if originalTooLong { return try await fromSearch(song, desc, byArtist: true) }
            // no usable link: work out the song from the title / description and look it up on LRCLIB
            return try await fromSearch(song, desc)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is LrclibFailed { throw error }   // LRCLIB busy: retried later, not cached
            log("WARN cover -> original lookup failed for \(song.title): \(error.localizedDescription)")
            return nil
        }
    }

    private enum OriginalOutcome { case skipped, tooLong(TrackInfo), used(Synced?) }

    /// One candidate for the cover's original (a description link, or a search result): skipped (no length, an
    /// arrangement, another song), too long or short for the cover, or used (its lyrics, or nil when it has none).
    private func tryOriginal(_ id: String, _ song: Song, _ desc: VideoDescription?, hinted: Bool, ytmLyrics: inout Bool) async throws -> OriginalOutcome {
        let orig: TrackInfo
        do { orig = try await ytm.lookup(id, withLyrics: ytmLyrics) }
        catch where ytmLyrics && !Task.isCancelled {
            log("WARN cover: original's YouTube Music lyrics failed (\(error.localizedDescription)), looking the original up without them")
            ytmLyrics = false
            orig = try await ytm.lookup(id, withLyrics: false)
        }
        let label = "\(id) (\(orig.artist) - \(orig.title), \(Int(orig.duration))s)"
        if orig.duration <= 0 { log("INFO cover: original candidate \(id) has no known length, skipped"); return .skipped }
        if CoverLyrics.looksArranged(orig.title) { log("INFO cover: candidate \(label) is an arrangement, skipped"); return .skipped }
        // links without an "原曲 / original" label are often the singer's other videos: the title must fit
        if !hinted && !CoverLyrics.titleMatchesCover(song, orig) { log("INFO cover: candidate \(label) is a different song, skipped"); return .skipped }
        let diff = abs(orig.duration - song.duration)
        if diff > CoverLyrics.maxLengthDiff { log("INFO cover: candidate \(label) differs from the cover by \(Int(diff))s, skipped"); return .tooLong(orig) }
        if !orig.lines.isEmpty {
            log("INFO lyrics found via original \(label) on YouTube Music: \(song.artist) - \(song.title)")
            return .used(Synced(lookup: .synced(orig.lines, source: "YouTube Music · 원곡")))
        }
        if ytmLyrics {
            // the link is usually the original's music video; its official audio track has the timed lyrics
            // the cover may call it differently ("帝国少女" for "Imperial Girl")
            let coverName = CoverLyrics.guessOriginal(song, description: desc?.text).title
            if let audio = try await audioTrackLyrics(orig, otherNames: [coverName]) {
                log("INFO lyrics found via original \(label)'s official audio on YouTube Music: \(song.artist) - \(song.title)")
                return .used(Synced(lookup: .synced(audio, source: "YouTube Music · 원곡")))
            }
        }
        if !orig.title.isEmpty {
            // "ビノミ - Binomi": also try the title without the romanized/translated half
            let primary = CoverLyrics.primaryTitle(orig.title, artist: orig.artist, coverArtist: CoverLyrics.guessOriginal(song, description: desc?.text).artist)
            // artist names in the title count too (as tags: they vouch for results with this title)
            var original = Song(title: orig.title, alternativeTitle: primary != orig.title ? primary : "", artist: orig.artist, videoId: id, duration: orig.duration)
            original.tags = CoverLyrics.artistsInTitle(orig.title, songName: primary)
            let l = try await lrclibFind(original)
            if case .synced(let lines, let source) = l.lookup {
                log("INFO lyrics found via original \(label) on \(source): \(song.artist) - \(song.title)")
                return .used(Synced(lookup: .synced(lines, source: source + " · 원곡"), standIn: l.standIn))
            }
        }
        log("INFO cover: original \(label) has no synced lyrics under that name")
        return .used(nil)
    }

    /// The cover's original found by searching YouTube for the song's name (CoverLyrics.pickOriginal), or nil.
    private func searchOriginal(_ song: Song, _ desc: VideoDescription?) async throws -> SearchHit? {
        let name = CoverLyrics.guessOriginal(song, description: desc?.text).title
        if name.isEmpty { return nil }
        do {
            let hits = try await ytm.search(name)
            let hit = CoverLyrics.pickOriginal(hits, songName: name, cover: song)
            log("INFO cover: YouTube search for the original \"\(name)\": " + (hit.map { "\($0.videoId) (\($0.owner) - \($0.title), \(Int($0.length))s)" } ?? "no sure original among \(hits.count) results"))
            return hit
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log("INFO cover: YouTube search for the original failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// No usable link: read the song title (and original artist, if given) from the cover's title or description
    /// and look the original up on LRCLIB. (YouTube Music's own search doesn't list songs without signing in,
    /// so it can't be used for this.) The original must be within a few seconds of the cover's length.
    /// `byArtist`: only an original artist named by the title or description, and only results by that artist within
    /// the cover's length tolerance (the linked original didn't fit).
    /// `original`: the original's video found by search but longer or shorter than the cover: its artist (and the
    /// artists its title names) instead of one the description names.
    private func fromSearch(_ song: Song, _ desc: VideoDescription?, byArtist: Bool = false, original: TrackInfo? = nil) async throws -> Synced? {
        var (title, artist) = CoverLyrics.guessOriginal(song, description: desc?.text)
        var tags: [String] = []
        if let original {
            let primary = CoverLyrics.primaryTitle(original.title, artist: original.artist)
            if title.isEmpty { title = primary }
            artist = original.artist
            tags = CoverLyrics.artistsInTitle(original.title, songName: primary)
        }
        if title.isEmpty { log("INFO cover: couldn't tell the song title from \"\(song.title)\""); return nil }
        if byArtist && artist.isEmpty {
            log("INFO cover: the original differs in length and no artist is named, no lyrics rather than a title guess: \(song.title)")
            return nil
        }
        log("INFO cover: looking up the original on LRCLIB: \"\(title)\"" + (artist.isEmpty ? " (artist unknown)" : " by \"\(artist)\"")
            + (byArtist ? ", that artist only" : ""))
        // With the original artist named, another singer's lyrics only count when they are the well-known version (the
        // same timing uploaded at least 3 times): one cover of the song is no proof (Bad Apple!!: the PV's lyrics, not
        // FalKKonE's or an English cover's).
        var wanted = Song(title: title, artist: artist, videoId: song.videoId + "#original", duration: song.duration)
        wanted.tags = tags
        let l = try await lrclibFind(wanted,
                                     titleTolerance: CoverLyrics.maxLengthDiff, titleOnly: !byArtist,
                                     artistTolerance: byArtist ? CoverLyrics.maxLengthDiff : 15, titleCopies: artist.isEmpty ? 1 : 3)
        guard case .synced(let lines, let source) = l.lookup else { return nil }
        log("INFO lyrics found via original \"\(title)\" on \(source): \(song.artist) - \(song.title)")
        return Synced(lookup: .synced(lines, source: source + " · 원곡 검색"), standIn: l.standIn)
    }

    /// An album track whose title Pear gives only translated or romanized ("kanade tomosu sora nekobolo version") is
    /// also searched under its original title, which YouTube Music's lookup already brought ("カナデトモスソラ　ねこぼーろver."):
    /// LRCLIB mostly lists songs under their original titles. Same as src/Lyrics.cs.
    private func withOriginalTitle(_ song: Song) -> Song {
        guard song.mediaType == "AUDIO", let track = ytm.known(song.videoId),
              let original = CoverLyrics.originalTitle(song.title, queueTitle: track.title) else { return song }
        var copy = song; copy.alternativeTitle = original
        return copy
    }

    /// LRCLIB, then (when it has no synced lyrics or is busy) Kugou and NetEase. Their catalogs are bigger and looser,
    /// so a title-only match there needs the exact title and length (`titleTolerance` up to 3s, and no "several identical
    /// uploads" rule to lean on): with a wider tolerance or that rule, artist matches only. Throws LRCLIB's error when
    /// nothing was found and LRCLIB failed. Same as FindSynced in src/Lyrics.cs.
    private func findSynced(_ song: Song, titleTolerance: Double = 3, titleOnly: Bool = true, artistTolerance: Double = 15,
                            titleCopies: Int = 1) async throws -> Synced {
        var result: LyricsLookup = .notFound
        var lrclibError: Error?
        do { result = try await lrclib.find(song, titleTolerance: titleTolerance, titleOnly: titleOnly, artistTolerance: artistTolerance, titleCopies: titleCopies) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            lrclibError = error
        }
        if result.isFound { return Synced(lookup: result) }
        // Kugou / NetEase only when LRCLIB has nothing, or rate-limits us (429); when it is busy (503 …) it is
        // asked again instead, as soon as its Retry-After allows (user's choice: LRCLIB first)
        let rateLimited = lrclibError.map { ($0 as NSError).domain == "LRCLIB" && ($0 as NSError).code == 429 } ?? false
        guard let more, useMore, !LrclibRecheck.only, lrclibError == nil || rateLimited else {
            if let lrclibError { throw lrclibError }
            return Synced(lookup: result)
        }
        let m = try await more.find(song, titleTolerance: titleOnly && titleCopies <= 1 && titleTolerance <= 3 ? titleTolerance : -1,
                                    artistTolerance: artistTolerance)
        if case .found(let lines, let source) = m { return Synced(lookup: .synced(lines, source: source), standIn: lrclibError != nil) }
        if let lrclibError { throw lrclibError }   // LRCLIB rate-limited: retried later
        if case .failed = m { return Synced(lookup: result, unsure: true) }
        return Synced(lookup: result)
    }

    /// findSynced for a cover's original: a failure ends the whole lookup (LrclibFailed) so it is retried later.
    private func lrclibFind(_ song: Song, titleTolerance: Double = 3, titleOnly: Bool = true, artistTolerance: Double = 15, titleCopies: Int = 1) async throws -> Synced {
        do { return try await findSynced(song, titleTolerance: titleTolerance, titleOnly: titleOnly, artistTolerance: artistTolerance, titleCopies: titleCopies) }
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
