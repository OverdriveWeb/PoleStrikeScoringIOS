import Foundation

/// Everything the app needs to reach the shared backend, baked in at build time.
///
/// There is deliberately no screen for any of this. Shared learning is not a
/// feature you turn on — it is how the app works, and a setting that can be
/// switched off is a setting that will be switched off by accident on the one
/// phone that had the best data.
///
/// The anon key belongs in client code. That is what it is for: it grants only
/// what row-level security allows, which here is "insert a row of fourteen
/// numbers", "read the pool", and "call the scoring function". It is not a
/// secret in the way a service-role key is — never put a service-role key in an
/// app.
enum CloudDefaults {

    static let url = "https://ovtmvlqfafrwlyjhbsow.supabase.co"

    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im92dG12bHFmYWZyd2x5amhic293Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY0MDE5MjAsImV4cCI6MjEwMTk3NzkyMH0.ly804NW3gJRQnFj0NGqBi0ecWJSlMMjoIbmcQjg1Jiw"

    /// Trimmed, no trailing slash, so path joining is never ambiguous.
    static var base: String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static var isConfigured: Bool {
        !base.isEmpty && !anonKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func rest(_ path: String) -> URL? {
        URL(string: "\(base)/rest/v1/\(path)")
    }

    /// Random per install, so rows can be de-duplicated and a device can skip
    /// its own contributions on download. Not tied to anything about you.
    static var deviceId: String {
        let key = "polescore.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func authorize(_ request: inout URLRequest) {
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
