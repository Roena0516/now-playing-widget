import Foundation

/// "Listening to" on the user's Discord profile (Rich Presence), through the Discord app's local IPC socket
/// ($TMPDIR/discord-ipc-N): no server of ours, and nothing when Discord isn't running. Only songs from the browser
/// are shown (Pear Desktop has its own Discord plugin), and only when the user turns it on (discordPresence).
/// Socket work runs on its own queue. Same as src/DiscordPresence.cs.
final class DiscordPresence: @unchecked Sendable {
    static let clientId = "1562020013953515553"
    static let projectURL = "https://github.com/Roena0516/pear-now-playing"
    /// Discord takes about 5 activity updates per 20 seconds.
    static let minGap: TimeInterval = 4

    struct Activity: Equatable {
        var title = "", artist = "", album = "", imageURL = "", videoId = ""
        /// When the song started and ends, for Discord's progress bar.
        var start = Date(), end = Date()
        var button = true
        /// Close enough that sending it again would only use up Discord's rate limit (positions drift with the
        /// clock; a seek moves the start by more than 3 seconds).
        func same(_ other: Activity?) -> Bool {
            guard let other else { return false }
            return title == other.title && artist == other.artist && album == other.album && imageURL == other.imageURL && videoId == other.videoId
                && button == other.button && abs(start.timeIntervalSince(other.start)) < 3 && abs(end.timeIntervalSince(other.end)) < 3
        }
    }

    private let queue = DispatchQueue(label: "DiscordPresence")
    /// Where Discord's sockets are (its own temporary folder is the user's); a test points it elsewhere.
    var directory = NSTemporaryDirectory()
    private var wanted: Activity?, sent: Activity?
    private var sentAny = false, scheduled = false, loggedMissing = false
    private var lastSend = Date.distantPast
    private var fd: Int32 = -1

    /// The activity to show (nil: none). Sent when it differs from the last one, at Discord's pace.
    func show(_ activity: Activity?) { queue.async { self.wanted = activity; self.pump() } }

    private func later(_ seconds: TimeInterval) {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + seconds) { self.scheduled = false; self.pump() }
    }

    private func pump() {
        let next = wanted
        if let next { if next.same(sent) { return } } else if !sentAny || sent == nil { return }
        if next == nil && fd < 0 { sent = nil; return }   // nothing shown: no need to connect
        let wait = lastSend.addingTimeInterval(Self.minGap).timeIntervalSinceNow
        if wait > 0 { later(wait); return }
        if fd < 0 && !connect() { later(15); return }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "nonce": UUID().uuidString,
                                      "args": ["pid": Int(getpid()), "activity": next.map(Self.activity) ?? NSNull()]]
        if write(1, payload) {
            lastSend = Date(); sent = next; sentAny = true
        } else {
            Log.write("INFO Discord: the connection closed, trying again later")
            disconnect(); later(15)
        }
    }

    /// Discord's activity object: "Listening" with the song, its cover, progress and the project's button.
    static func activity(_ a: Activity) -> [String: Any] {
        var activity: [String: Any] = [
            "type": 2,                    // Listening
            "status_display_type": 2,     // the member list shows the song ("details"), not the app's name
            "details": field(a.title), "state": field(a.artist),
            "timestamps": ["start": Int64(a.start.timeIntervalSince1970 * 1000), "end": Int64(a.end.timeIntervalSince1970 * 1000)],
        ]
        // the title (and the cover) open the song on YouTube Music
        let link = BrowserSource.isVideoId(a.videoId) ? "https://music.youtube.com/watch?v=" + a.videoId : nil
        if let link { activity["details_url"] = link }
        if a.imageURL.hasPrefix("https://") {
            var assets: [String: Any] = ["large_image": a.imageURL, "large_text": field(a.album.isEmpty ? a.title : a.album)]
            if let link { assets["large_url"] = link }
            activity["assets"] = assets
        }
        if a.button { activity["buttons"] = [["label": "Now Playing Widget", "url": projectURL]] }
        return activity
    }

    /// Discord takes 2 to 128 characters (padded with a blank that isn't whitespace, so it isn't trimmed away).
    static func field(_ s: String) -> String {
        var t = s.trimmed
        if t.count > 128 { t = String(t.prefix(127)) + "…" }
        while t.count < 2 { t += "\u{2800}" }
        return t
    }

    // ---- the socket ----

    private func connect() -> Bool {
        for i in 0..<10 {
            let path = (directory as NSString).appendingPathComponent("discord-ipc-\(i)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            if s < 0 { continue }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected != 0 { close(s); continue }
            fd = s
            guard write(0, ["v": 1, "client_id": Self.clientId]), let ready = read(s), ready.contains("\"READY\"") else {
                Log.write("INFO Discord: discord-ipc-\(i) didn't accept the handshake")
                disconnect(); continue
            }
            Log.info("Discord: connected (discord-ipc-\(i))")
            loggedMissing = false
            // answers to later commands are read and dropped, so the socket never fills up; a closed socket ends it
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self] in
                while Self.readFrame(s) != nil {}
                self?.queue.async { if self?.fd == s { self?.disconnect() } }
            }
            return true
        }
        if !loggedMissing { loggedMissing = true; Log.info("Discord isn't running; the listening status waits for it") }
        return false
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1; sent = nil
    }

    private func write(_ opcode: UInt32, _ payload: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: opcode.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func read(_ s: Int32) -> String? { Self.readFrame(s) }

    /// One frame's JSON, or nil when the socket closed (or timed out).
    private static func readFrame(_ s: Int32) -> String? {
        guard let header = readExactly(s, 8) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard length >= 0, length <= 1 << 20, let body = readExactly(s, length) else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    private static func readExactly(_ s: Int32, _ count: Int) -> Data? {
        var data = Data(count: count), got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(s, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }
}
