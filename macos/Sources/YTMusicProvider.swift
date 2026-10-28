import Foundation

struct TrackInfo {
    var videoId = "", title = "", artist = ""
    /// YouTube Music artist page of the video's artist (UC…), when the response links one.
    var artistId = ""
    /// MUSIC_VIDEO_TYPE_ATV (official audio), _OMV (official video), _UGC …
    var videoType = ""
    var duration: Double = 0
    /// The largest cover / thumbnail of the queue entry (the browser source's album art).
    var thumbnail = ""
    /// A playlist entry's other version (the official audio of a music video entry), from its watch parameters.
    var counterpartId = ""
    var lines: [LyricLine] = []
    /// YouTube Music has lyrics for it, but without times.
    var plainOnly = false
}

/// A video in YouTube's search results. `official`: an official artist channel (verified artist badge) or an
/// artist's "- Topic" channel (official audio).
struct SearchHit: Equatable {
    var videoId = "", title = "", owner = ""
    var length: Double = 0
    var official = false
}

struct VideoDescription {
    var text = ""
    var linkedIds: [String] = []
}

/// YouTube Music's own time-synced lyrics, fetched the same way as Pear Desktop's "YTMusic" lyrics provider
/// (src/plugins/synced-lyrics/providers/YTMusic.ts) and the Windows version (src/YtmLyrics.cs):
///   1. /youtubei/v1/next for the video -> the lyrics tab's browseId
///   2. /browse for that browseId as the YouTube Music mobile client (26 / 7.01.05) through Pear's relay
///      (ytmbrowseproxy.zvz.be). Anonymous direct browse returns no lyrics, which is why Pear uses the relay.
///      In practice timed lines come back for official audio tracks; MVs and uploads get "not available".
/// No Google account cookies or Pear tokens are sent. The relay is a third-party service, so after repeated
/// failures it is skipped for a while and lookups go straight to LRCLIB.
@MainActor final class YTMusicProvider {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    nonisolated static let defaultProxy = "https://ytmbrowseproxy.zvz.be/"
    private static func datedVersion(_ prefix: String, _ suffix: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd"
        return prefix + f.string(from: Date().addingTimeInterval(-2 * 86400)) + suffix
    }
    /// WEB_REMIX versions are dated builds ("1.YYYYMMDD.01.00"); a recent date is what the web app sends.
    static var webRemixVersion: String { datedVersion("1.", ".01.00") }
    static var webVersion: String { datedVersion("2.", ".00.00") }

    var musicBase = "https://music.youtube.com/"
    var youtubeBase = "https://www.youtube.com/"
    var proxyBase = defaultProxy

    private let session: URLSession
    private let transport: Transport?
    private let log: (String) -> Void
    private var consecutiveFailures = 0
    private var skipUntil = Date.distantPast
    static let failuresBeforeSkip = 3
    static let skipFor: TimeInterval = 600

    init(transport: Transport? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.log = log
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 12
        // redirects are followed by hand: a 301/302 would otherwise turn the POST into a GET
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// True while the relay is being skipped after repeated failures.
    var paused: Bool { Date() < skipUntil }
    func resetPause() { skipUntil = .distantPast; consecutiveFailures = 0 }

    // Answers from YouTube for this session, so retries (LRCLIB busy) and the next lookups of the same
    // originals don't ask again. Failed requests are not remembered.
    private var lookups: [String: TrackInfo] = [:]
    private var audioTracks: [String: String?] = [:]
    private var descriptions: [String: VideoDescription] = [:]
    private var artistPages: [String: Any] = [:]
    private var fullDiscographies: [String: [(id: String, title: String)]] = [:]

    private func remember<T>(_ memo: inout [String: T], _ key: String, _ value: T) {
        if memo.count > 300 { memo.removeAll() }
        memo[key] = value
    }

    /// Drop what is known about one video, for a manual "find lyrics again".
    func forget(_ videoId: String) {
        lookups.removeValue(forKey: videoId + "|L"); lookups.removeValue(forKey: videoId + "|M")
    }

    /// Lyrics plus the track's title/artist/length as YouTube Music lists it. Throws when the servers can't be
    /// reached or answer with an error; counts towards the relay's pause.
    /// What a lookup earlier in this session learned about the video (no request), or nil.
    func known(_ videoId: String) -> TrackInfo? { lookups[videoId + "|L"] ?? lookups[videoId + "|M"] }

    func lookup(_ videoId: String, withLyrics: Bool = true) async throws -> TrackInfo {
        if let known = lookups[videoId + (withLyrics ? "|L" : "|M")] { return known }
        if !withLyrics, let known = lookups[videoId + "|L"] { return known }
        do {
            var info = TrackInfo(videoId: videoId)
            try await findCore(&info, withLyrics: withLyrics)
            consecutiveFailures = 0
            remember(&lookups, videoId + (withLyrics ? "|L" : "|M"), info)
            return info
        } catch {
            if Task.isCancelled { throw CancellationError() }
            consecutiveFailures += 1
            if consecutiveFailures >= Self.failuresBeforeSkip {
                skipUntil = Date().addingTimeInterval(Self.skipFor); consecutiveFailures = 0
                log("WARN YouTube Music lyrics failed \(Self.failuresBeforeSkip) times in a row; using LRCLIB only for \(Int(Self.skipFor / 60)) minutes")
            }
            throw error
        }
    }

    private func findCore(_ info: inout TrackInfo, withLyrics: Bool) async throws {
        // 1) watch-next page of the video: find the lyrics tab
        let next = try await post(musicBase.trimmed("/") + "/youtubei/v1/next?prettyPrint=false",
                                  body: ["videoId": info.videoId, "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion]]], label: "next")
        Self.readQueueEntry(next, into: &info)
        if !withLyrics { return }   // only the title/artist/length were wanted
        guard let browseId = Self.lyricsBrowseID(in: next) else {
            log("INFO YouTube Music: no lyrics tab for video \(info.videoId) -> LRCLIB")   // user uploads, covers, MVs …
            return
        }
        // 2) the lyrics page as the mobile client (same request body as Pear). Asking music.youtube.com directly
        // (anonymously) has always answered "Lyrics not available at this time.", so go straight to Pear's relay.
        let body: [String: Any] = ["browseId": browseId, "context": ["client": ["clientName": "26", "clientVersion": "7.01.05"]]]
        let relayed = try await post(proxyBase.trimmed("/") + "/browse?prettyPrint=false", body: body, label: "relay browse")
        switch Self.parse(relayed) {
        case .synced(let lines, _): info.lines = lines
        case .plainOnly: info.plainOnly = true; log("INFO YouTube Music relay browse \(info.videoId): plain lyrics only")
        default: log("INFO YouTube Music relay browse \(info.videoId): no timed lines (\(Self.describe(relayed)))")
        }
    }

    /// Short summary of a /browse answer for the log: what kind of lyrics (if any) it carried.
    static func describe(_ response: [String: Any]) -> String {
        guard let contents = response["contents"] else { return "no contents [" + response.keys.prefix(6).joined(separator: ",") + "]" }
        if let model = find("musicMessageModel", in: contents) as? [String: Any] { return "message: " + (model["text"] as? String ?? "?") }
        if let message = find("messageRenderer", in: contents) as? [String: Any], !runs(message["text"]).isEmpty { return "message: " + runs(message["text"]) }
        return "contents [" + ((contents as? [String: Any])?.keys.prefix(6).joined(separator: ",") ?? "?") + "]"
    }

    /// Title, artist and length of the video from the "up next" queue entry YouTube Music returns for it.
    static func readQueueEntry(_ next: Any, into info: inout TrackInfo) {
        let videoId = info.videoId
        guard let r = findWhere("playlistPanelVideoRenderer", in: next, { ($0 as? [String: Any])?["videoId"] as? String == videoId }) else { return }
        info.title = runs(path(r, "title"))
        let byline = path(r, "shortBylineText") ?? path(r, "longBylineText")
        for run in path(byline, "runs") as? [Any] ?? [] {
            if let t = path(run, "text") as? String, !t.trimmed.isEmpty { info.artist = t.trimmed; break }
        }
        info.duration = parseClock(runs(path(r, "lengthText")))
        info.videoType = find("musicVideoType", in: r) as? String ?? ""
        info.thumbnail = coverURL(path(path(r, "thumbnail"), "thumbnails") as? [Any] ?? [])
        let artist = findWhere("browseEndpoint", in: next) { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }
        info.artistId = path(artist, "browseId") as? String ?? ""
    }

    /// The song after `videoId` in a playlist (an album, a playlist; the browser source's guess at the next song,
    /// as the browser's own queue can't be read). Nil when it is the last one or not in the list. The list is
    /// remembered for this session, so going through an album asks once.
    func queueAfter(_ videoId: String, playlist: String) async throws -> TrackInfo? {
        let entries = try await playlistEntries(videoId, playlist: playlist, ending: true)
        guard let index = entries.firstIndex(where: { $0.videoId == videoId || $0.counterpartId == videoId }), index + 1 < entries.count else { return nil }
        // the web player plays an album's official audio where the list names its music video: the next song in
        // the same kind (its details from the queue entry YouTube Music gives for it, as for the song playing)
        let next = entries[index + 1]
        let nextId = entries[index].counterpartId == videoId && !next.counterpartId.isEmpty ? next.counterpartId : next.videoId
        return try await lookup(nextId, withLyrics: false)
    }
    /// The songs of a playlist as YouTube Music's queue panel lists them around `videoId`. Asked again when the
    /// video isn't in the remembered list (or, with `ending`, is its last entry: the panel shows a window of it).
    func playlistEntries(_ videoId: String, playlist: String, ending: Bool = false) async throws -> [TrackInfo] {
        if let known = queues[playlist], (ending ? known.dropLast() : known[...]).contains(where: { $0.videoId == videoId || $0.counterpartId == videoId }) { return known }
        let next = try await post(musicBase.trimmed("/") + "/youtubei/v1/next?prettyPrint=false",
                                  body: ["videoId": videoId, "playlistId": playlist, "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion]]], label: "queue")
        let entries = Self.queueEntries(next)
        remember(&queues, playlist, entries)
        return entries
    }
    private var queues: [String: [TrackInfo]] = [:]

    /// The queue panel's songs in order (the album version of each, not its music video counterpart).
    static func queueEntries(_ next: Any) -> [TrackInfo] {
        var found: [TrackInfo] = []
        for item in path(find("playlistPanelRenderer", in: next), "contents") as? [Any] ?? [] {
            guard let r = path(item, "playlistPanelVideoRenderer") ?? path(item, "playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"),
                  let id = path(r, "videoId") as? String else { continue }
            var info = TrackInfo(videoId: id)
            readQueueEntry(["r": ["playlistPanelVideoRenderer": r]], into: &info)
            info.counterpartId = counterpart(path(r, "navigationEndpoint", "watchEndpoint", "params") as? String ?? "") ?? ""
            found.append(info)
        }
        return found
    }

    /// The video ID inside a playlist entry's watch parameters (base64 protobuf; a length byte 11 and the ID):
    /// an album entry that is a music video carries its official audio this way.
    static func counterpart(_ params: String) -> String? {
        var b64 = (params.removingPercentEncoding ?? params).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        let bytes = [UInt8](data)
        for i in bytes.indices where bytes[i] == 11 && i + 11 < bytes.count {
            let id = String(decoding: bytes[(i + 1)...(i + 11)], as: UTF8.self)
            if BrowserSource.isVideoId(id) { return id }
        }
        return nil
    }

    /// YouTube's search results for a query (first page, videos only), remembered for this session. Used to find a
    /// cover's original (LyricsFinder) and a browser song's video (findVideo).
    func search(_ query: String) async throws -> [SearchHit] {
        if let known = searchResults[query] { return known }
        let body: [String: Any] = ["query": query, "context": ["client": ["clientName": "WEB", "clientVersion": Self.webVersion, "hl": "ja"]]]
        let hits = Self.searchHits(try await post(youtubeBase.trimmed("/") + "/youtubei/v1/search?prettyPrint=false", body: body, label: "search"))
        remember(&searchResults, query, hits)
        return hits
    }
    private var searchResults: [String: [SearchHit]] = [:]

    /// The videos of a search response, in order.
    static func searchHits(_ response: Any) -> [SearchHit] {
        var hits: [SearchHit] = []
        for section in path(find("sectionListRenderer", in: response), "contents") as? [Any] ?? [] {
            for item in path(section, "itemSectionRenderer", "contents") as? [Any] ?? [] {
                guard let r = path(item, "videoRenderer"), let id = path(r, "videoId") as? String else { continue }
                let owner = runs(path(r, "ownerText"))
                let badges = path(r, "ownerBadges") as? [Any] ?? []
                hits.append(SearchHit(videoId: id, title: runs(path(r, "title")), owner: owner, length: parseClock(runs(path(r, "lengthText"))),
                                      official: owner.hasSuffix(" - Topic") || badges.contains { path($0, "metadataBadgeRenderer", "style") as? String == "BADGE_STYLE_TYPE_VERIFIED_ARTIST" }))
            }
        }
        return hits
    }

    /// A video for a song known only by its title, artist and length (the browser source when the tab's address
    /// can't be read): YouTube's search for "artist title", picked by pickVideo. Nil when none is that sure.
    func findVideo(title: String, artist: String, duration: Double) async throws -> String? {
        guard !title.trimmed.isEmpty, duration > 0 else { return nil }
        let query = (artist.trimmed.isEmpty ? "" : artist + " ") + title
        let found = Self.pickVideo(try await search(query), title: title, artist: artist, duration: duration)
        log("INFO YouTube search for \(artist) - \(title) (\(Int(duration))s): \(found ?? "no video of that length and title")")
        return found
    }

    /// The search result that is this song, in order: as long as the song (±2 s) and titled exactly like it (a
    /// cover's own upload); or from the artist's channel, or an official artist / "- Topic" channel, and naming the
    /// song ("YOASOBI「ハルジオン」Official Music Video" for "ハルジオン (Halzion)"). Failing those, the one official
    /// result within a second of the length: the browser may name the artist and song in the player's language
    /// ("요아소비", "Idol"), which the video's title doesn't use. Fan uploads of the same length are never taken.
    /// Same as YtmLyrics.PickVideo in src/YtmLyrics.cs.
    static func pickVideo(_ hits: [SearchHit], title: String, artist: String, duration: Double) -> String? {
        let wanted = CoverLyrics.norm(title)
        let names = CoverLyrics.titleNames(title, artist: artist).map(CoverLyrics.norm).filter { $0.count >= 2 }
        let singer = CoverLyrics.norm(artist)
        var official: [String] = []
        for h in hits where h.length > 0 && abs(h.length - duration) <= 2 {
            let t = CoverLyrics.norm(h.title)
            if !wanted.isEmpty && t == wanted { return h.videoId }
            let ownerName = CoverLyrics.norm(h.owner.replacingOccurrences(of: " - Topic", with: ""))
            let byArtist = !singer.isEmpty && !ownerName.isEmpty && (ownerName.contains(singer) || singer.contains(ownerName))
            if (byArtist || h.official) && names.contains(where: { t.contains($0) }) { return h.videoId }
            if h.official && abs(h.length - duration) <= 1 { official.append(h.videoId) }
        }
        return official.count == 1 ? official[0] : nil
    }

    /// The largest of a renderer's thumbnails; album covers (lh3.googleusercontent.com, "=w60-h60-…") are asked
    /// for at 544 px, the size Pear's album art comes in.
    static func coverURL(_ thumbnails: [Any]) -> String {
        let best = thumbnails.max { ((path($0, "width") as? NSNumber)?.intValue ?? 0) < ((path($1, "width") as? NSNumber)?.intValue ?? 0) }
        guard let url = path(best, "url") as? String, url.hasPrefix("https://") else { return "" }
        if url.contains("googleusercontent.com/"), let range = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return url.replacingCharacters(in: range, with: "=w544-h544")
        }
        return url
    }

    // ---- official audio track for a music video (MV -> artist page -> single/album -> track) -------------

    /// YouTube Music only returns timed lyrics for official audio tracks, not for music videos, and without
    /// signing in it doesn't link a video to its audio track. So: open the artist's page, take the singles/albums
    /// named like the song, and pick the track with the same title and (nearly) the same length.
    /// Returns the audio track's video ID, or nil. `otherNames`: more names the song may go by (e.g. a cover's).
    func findAudioTrack(_ video: TrackInfo, otherNames: [String] = []) async throws -> String? {
        if video.artistId.isEmpty || video.title.isEmpty || video.duration <= 0 { return nil }
        let key = ([video.videoId] + otherNames).joined(separator: "|")
        if let known = audioTracks[key] { return known }
        let found = try await findAudioTrackCore(video, otherNames)
        remember(&audioTracks, key, found)
        return found
    }

    private func findAudioTrackCore(_ video: TrackInfo, _ otherNames: [String]) async throws -> String? {
        // the song's names: no 【tags】 / artist part / "covered by …"; Japanese and English halves both tried
        // ("サイエンス - Science" may be released as either)
        let names = CoverLyrics.titleNames(video.title, artist: video.artist, extra: otherNames)
        if names.isEmpty { return nil }
        let title = names.joined(separator: " / ")
        func named(_ t: String) -> Bool { names.contains { CoverLyrics.sameTitle(t, $0) || CoverLyrics.sameTitle(CoverLyrics.primaryTitle(t), $0) } }
        let browseURL = musicBase.trimmed("/") + "/youtubei/v1/browse?prettyPrint=false"
        let artistPage: Any
        if let known = artistPages[video.artistId] { artistPage = known }
        else { artistPage = try await post(browseURL, body: browseBody(video.artistId), label: "artist page"); remember(&artistPages, video.artistId, artistPage) }
        var releases: [(id: String, title: String)] = []
        Self.collectReleases(artistPage, into: &releases)
        // the closest titles first: "メズマライザー" before "Mesmerizer (Official English Version)", the page's order otherwise
        func namedReleases() -> [(id: String, title: String)] {
            releases.enumerated().filter { !CoverLyrics.looksArranged($0.element.title) && named($0.element.title) }
                .map { (CoverLyrics.titleCloseness($0.element.title, names), $0.offset, $0.element) }
                .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
        func match() -> [String] { Array(namedReleases().map(\.id).uniqued().prefix(2)) }
        var matching = match()

        // The artist page only shows the latest releases; "show all" (full singles / albums lists) has the rest. Also
        // looked at when only a different version is on the artist page (a newer English version, the original older).
        if matching.isEmpty || namedReleases().allSatisfy({ CoverLyrics.titleCloseness($0.title, names) > 0 }) {
            var all: [(id: String, title: String)]
            if let known = fullDiscographies[video.artistId] { all = known }
            else {
                all = []
                var more: [(id: String, params: String)] = []
                Self.collectDiscographyLinks(artistPage, into: &more)
                var seen = Set<String>()
                for link in more where seen.count < 2 && seen.insert(link.id + "|" + link.params).inserted {
                    Self.collectReleases(try await post(browseURL, body: browseBody(link.id, params: link.params), label: "discography"), into: &all)
                }
                remember(&fullDiscographies, video.artistId, all)
            }
            releases += all
            matching = match()
        }
        if matching.isEmpty {
            log("INFO YouTube Music: no single/album named \"\(title)\" by this artist (\(releases.map(\.id).uniqued().count) releases)")
            return nil
        }
        // the closest track: one named exactly ends the search, otherwise the closest of the releases looked at
        var best: (id: String, title: String, length: Double, closeness: Int)?
        for album in matching where best?.closeness != 0 {
            let page = try await post(browseURL, body: browseBody(album), label: "album page")
            var tracks: [Any] = []
            Self.collectAll("musicResponsiveListItemRenderer", in: page, into: &tracks)
            for t in tracks {
                guard let id = Self.path(t, "playlistItemData", "videoId") as? String, !id.isEmpty else { continue }
                let trackTitle = (Self.path(t, "flexColumns") as? [Any])?.first.map { Self.runs(Self.path($0, "musicResponsiveListItemFlexColumnRenderer", "text")) } ?? ""
                var length: Double = 0
                for c in Self.path(t, "fixedColumns") as? [Any] ?? [] {
                    length = Self.parseClock(Self.runs(Self.path(c, "musicResponsiveListItemFixedColumnRenderer", "text"))); if length > 0 { break }
                }
                if !named(trackTitle) { continue }
                if length > 0 && abs(length - video.duration) > 5 { continue }
                let closeness = CoverLyrics.titleCloseness(trackTitle, names)
                if closeness >= best?.closeness ?? .max { continue }
                best = (id, trackTitle, length, closeness)
                if closeness == 0 { break }
            }
        }
        if let best {
            log("INFO YouTube Music: official audio for \(video.videoId) (\(video.title)) is \(best.id) (\(best.title), \(Int(best.length))s)")
            return best.id
        }
        log("INFO YouTube Music: no track \"\(title)\" of about \(Int(video.duration))s in \(matching.joined(separator: ", "))")
        return nil
    }

    private func browseBody(_ browseId: String, params: String = "") -> [String: Any] {
        // hl=ja: Japanese titles, as in the songs
        var body: [String: Any] = ["browseId": browseId, "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion, "hl": "ja"]]]
        if !params.isEmpty { body["params"] = params }
        return body
    }

    /// "Show all" links of the artist page's album / single shelves (browseId + params).
    static func collectDiscographyLinks(_ node: Any, into found: inout [(id: String, params: String)], depth: Int = 0) {
        guard depth <= 60 else { return }
        if let d = node as? [String: Any] {
            if let be = d["browseEndpoint"], pageType(be) == "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY", let id = path(be, "browseId") as? String, !id.isEmpty {
                found.append((id, path(be, "params") as? String ?? ""))
            }
            for v in d.values { collectDiscographyLinks(v, into: &found, depth: depth + 1) }
        } else if let list = node as? [Any] { for v in list { collectDiscographyLinks(v, into: &found, depth: depth + 1) } }
    }

    static func collectReleases(_ node: Any, into found: inout [(id: String, title: String)], depth: Int = 0) {
        guard depth <= 60 else { return }
        if let d = node as? [String: Any] {
            if let item = d["musicTwoRowItemRenderer"] {
                let be = path(item, "navigationEndpoint", "browseEndpoint")
                if pageType(be) == "MUSIC_PAGE_TYPE_ALBUM", let id = path(be, "browseId") as? String, !id.isEmpty { found.append((id, runs(path(item, "title")))) }
            }
            for v in d.values { collectReleases(v, into: &found, depth: depth + 1) }
        } else if let list = node as? [Any] { for v in list { collectReleases(v, into: &found, depth: depth + 1) } }
    }

    static func collectAll(_ key: String, in node: Any, into found: inout [Any], depth: Int = 0) {
        guard depth <= 60 else { return }
        if let d = node as? [String: Any] {
            if let v = d[key] { found.append(v) }
            for c in d.values { collectAll(key, in: c, into: &found, depth: depth + 1) }
        } else if let list = node as? [Any] { for c in list { collectAll(key, in: c, into: &found, depth: depth + 1) } }
    }

    // ---- video description (www.youtube.com) ---------------------------------------------------

    /// The video's description text, plus the video IDs its links point to (YouTube shortens long links in
    /// the visible text, so linked IDs are collected separately). Nil when it can't be read.
    func description(_ videoId: String) async throws -> VideoDescription? {
        if let known = descriptions[videoId] { return known }
        guard let d = try await descriptionCore(videoId) else { return nil }
        remember(&descriptions, videoId, d)
        return d
    }

    private func descriptionCore(_ videoId: String) async throws -> VideoDescription? {
        let body: [String: Any] = ["videoId": videoId, "context": ["client": ["clientName": "WEB", "clientVersion": Self.webVersion]]]
        // the player response carries the full description as plain text
        do {
            let player = try await post(youtubeBase.trimmed("/") + "/youtubei/v1/player?prettyPrint=false", body: body, label: "player")
            if let text = Self.path(player, "videoDetails", "shortDescription") as? String, !text.isEmpty { return VideoDescription(text: text) }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log("INFO YouTube player (description) failed: \(error.localizedDescription), trying the watch page")
        }
        // otherwise the watch-next page: description text + the videos its links point to
        let next = try await post(youtubeBase.trimmed("/") + "/youtubei/v1/next?prettyPrint=false", body: body, label: "watch next")
        let desc = Self.find("attributedDescriptionBodyText", in: next) ?? Self.find("attributedDescription", in: next)
        var d = VideoDescription(text: Self.path(desc, "content") as? String ?? "")
        if let desc { Self.collectWatchIds(desc, into: &d.linkedIds) }
        return d.text.isEmpty && d.linkedIds.isEmpty ? nil : d
    }

    static func collectWatchIds(_ node: Any, into ids: inout [String], depth: Int = 0) {
        guard depth <= 30 else { return }
        if let d = node as? [String: Any] {
            if let id = path(d["watchEndpoint"], "videoId") as? String, !id.isEmpty, !ids.contains(id) { ids.append(id) }
            for v in d.values { collectWatchIds(v, into: &ids, depth: depth + 1) }
        } else if let list = node as? [Any] { for v in list { collectWatchIds(v, into: &ids, depth: depth + 1) } }
    }

    // ---- response helpers -----------------------------------------------------------------------

    /// Timed lines from a /browse response; plain lyrics and "not available" are told apart for the status line.
    static func parse(_ response: [String: Any]) -> LyricsLookup {
        guard let contents = response["contents"] else { return .notFound }
        if let data = find("timedLyricsData", in: contents) as? [[String: Any]], !data.isEmpty {
            var lines: [(Double, String)] = []
            for row in data {
                guard let cue = row["cueRange"] as? [String: Any],
                      let milliseconds = Double(String(describing: cue["startTimeMilliseconds"] ?? "")), milliseconds.isFinite else { continue }
                let text = (row["lyricLine"] as? String ?? "").trimmed
                lines.append((max(0, milliseconds / 1000), text.isEmpty ? "♪" : text))
            }
            if !lines.isEmpty {
                return .synced(lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }, source: "YouTube Music")
            }
            if data.contains(where: { !(($0["lyricLine"] as? String) ?? "").isEmpty }) { return .plainOnly }
        }
        if let shelf = find("musicDescriptionShelfRenderer", in: contents) as? [String: Any], !runs(shelf["description"]).trimmed.isEmpty { return .plainOnly }
        return .notFound
    }

    /// The lyrics tab's browseId, wherever it sits in the watch-next response.
    static func lyricsBrowseID(in object: Any) -> String? {
        path(findWhere("browseEndpoint", in: object) { pageType($0) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" }, "browseId") as? String
    }

    static func pageType(_ browseEndpoint: Any?) -> String? {
        path(browseEndpoint, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") as? String
    }

    static func find(_ key: String, in object: Any) -> Any? { findWhere(key, in: object) { _ in true } }

    static func findWhere(_ key: String, in object: Any, depth: Int = 0, _ match: (Any) -> Bool) -> Any? {
        guard depth <= 40 else { return nil }
        if let dict = object as? [String: Any] {
            if let value = dict[key], match(value) { return value }
            for value in dict.values { if let hit = findWhere(key, in: value, depth: depth + 1, match) { return hit } }
        } else if let values = object as? [Any] {
            for value in values { if let hit = findWhere(key, in: value, depth: depth + 1, match) { return hit } }
        }
        return nil
    }

    static func path(_ node: Any?, _ keys: String...) -> Any? {
        var node = node
        for k in keys { guard let d = node as? [String: Any] else { return nil }; node = d[k] }
        return node
    }

    static func runs(_ textNode: Any?) -> String {
        if let simple = path(textNode, "simpleText") as? String { return simple }
        return (path(textNode, "runs") as? [Any] ?? []).map { path($0, "text") as? String ?? "" }.joined()
    }

    /// "4:51" / "1:02:03" -> seconds (0 when unreadable).
    static func parseClock(_ text: String) -> Double {
        let t = text.trimmed
        if t.isEmpty { return 0 }
        var total: Double = 0
        for part in t.components(separatedBy: ":") { guard let v = Int(part) else { return 0 }; total = total * 60 + Double(v) }
        return total
    }

    private func post(_ url: String, body: [String: Any], label: String) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var url = url
        for _ in 0..<4 {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"; request.timeoutInterval = 12; request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("NowPlayingWidget-macOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
            request.httpBody = payload
            let data: Data, response: HTTPURLResponse
            if let transport { (data, response) = try await transport(request) }
            else {
                let result = try await session.data(for: request)
                guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                (data, response) = (result.0, http)
            }
            try Task.checkCancellation()
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: URL(string: url)) {
                url = next.absoluteString
                continue   // re-send the same POST to the new address
            }
            guard (200...299).contains(response.statusCode) else {
                throw NSError(domain: "YTMusic", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "YouTube Music \(label) \(response.statusCode)"])
            }
            // big pages (artist, album) are parsed off the main thread
            let parsed = try await Task.detached { try JSONSerialization.jsonObject(with: data) as? [String: Any] }.value
            guard let parsed else { throw URLError(.cannotParseResponse) }
            return parsed
        }
        throw URLError(.httpTooManyRedirects)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
