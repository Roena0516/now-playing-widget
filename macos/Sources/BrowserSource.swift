import AppKit
import Foundation

/// What macOS says is playing: MediaRemote's now-playing information, read by Helper/NowPlaying.m.
struct NowPlayingInfo: Equatable {
    var pid: Int32 = 0
    var title = "", artist = "", album = ""
    var duration: Double = 0
    /// The position at `timestamp`; it moves on at `rate` (0 = paused).
    var elapsed: Double = 0, rate: Double = 0
    var timestamp = Date.distantPast
    var playing: Bool { rate > 0 }
    func position(at now: Date) -> Double {
        max(0, elapsed + (playing && timestamp != .distantPast ? now.timeIntervalSince(timestamp) * rate : 0))
    }
    init() {}
    init?(_ d: [String: Any]) {
        guard let pid = d["pid"] as? NSNumber else { return nil }
        self.pid = pid.int32Value
        title = d["title"] as? String ?? ""; artist = d["artist"] as? String ?? ""; album = d["album"] as? String ?? ""
        duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (d["elapsed"] as? NSNumber)?.doubleValue ?? 0
        rate = (d["rate"] as? NSNumber)?.doubleValue ?? 0
        let stamp = (d["timestamp"] as? NSNumber)?.doubleValue ?? 0
        timestamp = stamp > 0 ? Date(timeIntervalSince1970: stamp) : .distantPast
    }
}

/// Runs /usr/bin/perl with Helper/NowPlaying.m loaded (MediaRemote answers only processes Apple allows, perl
/// among them) and hands each line to `onInfo`. Commands ("toggle", "next", "previous") go to whatever is playing.
@MainActor final class NowPlayingReader {
    var onInfo: ((NowPlayingInfo) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopped = true
    private var quickExits = 0
    private(set) var failed = false

    static let loader = #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); my $s = DynaLoader::dl_find_symbol($l, "np_main") or die "np_main"; DynaLoader::dl_install_xsub("main::np", $s); np();"#

    func start() {
        guard stopped else { return }
        stopped = false; failed = false; quickExits = 0
        launch()
    }
    func stop() {
        stopped = true
        process?.terminate(); process = nil; input = nil
    }
    func send(_ command: String) {
        input?.write(Data((command + "\n").utf8))
    }

    /// The library, copied out of the app bundle: files copied from a downloaded DMG keep the quarantine flag,
    /// and the library is loaded by perl rather than by the app the user allowed to run.
    private static func library() throws -> URL {
        guard let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("libnowplaying.dylib"),
              let data = FileManager.default.contents(atPath: bundled.path) else {
            throw NSError(domain: "NowPlaying", code: 1, userInfo: [NSLocalizedDescriptionKey: "libnowplaying.dylib not in the app"])
        }
        let dir = Settings.directory.appendingPathComponent("helper")
        let copy = dir.appendingPathComponent("libnowplaying.dylib")
        if FileManager.default.contents(atPath: copy.path) != data {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: copy, options: .atomic)
        }
        removexattr(copy.path, "com.apple.quarantine", 0)
        return copy
    }

    private func launch() {
        let started = Date()
        do {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", Self.loader, try Self.library().path]
            let out = Pipe(), inPipe = Pipe()
            p.standardOutput = out; p.standardInput = inPipe; p.standardError = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData, target = self
                DispatchQueue.main.async { MainActor.assumeIsolated { target?.received(chunk) } }
            }
            p.terminationHandler = { [weak self] ended in
                let status = ended.terminationStatus, target = self
                DispatchQueue.main.async { MainActor.assumeIsolated { target?.ended(status, after: Date().timeIntervalSince(started)) } }
            }
            try p.run()
            process = p; input = inPipe.fileHandleForWriting
        } catch {
            Log.error("now playing reader", error)
            failed = true
        }
    }

    private func received(_ chunk: Data) {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { Log.write("WARN now playing reader: \(error)"); continue }
            if let info = NowPlayingInfo(obj) { quickExits = 0; onInfo?(info) }
        }
    }

    private func ended(_ status: Int32, after seconds: TimeInterval) {
        process = nil; input = nil; buffer.removeAll()
        guard !stopped else { return }
        if seconds < 10 { quickExits += 1 }
        if quickExits >= 3 {
            Log.write("WARN now playing reader keeps exiting (\(status)); browser playback can't be read")
            failed = true
            return
        }
        Log.write("INFO now playing reader exited (\(status)), starting it again")
        Task { try? await Task.sleep(for: .seconds(5)); if !stopped { launch() } }
    }
}

/// The YouTube Music tabs of a browser, read with AppleScript: only tabs whose address starts with
/// https://music.youtube.com/ leave the browser (the filter runs inside it). The script runs in /usr/bin/osascript:
/// NSAppleScript on a background thread waited forever for the browser's reply, and on the main thread it would
/// hold up the overlay for the 0.2-0.4 s a reply takes.
@MainActor final class BrowserTabs {
    struct Tab: Equatable { var url: String; var title: String }
    enum Failure: Error { case denied, notScriptable, other(String) }

    /// Browsers whose tabs can be read: Chromium-based ones (Chrome's scripting terms) and Safari.
    static let chromium: [String: String] = [
        "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta", "com.google.Chrome.dev": "Chrome Dev",
        "com.google.Chrome.canary": "Chrome Canary", "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi", "company.thebrowser.Browser": "Arc", "org.chromium.Chromium": "Chromium",
        "com.operasoftware.Opera": "Opera", "com.naver.Whale": "Whale",
    ]
    static let safari: [String: String] = ["com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview"]
    /// Browsers known to play YouTube Music but without tab scripting.
    static let unscriptable: [String: String] = ["org.mozilla.firefox": "Firefox", "org.mozilla.firefoxdeveloperedition": "Firefox", "app.zen-browser.zen": "Zen"]
    static func name(of bundleId: String) -> String? { chromium[bundleId] ?? safari[bundleId] ?? unscriptable[bundleId] }
    static func scriptable(_ bundleId: String) -> Bool { chromium[bundleId] != nil || safari[bundleId] != nil }

    /// (The separators are set outside the tell block: inside it "tab" is the browser's tab class.)
    static func script(for bundleId: String) -> String? {
        let titleTerm: String
        if chromium[bundleId] != nil { titleTerm = "title" }
        else if safari[bundleId] != nil { titleTerm = "name" }
        else { return nil }
        return """
        set sep to character id 9
        set eol to character id 10
        with timeout of 3 seconds
            tell application id "\(bundleId)"
                set found to ""
                repeat with w in windows
                    repeat with t in (tabs of w whose URL starts with "https://music.youtube.com/")
                        set found to found & (URL of t) & sep & (\(titleTerm) of t) & eol
                    end repeat
                end repeat
                return found
            end tell
        end timeout
        """
    }

    /// The browser's YouTube Music tabs.
    func read(_ bundleId: String) async -> Result<[Tab], Failure> {
        guard let script = Self.script(for: bundleId) else { return .failure(.notScriptable) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let ended: Int32? = await withCheckedContinuation { (done: CheckedContinuation<Int32?, Never>) in
            p.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; done.resume(returning: nil); return }
            // a browser that doesn't answer (or a permission prompt left open) mustn't stop the reads for good
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let ended else { return .failure(.other("osascript didn't start")) }
        if ended != 0 {
            // -1743: the user said no in Privacy & Security > Automation
            return .failure(error.contains("-1743") ? .denied : .other(error.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(Self.parse(output))
    }

    /// "url<TAB>title" lines.
    static func parse(_ output: String) -> [Tab] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = fields.first, !url.isEmpty else { return nil }
            return Tab(url: String(url), title: fields.count > 1 ? String(fields[1]) : "")
        }
    }
}

/// YouTube Music played in a web browser, as a source of songs instead of Pear Desktop: the browser hands its
/// media session to macOS (title, position, playing or paused), and the tab's address names the video. The song's
/// details come from YouTube Music's queue entry for that video (the same anonymous request the lyrics lookup
/// makes), so a song from the browser looks like one from Pear. Messages go out in Pear's WebSocket format.
@MainActor final class BrowserSource {
    var onMessage: (([String: Any]) -> Void)?
    /// The browser playing (its name), or nil when none is.
    var onBrowser: ((String?) -> Void)?
    var onNotice: ((String) -> Void)?
    let reader = NowPlayingReader()
    private let tabs = BrowserTabs()
    private let ytm: YTMusicProvider

    private var info: NowPlayingInfo?
    private var bundleId = ""
    private var reading = false
    private var lastRead = Date.distantPast
    private var denied: Set<String> = []
    /// Browsers whose tabs were read this run (a timeout then is the browser being slow, not a permission prompt),
    /// and those the permission notice was shown for.
    private var readable: Set<String> = [], prompted: Set<String> = []
    private var resolving = ""
    /// The song sent last: its video, its playlist (the tab's `list`), and whether it was playing.
    private(set) var videoId = ""
    private(set) var playlist = ""
    private var songKey = ""
    private var title = "", tabTitle = ""
    private var playing = false
    private(set) var browser: String?

    init(ytm: YTMusicProvider) { self.ytm = ytm }

    func start() {
        reader.onInfo = { [weak self] info in self?.update(info) }
        reader.start()
    }
    func stop() { reader.stop(); browser = nil }

    /// Play / pause, next, previous: macOS sends them to the app playing (the browser, while it is the source).
    func control(_ action: String) {
        switch action {
        case "toggle-play": reader.send("toggle")
        case "next": reader.send("next")
        case "previous": reader.send("previous")
        default: break
        }
    }

    private func update(_ info: NowPlayingInfo) {
        self.info = info
        let app = NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier ?? ""
        guard let name = BrowserTabs.name(of: app), !info.title.isEmpty else {
            missing()   // something else is playing (or nothing)
            return
        }
        bundleId = app
        if !BrowserTabs.scriptable(app) || denied.contains(app) {
            // no tab addresses (Firefox, or not allowed): the song from what macOS says alone
            setBrowser(name)
            follow(videoId: "", list: "", tabTitle: "")
            return
        }
        // the tabs every second while playing, every 3 seconds while paused
        guard !reading, Date().timeIntervalSince(lastRead) >= (info.playing || songKey.isEmpty ? 0.9 : 2.9) else { tick(); return }
        reading = true; lastRead = Date()
        Task {
            let result = await tabs.read(app)
            reading = false
            switch result {
            case .success(let found):
                readable.insert(app)
                guard let tab = Self.playingTab(found, title: self.info?.title ?? "") else {
                    // no tab to tell by while macOS still names the song shown: carry on with it rather than calling it stopped
                    if shown() { missingSince = nil; setBrowser(name); tick(); return }
                    missing()   // a browser plays something, but not YouTube Music (another tab, another site)
                    return
                }
                missingSince = nil
                setBrowser(name)
                let (id, list) = Self.watchParameters(tab.url)
                follow(videoId: id, list: list, tabTitle: Self.tabSongTitle(tab.title))
            case .failure(.denied):
                if denied.insert(app).inserted {
                    Log.write("INFO reading \(name)'s tabs not allowed (Automation); using what macOS reports")
                    onNotice?("\(name) 탭의 주소를 읽을 수 없어서 제목으로 곡을 찾습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 허용할 수 있습니다")
                }
            case .failure(.other(let message)) where message.contains("-1712") && !readable.contains(app):
                // the first read waits for macOS's Automation prompt (it may open on another screen): say so, once
                Log.write("INFO reading \(name)'s tabs timed out, probably waiting for the Automation prompt")
                if prompted.insert(app).inserted {
                    onNotice?("\(name) 탭의 주소를 읽기 위해 macOS가 권한을 묻고 있습니다. 화면에 나타난 창에서 '허용'을 눌러 주십시오")
                }
            case .failure(let error):
                Log.write("INFO reading \(name)'s tabs failed: \(error)")
            }
        }
    }

    private func setBrowser(_ name: String?) {
        guard browser != name else { return }
        browser = name
        onBrowser?(name)
    }

    /// The tab playing: the YouTube Music video tab whose title has the title macOS reports, or the only one.
    static func playingTab(_ tabs: [BrowserTabs.Tab], title: String) -> BrowserTabs.Tab? {
        let videos = tabs.filter { !watchParameters($0.url).videoId.isEmpty }
        if let named = videos.first(where: { sameSong(title, title: tabSongTitle($0.title), tabTitle: "") }) { return named }
        return videos.count == 1 ? videos[0] : nil
    }
    /// "アイドル - Idol | YouTube Music" -> "アイドル - Idol" (before the video starts it is "YouTube Music" alone).
    static func tabSongTitle(_ title: String) -> String {
        for suffix in [" | YouTube Music", " - YouTube Music"] where title.hasSuffix(suffix) { return String(title.dropLast(suffix.count)) }
        return title == "YouTube Music" ? "" : title
    }
    /// The video ID and playlist of a music.youtube.com/watch address.
    static func watchParameters(_ url: String) -> (videoId: String, list: String) {
        guard let c = URLComponents(string: url), c.host == "music.youtube.com", c.path == "/watch" else { return ("", "") }
        let v = c.queryItems?.first { $0.name == "v" }?.value ?? ""
        let list = c.queryItems?.first { $0.name == "list" }?.value ?? ""
        return (isVideoId(v) ? v : "", list)
    }
    nonisolated static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The song playing: a new one is looked up and announced (VIDEO_CHANGED); the same one gets its position and
    /// play state. `urlId` empty: no tab address, only macOS's title and artist are known. Same as Follow in
    /// src/BrowserSource.cs.
    private func follow(videoId urlId: String, list: String, tabTitle: String) {
        guard let info else { return }
        // no address (only titles): the song shown goes on while macOS names it, instead of being looked up again by title
        if urlId.isEmpty && shown() { mismatchSince = nil; tick(); return }
        var id = urlId, tabSong = tabTitle
        // The tab's title and macOS's should name the same song. They don't for a moment while a song changes, and
        // a tab can keep the address and title of another song while it plays this one (seen 2026-10-20 after
        // opening an album link: "Epilogue" in the address bar, ハルジオン playing). Then a song with an album is
        // YouTube Music's, found by title; without one, it's another site playing.
        if !tabSong.isEmpty, !info.title.isEmpty, !Self.sameSong(info.title, title: tabSong, tabTitle: "") {
            if !mismatched() { tick(); return }
            if info.album.isEmpty { notYouTubeMusic(); return }
            id = ""; tabSong = ""
        }
        let key = id.isEmpty ? "|" + info.title + "|" + info.artist : id
        if key == songKey { mismatchSince = nil; playlist = list; tick(); return }
        guard key != resolving else { return }
        resolving = key
        Task {
            defer { if resolving == key { resolving = "" } }
            var id = id, settled = key
            // the address names another song than the one playing (read before it changed): wait for it, then go by title
            if !id.isEmpty, !(await addressNamesSong(id, tabSong: tabSong, info: info)) {
                if !mismatched() { return }
                id = ""; settled = "|" + info.title + "|" + info.artist
                if settled == songKey { return }
            }
            var found = id
            if found.isEmpty { found = await videoByTitle(info, tabSong: tabSong, playlist: list, near: urlId) }
            let song = await songFor(videoId: found, tabTitle: id.isEmpty ? "" : tabSong, info: info)
            guard resolving == key else { return }
            mismatchSince = nil
            noteGuess(list: list, videoId: found)
            songKey = settled; videoId = found; playlist = list; title = song["title"] as? String ?? ""; sent = song
            self.tabTitle = id.isEmpty ? "" : tabSong
            let now = self.info ?? info
            // macOS may still describe the song before for a moment: its position only when it names this one
            let position = Self.sameSong(now.title, title: title, tabTitle: self.tabTitle) ? now.position(at: Date()) : 0
            playing = now.playing
            Log.info("browser (\(browser ?? "?")) plays \(found.isEmpty ? "a song without a known video" : found): \(song["artist"] as? String ?? "") - \(title)")
            send(["type": "VIDEO_CHANGED", "song": song, "isPlaying": now.playing, "position": position])
        }
    }
    private var mismatchSince: Date?
    /// The song fields sent last.
    private var sent: [String: Any] = [:]

    /// Whether a song was sent and macOS still names it.
    private func shown() -> Bool {
        guard let info else { return false }
        return !songKey.isEmpty && Self.sameSong(info.title, title: title, tabTitle: tabTitle)
    }

    /// Whether titles have disagreed for 3 seconds now (started on the first call).
    private func mismatched() -> Bool {
        let since = mismatchSince ?? Date()
        mismatchSince = since
        return Date().timeIntervalSince(since) >= 3
    }

    /// Whether YouTube Music's title for the address's video is the song macOS (or the tab) names.
    private func addressNamesSong(_ id: String, tabSong: String, info: NowPlayingInfo) async -> Bool {
        guard let track = try? await ytm.lookup(id, withLyrics: false) else { return true }   // can't tell
        return track.title.isEmpty || Self.sameSong(info.title, title: track.title, tabTitle: "")
            || (!tabSong.isEmpty && Self.sameSong(tabSong, title: track.title, tabTitle: "") && Self.sameSong(info.title, title: tabSong, tabTitle: ""))
    }

    /// The position and play state of the song sent last, from what macOS reports now.
    private func tick() {
        guard !songKey.isEmpty, let info, resolving.isEmpty, Self.sameSong(info.title, title: title, tabTitle: tabTitle) else { return }
        // the album, once macOS describes this song (it was still on the song before when this one was sent)
        if (sent["album"] as? String ?? "").isEmpty && !info.album.isEmpty {
            sent["album"] = info.album; playing = info.playing
            send(["type": "VIDEO_CHANGED", "song": sent, "isPlaying": info.playing, "position": info.position(at: Date())])
            return
        }
        if info.playing != playing {
            playing = info.playing
            send(["type": "PLAYER_STATE_CHANGED", "isPlaying": info.playing, "position": info.position(at: Date())])
        } else if playing {
            send(["type": "POSITION_CHANGED", "position": info.position(at: Date())])
        }
    }

    /// Whether macOS's title is this song's: the same, or one half of "original - translation".
    static func sameSong(_ reported: String, title: String, tabTitle: String) -> Bool {
        let r = CoverLyrics.norm(reported)
        if r.isEmpty { return false }
        for candidate in [title, tabTitle] where !candidate.isEmpty {
            let c = CoverLyrics.norm(candidate)
            if !c.isEmpty && (c == r || c.contains(r) || r.contains(c)) { return true }
        }
        return false
    }

    private var missingSince: Date?

    /// No YouTube Music playing in sight. Taken as stopped only after 3 seconds: when a song ends, the browser clears
    /// its media information for about a second before naming the next song (seen on Windows 2026-10-20), which showed
    /// "paused" between every two songs. A pause by the user comes as paused from macOS and is shown at once.
    /// Same as Missing in src/BrowserSource.cs.
    private func missing() {
        if playing {
            let since = missingSince ?? Date()
            missingSince = since
            if Date().timeIntervalSince(since) < 3 { return }
        }
        missingSince = nil
        notYouTubeMusic()
    }

    /// Something else plays (or nothing): the browser's song, if any, stopped.
    private func notYouTubeMusic() {
        if playing { playing = false; send(["type": "PLAYER_STATE_CHANGED", "isPlaying": false]) }
        setBrowser(nil)
    }

    /// The video of a song known by its titles, artist and length: an entry of the tab's playlist with that title
    /// and length, or YouTube's search (with the tab's title when it has one). "" when neither is sure.
    private func videoByTitle(_ info: NowPlayingInfo, tabSong: String, playlist list: String, near: String) async -> String {
        if !list.isEmpty, !near.isEmpty, let entries = try? await ytm.playlistEntries(near, playlist: list),
           let entry = entries.first(where: { Self.sameSong(info.title, title: $0.title, tabTitle: "") && (info.duration <= 0 || abs($0.duration - info.duration) <= 3) }) {
            return entry.videoId
        }
        do { return try await ytm.findVideo(title: tabSong.isEmpty ? info.title : tabSong, artist: info.artist, duration: info.duration) ?? "" }
        catch { Log.write("INFO YouTube search failed: \(error.localizedDescription)"); return "" }
    }

    /// Pear's song fields for this video: YouTube Music's queue entry (title, artist, length, kind, cover) with
    /// macOS's title when it is one half of the entry's ("Idol" of "アイドル - Idol", as Pear gives it).
    private func songFor(videoId id: String, tabTitle: String, info: NowPlayingInfo) async -> [String: Any] {
        var song: [String: Any] = ["title": info.title, "artist": info.artist, "album": info.album,
                                   "songDuration": info.duration, "videoId": id, "mediaType": id.isEmpty ? "UNKNOWN" : ""]
        guard !id.isEmpty else { return song }
        do {
            let track = try await ytm.lookup(id, withLyrics: false)
            let described = Self.sameSong(info.title, title: track.title, tabTitle: "")
            if !track.title.isEmpty { song["title"] = described ? info.title : track.title }
            // macOS may still describe the song before (its album would stay on this one); tick() fills it in later
            if !described { song["album"] = "" }
            if !track.artist.isEmpty { song["artist"] = track.artist }
            if track.duration > 0 { song["songDuration"] = track.duration }
            song["mediaType"] = Self.mediaType(track.videoType)
            if !track.thumbnail.isEmpty { song["imageSrc"] = track.thumbnail }
        } catch {
            Log.write("INFO YouTube Music details for \(id) failed (\(error.localizedDescription)); using what macOS reports")
            if !tabTitle.isEmpty, info.title.isEmpty { song["title"] = tabTitle }
        }
        return song
    }

    /// The next song, guessed from the tab's playlist (an album or a playlist, in order). The browser's own queue
    /// can't be read, so with shuffle (or a radio, made for the signed-in user) the guess is wrong: after a wrong
    /// guess for a playlist, the guess is still made (one YouTube Music request) but not handed out until one comes
    /// true again, so no lyrics are fetched ahead for songs that won't play.
    func nextSong() async throws -> Song? {
        guard !videoId.isEmpty, !playlist.isEmpty else { return nil }
        let list = playlist
        guard let next = try await ytm.queueAfter(videoId, playlist: list), !next.videoId.isEmpty else { return nil }
        guesses[list] = next.videoId
        if missed.contains(list) { return nil }
        return Song(title: next.title, artist: next.artist, videoId: next.videoId, mediaType: Self.mediaType(next.videoType), duration: next.duration)
    }
    private var guesses: [String: String] = [:]
    private var missed: Set<String> = []
    /// A new song from `list`: was it the one guessed?
    private func noteGuess(list: String, videoId id: String) {
        guard !list.isEmpty, let guess = guesses.removeValue(forKey: list) else { return }
        if guess == id { missed.remove(list) }
        else if missed.insert(list).inserted { Log.info("the browser didn't play the next song of its playlist (shuffle?); not fetching ahead for it") }
    }

    /// Pear's MediaType for YouTube Music's musicVideoType.
    static func mediaType(_ videoType: String) -> String {
        switch videoType {
        case "MUSIC_VIDEO_TYPE_ATV": return "AUDIO"
        case "MUSIC_VIDEO_TYPE_OMV": return "ORIGINAL_MUSIC_VIDEO"
        case "MUSIC_VIDEO_TYPE_UGC": return "USER_GENERATED_CONTENT"
        case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": return "PODCAST_EPISODE"
        case "": return ""
        default: return "OTHER_VIDEO"
        }
    }

    private func send(_ message: [String: Any]) { onMessage?(message) }
}
