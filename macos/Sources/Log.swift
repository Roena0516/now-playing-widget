import Foundation

/// The app's log, like the Windows version's error.log: ~/Library/Application Support/PearNowPlaying-macOS/error.log,
/// one line per event ("yyyy-MM-dd HH:mm:ss" local time + message), started over past 512 KB. Lyrics lookups,
/// the Pear connection and errors go here. Tokens and lyrics text are never written.
enum Log {
    static var file = Settings.directory.appendingPathComponent("error.log")
    /// Also print each line (the --browser-probe run).
    static var echo = false
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss "; return f
    }()

    static func info(_ message: String) { write("INFO " + message) }
    static func error(_ place: String, _ error: Error) {
        let e = error as NSError
        write("ERROR \(place): \(e.domain) \(e.code) \(e.localizedDescription)")
    }

    static func write(_ message: String) {
        if echo { print(stamp.string(from: Date()) + message); fflush(stdout) }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber, size.intValue > 512 * 1024 { try FileManager.default.removeItem(at: file) }
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data((stamp.string(from: Date()) + message + "\n").utf8))
        } catch { NSLog("Pear Now Playing log: %@", error.localizedDescription) }
    }

    /// " (built yyyy-MM-dd HH:mm)": when this executable was built (its modification time, kept by the DMG and
    /// updates), so logs of builds that share a version number can be told apart.
    static var buildStamp: String {
        guard let path = Bundle.main.executablePath,
              let built = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return " (built \(f.string(from: built)))"
    }

    /// Versions before 1.5.3 kept only lyrics lookups, in lyrics.log: carry it over.
    static func migrate() {
        let old = file.deletingLastPathComponent().appendingPathComponent("lyrics.log")
        if FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.moveItem(at: old, to: file)
        }
    }
}
