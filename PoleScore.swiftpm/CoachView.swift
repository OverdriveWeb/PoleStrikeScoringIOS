import SwiftUI

/// The assistant. Reads what the app measured and says something specific
/// about it. The detector looks at frames; this looks at numbers.
struct CoachView: View {
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var learning: LearningStore

    @State private var tuningResult: Evolver.Result?
    @State private var working = false

    var body: some View {
        List {
            Section("What I can see right now") {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(color(note.level)).frame(width: 9, height: 9).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.title).font(.subheadline.weight(.semibold))
                            Text(note.detail).font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                LabeledContent("From other players") {
                    Text("\(learning.pool.count)").monospacedDigit().foregroundStyle(Theme.muted)
                }
                if learning.usingPool {
                    Text("The pooled data is improving your calls, so it is being used.")
                        .font(.footnote).foregroundStyle(Theme.glass)
                } else if !learning.pool.isEmpty {
                    Text("Your own history predicts your court better right now, so the pool is being held back.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                if let report = learning.lastSync {
                    Text(report.error ?? "Sent \(report.uploaded), received \(report.downloaded).")
                        .font(.caption.monospaced())
                        .foregroundStyle(report.error == nil ? Theme.muted : Theme.flag)
                }
            } header: {
                Text("Everyone's data")
            } footer: {
                Text("Syncs by itself, on launch and as examples accumulate. There is no button and no "
                     + "switch — fourteen numbers per play plus the correct answer, no video, no images, "
                     + "no account.")
            }

            Section {
                LabeledContent("Examples learned") {
                    Text("\(learning.count)").monospacedDigit().foregroundStyle(Theme.muted)
                }
                LabeledContent("Model agrees") {
                    Text("\(Int(learning.lastAccuracy * 100))%").monospacedDigit().foregroundStyle(Theme.muted)
                }
                LabeledContent("Fixed rules agree") {
                    Text("\(Int(learning.ruleAgreement * 100))%").monospacedDigit().foregroundStyle(Theme.muted)
                }

                Button {
                    working = true
                    // Read the main-actor state here, then hand plain values to
                    // the background queue.
                    let startConfig = store.tuning
                    let examples = learning.examples + learning.pool
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Evolver.evolve(from: startConfig, examples: examples)
                        DispatchQueue.main.async {
                            store.tuning = result.config
                            camera.machine.applyTuning(result.config)
                            tuningResult = result
                            working = false
                        }
                    }
                } label: {
                    HStack {
                        Text("Tune thresholds from my history")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(learning.count < 8 || working)

                if let result = tuningResult {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Matched the confirmed calls \(Int(result.accuracyBefore * 100))% → \(Int(result.accuracyAfter * 100))%")
                            .font(.footnote.weight(.semibold))
                        Text("Catch height \(String(format: "%.3f", result.config.catchHeightMin)) · settle gate \(String(format: "%.2f", result.config.settleSpeedGate)) · confirm \(Int(result.config.confirmFrames)) frames")
                            .font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    }
                }

                Button("Retrain the model now") {
                    learning.retrain()
                }
                .disabled(learning.count < 4)

                Button("Forget everything it learned", role: .destructive) {
                    learning.forgetEverything()
                }

                Button("Forget the learned glow colours", role: .destructive) {
                    camera.classifier.forgetColors()
                }
            } header: {
                Text("Learning")
            } footer: {
                Text("Ask-first mode is where labelled examples come from — Automatic mode never asks, "
                     + "so it never collects one. Threshold tuning usually helps sooner than the learned "
                     + "model: it needs about 8 examples, the model closer to 40.")
            }

            Section("Common questions") {
                ForEach(Coach.questions) { item in
                    DisclosureGroup(item.question) {
                        Text(item.answer).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    .font(.subheadline)
                }
            }

            if store.showDebug {
                Section("Detection self-checks") {
                    ForEach(DetectionSelfTests.runAll(), id: \.name) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.passed ? Theme.glass : Theme.alert)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.caption)
                                if !result.passed, !result.detail.isEmpty {
                                    Text(result.detail).font(.caption2.monospaced()).foregroundStyle(Theme.alert)
                                }
                            }
                        }
                    }
                }
            }

            if let last = store.plays.last {
                Section("Why it called the last play that way") {
                    Text(Coach.explain(last)).font(.footnote.monospaced()).foregroundStyle(Theme.muted)
                }
            }
        }
        .navigationTitle("Coach")
        .onAppear { learning.autoSync() }
    }

    private var notes: [CoachNote] {
        Coach.diagnose(
            scene: Coach.SceneSnapshot(blobCount: camera.blobCount,
                                       fps: camera.analysisFPS,
                                       courtReady: camera.courtReady,
                                       courtConfidence: camera.courtConfidence,
                                       courtSummary: camera.courtSummary,
                                       colorSummary: camera.colorSummary,
                                       detectorStatus: camera.detectorStatus,
                                       detectionCount: camera.modelDetections.count),
            mode: store.mode,
            plays: store.plays,
            learning: learning.snapshot)
    }

    private func color(_ level: CoachNote.Level) -> Color {
        switch level {
        case .good: return Theme.glass
        case .warn: return Theme.disc
        case .bad: return Theme.alert
        }
    }
}

/// Shown when you reject a suggestion in Ask-first mode: whatever you tap is
/// the truth, and becomes a labelled example.
struct CorrectionPad: View {
    @EnvironmentObject var store: GameStore
    let outcome: PlayOutcome

    private struct Choice: Identifiable {
        let id: PlayClass
    }

    private var choices: [Choice] { PlayClass.allCases.map { Choice(id: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What actually happened?")
                .font(.subheadline.weight(.semibold))
            Text("It said \(outcome.primaryClass.label). Tapping the right answer scores the play and teaches it.")
                .font(.caption).foregroundStyle(Theme.muted)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                ForEach(choices) { choice in
                    Button {
                        store.correct(to: choice.id.event)
                    } label: {
                        Text(choice.id.label)
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.disc, lineWidth: 1.5))
                }
            }

            Button("Skip") { store.cancelCorrection() }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.disc, lineWidth: 1.5))
    }
}
