import AppKit
import CryptoKit

struct UpdateInfo: Equatable {
    var version = "", assetName = "", url = "", sha256 = "", pageURL = ""
}

/// Updates from this repository's GitHub releases, like the Windows version (src/Updater.cs): the latest
/// release's PearNowPlaying-macOS-a.b.c.dmg is downloaded, checked against the SHA-256 GitHub lists for it, mounted
/// out of sight, its app checked (signature, bundle ID, version) and swapped in for the running one, which then
/// relaunches. Files the app downloads itself carry no quarantine flag, so Gatekeeper doesn't ask again.
@MainActor final class Updater {
    static let releasesAPI = URL(string: "https://api.github.com/repos/Roena0516/pear-now-playing/releases/latest")!
    var apiURL = releasesAPI
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("PearNowPlaying-macOS/\(appVersion) (+https://github.com/Roena0516/pear-now-playing)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The newer release for macOS, or nil when this version is the latest. Throws when GitHub can't be asked.
    func check(current: String = appVersion) async throws -> UpdateInfo? {
        let (data, response) = try await session.data(for: request(apiURL))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Updater", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "GitHub releases \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        return Self.info(from: try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:], current: current)
    }

    /// The update in a GitHub "latest release" answer: newer than `current`, with this platform's file
    /// ("PearNowPlaying-macOS-1.6.0.dmg") and its SHA-256 digest. Nil otherwise.
    nonisolated static func info(from release: [String: Any], current: String, prefix: String = "PearNowPlaying-macOS-", ext: String = ".dmg") -> UpdateInfo? {
        let version = (release["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard isNewer(version, than: current) else { return nil }
        let wanted = (prefix + version + ext).lowercased()
        guard let asset = (release["assets"] as? [[String: Any]] ?? []).first(where: { ($0["name"] as? String ?? "").lowercased() == wanted }),
              let digest = asset["digest"] as? String, digest.lowercased().hasPrefix("sha256:") else { return nil }   // can't be checked: not offered
        return UpdateInfo(version: version, assetName: asset["name"] as? String ?? "", url: asset["browser_download_url"] as? String ?? "",
                          sha256: String(digest.dropFirst(7)).lowercased(), pageURL: release["html_url"] as? String ?? "")
    }

    /// "1.6.0" newer than "1.5.2"? Missing parts count as 0; anything unreadable is never newer.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parse(_ v: String) -> [Int]? {
            let parts = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count) else { return nil }
            var n = [0, 0, 0]
            for (i, p) in parts.prefix(3).enumerated() { guard let x = Int(p), x >= 0, p.allSatisfy(\.isNumber) else { return nil }; n[i] = x }
            return n
        }
        guard let a = parse(candidate), let b = parse(current) else { return false }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    /// Download the release file into `directory` and check it against the listed SHA-256.
    func download(_ update: UpdateInfo, into directory: URL) async throws -> URL {
        guard let url = URL(string: update.url) else { throw URLError(.badURL) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temp, response) = try await session.download(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let file = directory.appendingPathComponent(update.assetName)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        let actual = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard actual == update.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "SHA-256 mismatch: expected \(update.sha256), got \(actual)"])
        }
        return file
    }

    /// Mount the DMG (no Finder window), check its app — valid signature, same bundle ID, the expected version —
    /// and swap it in for `target`. The running app is moved aside first and put back if anything fails.
    nonisolated static func install(dmg: URL, version: String, into target: URL, bundleId: String) throws {
        let work = dmg.deletingLastPathComponent()
        let mount = work.appendingPathComponent("mount")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "no app in the DMG"])
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) ?? [:]
        guard plist["CFBundleIdentifier"] as? String == bundleId, plist["CFBundleShortVersionString"] as? String == version else {
            throw NSError(domain: "Updater", code: 3, userInfo: [NSLocalizedDescriptionKey: "the DMG holds \(plist["CFBundleIdentifier"] ?? "?") \(plist["CFBundleShortVersionString"] ?? "?"), not \(bundleId) \(version)"])
        }
        let staged = work.appendingPathComponent("staged.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", ["--norsrc", app.path, staged.path])

        let aside = target.deletingLastPathComponent().appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-old.app")
        try? FileManager.default.removeItem(at: aside)
        try FileManager.default.moveItem(at: target, to: aside)
        do { try FileManager.default.moveItem(at: staged, to: target) }
        catch {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: aside, to: target)
            throw error
        }
        try? FileManager.default.removeItem(at: aside)
    }

    /// Open the app at `target` again once this process has exited, then quit.
    static func relaunch(_ target: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "relaunch", target.path]
        try? helper.run()
        NSApp.terminate(nil)
    }

    @discardableResult nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\((tool as NSString).lastPathComponent) failed: \(text.trimmed)"])
        }
        return text
    }
}
