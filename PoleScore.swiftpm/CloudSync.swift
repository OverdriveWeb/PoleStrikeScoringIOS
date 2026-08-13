import Foundation

/// Shared learning across every install. Always on, no setup, no switch.
///
/// What crosses the network is deliberately tiny and impersonal: fourteen
/// numbers describing the physics of a play — heights, speeds, frame counts —
/// plus which call was correct. No video, no images, no location, no account,
/// no way back to a person. A row looks like `[1, 5, 0, 0.02, 0.41, ...] -> 0`.
///
/// The reason this transfers across courts at all: every feature is normalized
/// against *that install's own* auto-detected court. A height of 0.02 means
/// "just above my ground line" whether the court is a backyard or a beach. Raw
/// pixels would be useless between users; calibrated ratios are comparable.
struct SyncReport {
    var uploaded = 0
    var downloaded = 0
    var poolSize = 0
    var error: String?
}

/// Supabase REST client. No server code to deploy for this part — a table and
/// two policies. See `supabase-schema.sql`.
actor CloudSync {
    private var uploadedIds = Set<String>()
    private let uploadedKey = "polescore.uploaded"

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: uploadedKey) {
            uploadedIds = Set(stored)
        }
    }

    private struct Row: Codable {
        var id: String
        var device: String
        var features: [Double]
        var label: Int
        var rule_call: Int
        var app_version: String
    }

    private struct DownloadRow: Codable {
        var id: String
        var features: [Double]
        var label: Int
        var rule_call: Int
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        CloudDefaults.authorize(&request)
        request.timeoutInterval = 20
        return request
    }

    /// Push anything this device has learned that has not been shared yet, then
    /// pull back what everyone else has contributed.
    func sync(local: [TrainingExample], poolLimit: Int = 800) async -> (report: SyncReport, pool: [TrainingExample]) {
        var report = SyncReport()
        guard CloudDefaults.isConfigured else {
            report.error = "No project baked into this build."
            return (report, [])
        }

        // --- upload ---------------------------------------------------------
        let pending = local.filter { !uploadedIds.contains($0.id) }
        if !pending.isEmpty, let url = CloudDefaults.rest("training_examples") {
            let rows = pending.map {
                Row(id: $0.id,
                    device: CloudDefaults.deviceId,
                    features: $0.features.vector,
                    label: $0.label,
                    rule_call: $0.ruleCall,
                    app_version: "2.0")
            }
            var request = request(url, method: "POST")
            request.setValue("return=minimal,resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
            request.httpBody = try? JSONEncoder().encode(rows)
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    report.uploaded = rows.count
                    uploadedIds.formUnion(rows.map(\.id))
                    UserDefaults.standard.set(Array(uploadedIds), forKey: uploadedKey)
                } else if let http = response as? HTTPURLResponse {
                    report.error = "Upload failed (HTTP \(http.statusCode))."
                }
            } catch {
                report.error = "Upload failed: \(error.localizedDescription)"
            }
        }

        // --- download -------------------------------------------------------
        guard let base = CloudDefaults.rest("training_examples"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return (report, [])
        }
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,features,label,rule_call"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(poolLimit)),
            // Skip our own rows: they are already in the local set, and counting
            // them twice would quietly overweight this one court.
            URLQueryItem(name: "device", value: "neq.\(CloudDefaults.deviceId)")
        ]
        guard let downloadURL = components.url else { return (report, []) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request(downloadURL, method: "GET"))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                report.error = report.error ?? "Download failed."
                return (report, [])
            }
            let rows = try JSONDecoder().decode([DownloadRow].self, from: data)
            let pool: [TrainingExample] = rows.compactMap { row in
                guard row.features.count == PlayFeatures.count else { return nil }
                var features = PlayFeatures()
                features.vector = row.features
                return TrainingExample(id: row.id, features: features, label: row.label,
                                       ruleCall: row.rule_call, at: Date())
            }
            report.downloaded = pool.count
            report.poolSize = pool.count
            return (report, pool)
        } catch {
            report.error = report.error ?? "Download failed: \(error.localizedDescription)"
            return (report, [])
        }
    }
}
