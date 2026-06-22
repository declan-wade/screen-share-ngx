import Foundation

/// Persisted CLI configuration written by `scripts/setup.sh`.
/// Lives at ~/.config/screenshare/config.json (override with $SCREENSHARE_CONFIG).
/// Lets `screenshare start` run with no flags or env vars after setup.
struct AppConfig: Decodable {
    var worker: String?
    var token: String?

    static func load() -> AppConfig {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["SCREENSHARE_CONFIG"]
            ?? (fm.homeDirectoryForCurrentUser.path + "/.config/screenshare/config.json")
        guard let data = fm.contents(atPath: path) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }
}
