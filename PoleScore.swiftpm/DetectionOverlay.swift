import SwiftUI

/// Boxes drawn over the live preview.
///
/// The geometry here is the whole reason `DetectionCoordinateMapper` exists.
/// The preview layer is `.resizeAspectFill`, so the video is scaled up until it
/// covers the view and the overflow is cropped — on a 16:9 buffer in a
/// portrait-ish view that is a large slice off the top and bottom. Multiplying
/// normalized coordinates by the view size, which is the obvious thing to write
/// and what the old debug overlay did, squashes every box by exactly the amount
/// that was cropped. The error is worst at the edges of the frame, which is
/// where the poles are, so it looks fine in the middle and wrong exactly where
/// it matters.
struct DetectionOverlay: View {
    let detections: [YOLODetection]
    let videoSize: CGSize
    var gravity: DetectionCoordinateMapper.Gravity = .aspectFill

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(detections) { detection in
                    let rect = DetectionCoordinateMapper.viewRect(
                        forVisionBox: detection.boundingBox,
                        videoSize: videoSize,
                        viewSize: geometry.size,
                        gravity: gravity)

                    if rect.width > 1, rect.height > 1 {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(color(for: detection.label), lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)

                        Text("\(shortName(detection.label)) \(Int(detection.confidence * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.field)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(color(for: detection.label)))
                            // Pin the label inside the view when the box runs
                            // off the top, which happens constantly under
                            // aspect-fill crop.
                            .position(x: rect.midX, y: max(10, rect.minY - 9))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func shortName(_ label: String) -> String {
        DetectionBridge.canonical(label) ?? label
    }

    private func color(for label: String) -> Color {
        switch DetectionBridge.canonical(label) {
        case "frisbee": return Theme.disc
        case "bottle": return Theme.glass
        case "pole": return Theme.chalk
        case "person": return Theme.flag
        case "ground": return Theme.muted
        default: return Theme.alert
        }
    }
}

/// Developer diagnostics. Off unless the developer overlay is switched on, and
/// compiled out of release builds entirely.
struct DetectorDebugHUD: View {
    let diagnostics: DetectorDiagnostics
    let videoSize: CGSize

    var body: some View {
        #if DEBUG
        VStack(alignment: .leading, spacing: 1) {
            row("status", diagnostics.status.text)
            row("infer", String(format: "%.1f / %.0f fps", diagnostics.measuredFPS, diagnostics.targetFPS))
            row("last", String(format: "%.1f ms", diagnostics.lastInferenceMilliseconds))
            row("objects", "\(diagnostics.detectionCount)")
            row("thermal", diagnostics.thermalText)
            row("buffer", "\(Int(videoSize.width))x\(Int(videoSize.height))")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(Theme.chalk)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field.opacity(0.75)))
        .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(Theme.muted)
            Text(value)
        }
    }
}
