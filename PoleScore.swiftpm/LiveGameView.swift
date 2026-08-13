import SwiftUI
import UIKit

struct LiveGameView: View {
    @EnvironmentObject var store: GameStore
    @EnvironmentObject var camera: CameraController
    @State private var now = Date()
    @State private var zooming = false
    @State private var showZoomBadge = false
    @State private var zoomBadgeTask: Task<Void, Never>?

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if camera.authorized {
                CameraPreview(controller: camera).ignoresSafeArea()
            } else {
                Theme.field.ignoresSafeArea()
            }

            if store.showDetectionOverlay {
                DetectionOverlay(detections: camera.modelDetections,
                                 videoSize: camera.videoResolution)
                    .ignoresSafeArea()
            }

            if store.showDebug {
                GeometryReader { geo in
                    DebugOverlay(tracks: camera.tracks,
                                 court: camera.court,
                                 videoSize: camera.videoResolution,
                                 size: geo.size)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        Spacer()
                        DetectorDebugHUD(diagnostics: camera.diagnostics,
                                         videoSize: camera.videoResolution)
                            .padding(.top, 60)
                            .padding(.trailing, 12)
                    }
                    Spacer()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer()
                scoreboard
                Spacer()
                bottomBar
            }
            .padding(16)

            if showZoomBadge {
                Text(String(format: "%.1f×", camera.zoom))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.chalk)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.field.opacity(0.7)))
                    .overlay(Capsule().stroke(Theme.edge, lineWidth: 1.5))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Pinch anywhere on the preview, exactly like the camera app, so the
        // phone can sit where it is convenient instead of being walked
        // backwards until both poles fit in frame. Double-tap snaps 1× / 2×.
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    if !zooming {
                        zooming = true
                        camera.beginZoomGesture()
                    }
                    camera.updateZoomGesture(scale: value.magnification)
                    flashZoomBadge()
                }
                .onEnded { _ in zooming = false }
        )
        .onTapGesture(count: 2) {
            camera.toggleZoom()
            flashZoomBadge()
        }
        .background(Theme.field)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(tick) { now = $0 }
        .onAppear {
            applyMode(store.mode)
            camera.machine.config.confidenceThreshold = store.confidence
            camera.machine.applyTuning(store.tuning)
            camera.onOutcome = { outcome in
                store.handle(outcome: outcome)
            }
            camera.resetTracking()
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomBadgeTask?.cancel()
            camera.stop()
        }
        .onChange(of: store.mode) { _, new in applyMode(new) }
        .onChange(of: store.confidence) { _, new in camera.machine.config.confidenceThreshold = new }
    }

    private func applyMode(_ mode: ScoringMode) {
        camera.scoringEnabled = mode != .manual
        // Automatic mode never blocks on a person, so the wait for a knocked
        // bottle to be replaced resolves itself instead of parking the game
        // behind a button nobody is standing next to.
        camera.machine.config.autoResumeBottleReset = mode == .auto
    }

    private func flashZoomBadge() {
        zoomBadgeTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { showZoomBadge = true }
        zoomBadgeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { showZoomBadge = false }
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(camera.status.text).font(.caption.weight(.bold)).kerning(1.2)
                    Text("\(Int(camera.analysisFPS)) fps · \(camera.blobCount) \(camera.detectorStatus.isRunnable ? "objects" : "lit") · \(String(format: "%.1f×", camera.zoom))")
                        .font(.caption.monospaced()).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.panel.opacity(0.85)))
                .overlay(Capsule().stroke(statusColor, lineWidth: 1.5))
                .foregroundStyle(statusColor)

                Text(store.mode.title.uppercased())
                    .font(.caption.weight(.bold)).kerning(1.4)
                    .foregroundStyle(store.mode == .auto ? Theme.glass : Theme.muted)

                Spacer()
            }

            // The court readout replaced six taps of setup. It is deliberately
            // a statement, not a question — there is nothing here to confirm.
            HStack(spacing: 6) {
                Image(systemName: camera.courtReady ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.caption2)
                Text(camera.courtReady ? "Court set · \(camera.courtSummary)" : camera.courtSummary)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(camera.courtReady ? Theme.muted : Theme.disc)

            // The detector says so itself when it is missing or throttled, so a
            // silent fallback to the glow pipeline is never mistaken for the
            // model quietly doing a bad job.
            if !camera.detectorStatus.isRunnable {
                Text(detectorNotice)
                    .font(.caption2)
                    .foregroundStyle(camera.detectorStatus == .pausedThermal ? Theme.alert : Theme.muted)
                    .lineLimit(2)
            }
        }
    }

    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 18) {
                teamColumn(.A)
                Text("/").font(.system(size: 60, weight: .heavy)).foregroundStyle(Theme.edge)
                teamColumn(.B)
            }
            if let notice = camera.notice {
                Text(notice)
                    .font(.headline).foregroundStyle(Theme.flag)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.opacity(0.9)))
            }
            if let winner = store.winner {
                Text("\(store.name(winner)) wins")
                    .font(.title.weight(.bold)).foregroundStyle(Theme.disc)
            }
        }
    }

    private func teamColumn(_ team: TeamId) -> some View {
        VStack(spacing: 2) {
            Text("\(store.scores[team])")
                .font(.system(size: 96, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.teamColor(team))
                .shadow(color: .black.opacity(0.8), radius: 8)
            Text(store.name(team).uppercased())
                .font(.caption.weight(.bold)).kerning(2)
                .foregroundStyle(store.thrower == team ? Theme.chalk : Theme.muted)
            Capsule()
                .fill(store.thrower == team ? Theme.teamColor(team) : Color.clear)
                .frame(width: 46, height: 4)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Ask-first and Tap-only keep their pads. Automatic shows neither,
            // ever — that is the whole difference between the modes.
            if store.mode == .assist {
                if let correcting = store.correcting {
                    CorrectionPad(outcome: correcting)
                } else if let pending = store.pending {
                    ConfirmCard(outcome: pending)
                }
            }
            if store.mode == .manual {
                ManualPad()
            }

            if let until = store.undoUntil, until > now {
                HStack {
                    Text(store.plays.last?.banner ?? "Scored")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Button("Undo") { store.undoLast() }
                        .font(.headline)
                        .foregroundStyle(Theme.flag)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .overlay(Capsule().stroke(Theme.flag, lineWidth: 1.5))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }

            HStack(spacing: 10) {
                Button("Undo") { store.undoLast() }
                    .buttonStyle(.bordered).tint(Theme.flag)
                Button(camera.running ? "Pause" : "Resume") {
                    camera.running ? camera.stop() : camera.start()
                }
                .buttonStyle(.bordered)
                // Automatic mode resolves this on its own, so the button is not
                // offered there — it would be a question, and Automatic mode
                // does not ask questions.
                if camera.status == .resetBottle, store.mode != .auto {
                    Button("Bottle is back on") { camera.machine.confirmBottleReset() }
                        .buttonStyle(.borderedProminent).tint(Theme.disc)
                }
                Spacer()
                Button("Recentre") { camera.rediscoverCourt() }
                    .buttonStyle(.bordered)
                Button("New game") { store.newGame() }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var detectorNotice: String {
        switch camera.detectorStatus {
        case .modelMissing:
            return "YOLO model missing from app bundle — scoring from glow brightness instead"
        case .loading:
            return "Loading the detector…"
        case .pausedThermal:
            return "AI paused: device too hot — scoring from glow brightness instead"
        case .pausedBackground:
            return "Detector paused"
        case .failed(let reason):
            return "Detector failed (\(reason)) — scoring from glow brightness instead"
        case .idle, .ready:
            return ""
        }
    }

    private var statusColor: Color {
        switch camera.status {
        case .watching, .paused: return Theme.muted
        case .trackingDisc: return Theme.disc
        case .scoringPlay: return Theme.glass
        case .lowConfidence, .resetBottle: return Theme.flag
        }
    }
}

/// Assist mode: the app proposes, you decide. Two large targets, no reading
/// beyond the banner.
struct ConfirmCard: View {
    @EnvironmentObject var store: GameStore
    let outcome: PlayOutcome

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.events.map(\.shortLabel).joined(separator: " + "))
                    .font(.headline)
                Text("\(Int(outcome.confidence * 100))% confidence · \(outcome.reasons.first ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer()
            Button("No") { store.reject(outcome: outcome) }
                .buttonStyle(.bordered)
            Button("Score it") { store.confirm(outcome: outcome) }
                .buttonStyle(.borderedProminent).tint(Theme.disc)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.disc, lineWidth: 1.5))
    }
}

/// The floor under everything else: whatever the camera does, the game stays
/// scorable with two taps.
struct ManualPad: View {
    @EnvironmentObject var store: GameStore

    private struct PadKey: Identifiable {
        let id: ScoreEvent
        let points: Int
    }

    private var scoringEvents: [PadKey] {
        store.rules.events
            .filter { $0.value.points > 0 }
            .map { PadKey(id: $0.key, points: $0.value.points) }
            .sorted { $0.points < $1.points }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.thrower = store.thrower.other
            } label: {
                VStack(spacing: 2) {
                    Text("THROWING").font(.caption2.weight(.bold)).kerning(1.2).foregroundStyle(Theme.muted)
                    Text(store.name(store.thrower)).font(.headline)
                }
                .frame(minWidth: 104)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.edge, lineWidth: 1.5))

            ForEach(scoringEvents) { key in
                Button {
                    store.scoreManually(key.id)
                } label: {
                    VStack(spacing: 2) {
                        Text("+\(key.points)").font(.title2.weight(.heavy)).monospacedDigit()
                            .foregroundStyle(Theme.disc)
                        Text(key.id.shortLabel).font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.chalk)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.disc, lineWidth: 1.5))
            }
        }
    }
}

/// Developer view only — normal play shows a clean preview.
struct DebugOverlay: View {
    let tracks: [Track]
    let court: Court?
    let videoSize: CGSize
    let size: CGSize

    /// Normalized app coordinates to view points, honouring the preview's
    /// aspect-fill crop. This used to be a plain multiply by the view size,
    /// which squashed every box by exactly the amount the preview had cropped
    /// away — worst at the left and right edges, which is where the poles are.
    private func rect(_ box: Box) -> CGRect {
        DetectionCoordinateMapper.viewRect(
            forTopLeftNormalized: CGRect(x: box.x, y: box.y, width: box.w, height: box.h),
            videoSize: videoSize, viewSize: size, gravity: .aspectFill)
    }

    private func point(_ p: Pt) -> CGPoint {
        DetectionCoordinateMapper.viewPoint(
            forTopLeftNormalized: CGPoint(x: p.x, y: p.y),
            videoSize: videoSize, viewSize: size, gravity: .aspectFill)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let court {
                Path { path in
                    path.move(to: point(court.groundA))
                    path.addLine(to: point(court.groundB))
                }
                .stroke(Theme.flag.opacity(0.7), lineWidth: 1.5)
            }

            ForEach(tracks) { track in
                let rect = rect(track.box)
                Rectangle()
                    .stroke(color(track.label), lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text("\(track.label.rawValue) #\(track.id)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(color(track.label))
                    .position(x: rect.midX, y: max(8, rect.minY - 8))
            }
        }
    }

    private func color(_ label: Label) -> Color {
        switch label {
        case .disc: return Theme.disc
        case .leftBottle, .rightBottle: return Theme.glass
        case .leftPole, .rightPole: return Theme.chalk
        case .player: return Theme.flag
        }
    }
}
