import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var learning: LearningStore

    // Mirrors of the detector's settings. The service is deliberately not an
    // ObservableObject — it lives on the capture path and has no business
    // publishing at frame rate — so the sliders hold their own state and
    // push changes across.
    @State private var detectorConfidence: Double = 0.45
    @State private var detectorFPS: Double = 10

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $store.mode) {
                    ForEach(ScoringMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(store.mode.detail).font(.footnote).foregroundStyle(Theme.muted)
            } header: {
                Text("How it keeps score")
            }

            Section {
                Picker("Rules", selection: Binding(
                    get: { store.rules.id },
                    set: { id in store.rules = RuleSet.presets.first { $0.id == id } ?? .beersbee }
                )) {
                    ForEach(RuleSet.presets) { Text($0.name).tag($0.id) }
                }
                Text(store.rules.detail).font(.footnote).foregroundStyle(Theme.muted)
            } header: {
                Text("Rules")
            }

            // Everything in this section used to be a control. It is a readout
            // now: the court, the glow colours, the brightness threshold and
            // the camera orientation are all worked out from what the camera
            // can see, and all four of them change during a game in ways a
            // saved setting could never keep up with.
            Section {
                LabeledContent("Court") {
                    Text(camera.courtReady ? camera.courtSummary : "Not read yet")
                        .foregroundStyle(camera.courtReady ? Theme.muted : Theme.flag)
                }
                LabeledContent("Confidence") {
                    Text("\(Int(camera.courtConfidence * 100))%").monospacedDigit().foregroundStyle(Theme.muted)
                }
                LabeledContent("Glow colours") {
                    Text(camera.colorSummary).foregroundStyle(Theme.muted)
                }
                LabeledContent("Zoom") {
                    Text(String(format: "%.1f×", camera.zoom)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                Button("Re-read the court") { camera.rediscoverCourt() }
            } header: {
                Text("What it worked out")
            } footer: {
                Text("The poles, the ground line, the glow colours, the brightness cut-off and the "
                     + "camera orientation are all detected, continuously. Pinch the game screen to "
                     + "zoom — the court is re-read automatically afterwards, because zooming moves "
                     + "every measurement in the frame.")
            }

            // The detector section. Everything here is a live readout except
            // the two numbers that genuinely are trade-offs: how sure the model
            // must be, and how hard the device is allowed to work.
            Section {
                LabeledContent("Detector") {
                    Text(camera.detectorStatus.text)
                        .foregroundStyle(camera.detectorStatus.isRunnable ? Theme.muted : Theme.flag)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Objects this frame") {
                    Text("\(camera.modelDetections.count)").monospacedDigit().foregroundStyle(Theme.muted)
                }
                Toggle("Show detection boxes", isOn: $store.showDetectionOverlay)

                VStack(alignment: .leading) {
                    Text("Detection confidence: \(Int(detectorConfidence * 100))%")
                    Slider(value: $detectorConfidence, in: 0.1...0.9, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Inference rate: \(Int(detectorFPS)) fps")
                    Slider(value: $detectorFPS, in: 3...15, step: 1)
                }
            } header: {
                Text("Object detection")
            } footer: {
                Text("A YOLO model running entirely on this device — nothing is uploaded and "
                     + "there is no network involved. If the model is not in the app bundle, or the "
                     + "device gets too hot, scoring falls back to the glow-brightness detector "
                     + "automatically. Lower the rate to save battery; raise the confidence if it is "
                     + "boxing things that are not there.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Confidence to auto-score: \(Int(store.confidence * 100))%")
                    Slider(value: $store.confidence, in: 0.5...0.99)
                }
                Toggle("Developer overlay", isOn: $store.showDebug)
                Toggle("Use what it has learned", isOn: $learning.enabled)
            } header: {
                Text("Scoring")
            } footer: {
                Text("In Ask-first mode this decides which calls are flagged for review. In "
                     + "Automatic mode nothing is ever flagged to you — a call the app is unsure of "
                     + "is sent to the cloud model for a second opinion instead, and corrected "
                     + "quietly if it comes back different.")
            }

            Section {
                TextField("Team A", text: $store.teamAName)
                TextField("Team B", text: $store.teamBName)
            } header: {
                Text("Teams")
            }

            Section {
                LabeledContent("Examples from this device") {
                    Text("\(learning.count)").monospacedDigit().foregroundStyle(Theme.muted)
                }
                LabeledContent("From other players") {
                    Text("\(learning.pool.count)").monospacedDigit().foregroundStyle(Theme.muted)
                }
            } header: {
                Text("Shared learning")
            } footer: {
                Text("Always on, nothing to set up. Every install contributes anonymous play "
                     + "measurements and reads back the pool, so a new phone starts with everyone's "
                     + "experience instead of nothing. What leaves the device is fourteen numbers "
                     + "and the correct call — no video, no images, no identity.")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            detectorConfidence = Double(camera.yolo.confidenceThreshold)
            detectorFPS = camera.yolo.inferenceFPS
        }
        .onChange(of: detectorConfidence) { _, new in camera.yolo.confidenceThreshold = Float(new) }
        .onChange(of: detectorFPS) { _, new in camera.yolo.inferenceFPS = new }
        .onChange(of: store.confidence) { _, new in camera.machine.config.confidenceThreshold = new }
        .onChange(of: store.mode) { _, new in
            camera.scoringEnabled = new != .manual
            camera.machine.config.autoResumeBottleReset = new == .auto
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: GameStore

    var body: some View {
        List {
            if store.plays.isEmpty {
                Text("No plays yet. Every call lands here with its confidence and the evidence behind it.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(store.plays.reversed()) { play in
                VStack(alignment: .leading, spacing: 4) {
                    Text(play.banner).font(.subheadline.weight(.semibold))
                    Text("\(Int(play.confidence * 100))% · \(play.applied ? "applied" : "not applied")")
                        .font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    ForEach(play.reasons, id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("History")
    }
}
