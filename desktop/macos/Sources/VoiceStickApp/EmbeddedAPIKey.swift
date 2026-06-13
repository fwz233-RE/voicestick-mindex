import Foundation

enum EmbeddedAPIKey {
    static func aliyunAPIKey() -> String {
#if PRIVATE_EMBEDDED_API_KEY
        PrivateEmbeddedAPIKey.aliyunAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
#else
        ""
#endif
    }
}