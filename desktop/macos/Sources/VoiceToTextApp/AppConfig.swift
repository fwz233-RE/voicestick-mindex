import Foundation

struct AppConfig {
    let aliyunAPIKey: String
    let shortcutKeyCode: UInt32
    let shortcutModifiers: UInt32

    static let `default` = AppConfig(
        aliyunAPIKey: "",
        shortcutKeyCode: 49,
        shortcutModifiers: 0
    )

    static func load() -> AppConfig {
        let key = environmentAPIKey()
            ?? localAPIKey()
            ?? Self.default.aliyunAPIKey
        return AppConfig(
            aliyunAPIKey: key,
            shortcutKeyCode: Self.default.shortcutKeyCode,
            shortcutModifiers: Self.default.shortcutModifiers
        )
    }

    private static func environmentAPIKey() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for name in ["DASHSCOPE_API_KEY", "ALIYUN_API_KEY", "VOICE_TO_TEXT_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func localAPIKey() -> String? {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let plistURL = supportDirectory
            .appendingPathComponent("Voice to Text", isDirectory: true)
            .appendingPathComponent("config.plist")

        guard let values = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let value = values["aliyunAPIKey"] as? String else {
            return nil
        }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
