import Foundation

/// Changes only the API plugin's local connection settings; keeps unrelated player preferences.
struct PlayerSetup {
    struct Result {
        let changed: Bool
        let backup: URL?
    }
    enum SetupError: LocalizedError {
        case configNotFound, invalidConfig
        var errorDescription: String? {
            switch self {
            case .configNotFound: return "YouTube Music/Pear Desktop 설정 파일을 찾지 못했습니다. 음악 앱을 한 번 실행한 뒤에 다시 요청해 주십시오."
            case .invalidConfig: return "음악 앱 설정 파일 형식을 확인할 수 없어 변경하지 않았습니다."
            }
        }
    }
    static func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        for name in ["YouTube Music", "Pear Desktop", "pear-desktop"] {
            let url = home.appendingPathComponent("Library/Application Support/\(name)/config.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw SetupError.configNotFound
    }
    static func apply(to url: URL, port: Int) throws -> Result {
        let original = try Data(contentsOf: url)
        guard var config = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              config["plugins"] == nil || config["plugins"] is [String: Any] else { throw SetupError.invalidConfig }
        var plugins = config["plugins"] as? [String: Any] ?? [:]
        guard plugins["api-server"] == nil || plugins["api-server"] is [String: Any] else { throw SetupError.invalidConfig }
        var api = plugins["api-server"] as? [String: Any] ?? [:]
        if api["enabled"] as? Bool == true, api["hostname"] as? String == "127.0.0.1",
           api["port"] as? Int == port, api["useHttps"] as? Bool != true {
            return Result(changed: false, backup: nil)
        }
        api["enabled"] = true; api["hostname"] = "127.0.0.1"; api["port"] = port
        api["useHttps"] = false
        plugins["api-server"] = api; config["plugins"] = plugins
        let updated = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        let backup = url.deletingLastPathComponent().appendingPathComponent("config.before-pear-now-playing-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: backup)
        try updated.write(to: url, options: .atomic)
        return Result(changed: true, backup: backup)
    }
}
