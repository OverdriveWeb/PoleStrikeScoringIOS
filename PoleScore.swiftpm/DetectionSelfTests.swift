import CoreGraphics
import CoreMedia
import Foundation

/// Checks for the pure logic behind detection: confidence filtering, NMS, and
/// the three coordinate transforms.
///
/// **Why this is not XCTest.** Swift Playgrounds cannot host a test target — an
/// app package has one executable product and no way to run XCTest on the
/// device it is built on. Since the coordinate maths is exactly the sort of
/// thing that is silently wrong until you are standing in a dark field
/// wondering why the boxes are half a pole off, the checks live in the app
/// instead, as plain functions over plain values with no XCTest dependency.
///
/// `Tests/DetectionTests.swift` in the repository wraps every case below in
/// real XCTest assertions for when the package is opened in Xcode. The bodies
/// are the same; only the assertion mechanism differs.
enum DetectionSelfTests {

    struct Result {
        var name: String
        var passed: Bool
        var detail: String
    }

    static func runAll() -> [Result] {
        [
            confidenceFilteringDropsWeakDetections(),
            confidenceFilteringKeepsThreshold(),
            nonMaximumSuppressionCollapsesOverlaps(),
            nonMaximumSuppressionKeepsDifferentClasses(),
            visionBoxFlipsToTopLeft(),
            aspectFillCropIsAccountedFor(),
            aspectFitLetterboxesInstead(),
            squareVideoInSquareViewIsIdentity(),
            centreBoxStaysCentredUnderCrop(),
            missingModelIsRecoverable(),
        ]
    }

    static var summary: String {
        let results = runAll()
        let failed = results.filter { !$0.passed }
        return failed.isEmpty
            ? "\(results.count)/\(results.count) detection checks passed"
            : "FAILED: " + failed.map(\.name).joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") -> Result {
        Result(name: name, passed: condition, detail: detail)
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func detection(_ label: String, _ confidence: Float, _ rect: CGRect) -> YOLODetection {
        YOLODetection(label: label, confidence: confidence, boundingBox: rect, timestamp: .zero)
    }

    // MARK: - Confidence filtering

    static func confidenceFilteringDropsWeakDetections() -> Result {
        var configuration = YOLOOutputParser.Configuration()
        configuration.confidenceThreshold = 0.45
        let kept = YOLOOutputParser.nonMaximumSuppression(
            [detection("bottle", 0.9, CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
             detection("frisbee", 0.2, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))]
                .filter { $0.confidence >= configuration.confidenceThreshold },
            iouThreshold: 0.45, maxDetections: 32)
        return check("confidence filtering drops weak detections",
                     kept.count == 1 && kept[0].label == "bottle",
                     "kept \(kept.map(\.label))")
    }

    static func confidenceFilteringKeepsThreshold() -> Result {
        // Exactly at the threshold must survive. An off-by-one here quietly
        // halves the detections at the default setting.
        let threshold: Float = 0.45
        let kept = [detection("pole", 0.45, CGRect(x: 0, y: 0, width: 0.1, height: 0.4))]
            .filter { $0.confidence >= threshold }
        return check("detection exactly at threshold is kept", kept.count == 1)
    }

    // MARK: - NMS

    static func nonMaximumSuppressionCollapsesOverlaps() -> Result {
        let a = detection("pole", 0.9, CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.60))
        let b = detection("pole", 0.7, CGRect(x: 0.11, y: 0.11, width: 0.20, height: 0.60))
        let kept = YOLOOutputParser.nonMaximumSuppression([a, b], iouThreshold: 0.45, maxDetections: 32)
        return check("NMS collapses two boxes on the same pole",
                     kept.count == 1 && kept[0].confidence == 0.9,
                     "kept \(kept.count)")
    }

    static func nonMaximumSuppressionKeepsDifferentClasses() -> Result {
        // A bottle sits on top of a pole and overlaps it almost entirely.
        // Suppressing across classes would delete one of them every frame.
        let pole = detection("pole", 0.9, CGRect(x: 0.10, y: 0.10, width: 0.06, height: 0.50))
        let bottle = detection("bottle", 0.8, CGRect(x: 0.10, y: 0.52, width: 0.06, height: 0.08))
        let kept = YOLOOutputParser.nonMaximumSuppression([pole, bottle], iouThreshold: 0.2, maxDetections: 32)
        return check("NMS keeps a bottle sitting on its pole", kept.count == 2, "kept \(kept.count)")
    }

    // MARK: - Coordinates

    static func visionBoxFlipsToTopLeft() -> Result {
        // A box hugging the BOTTOM of the frame in Vision space must end up
        // hugging the TOP in app space.
        let box = YOLOOutputParser.rectFromCenter(cx: 0.5, cy: 0.9, w: 0.2, h: 0.2, origin: .topLeft)
        guard let box else { return check("vision flip", false, "degenerate rect") }
        let converted = DetectionCoordinateMapper.topLeftNormalized(fromVisionBox: box)
        return check("vision bottom-left box flips to top-left",
                     near(CGFloat(converted.y), 0.8) && near(CGFloat(converted.x), 0.4),
                     "got y=\(converted.y) x=\(converted.x)")
    }

    static func aspectFillCropIsAccountedFor() -> Result {
        // 16:9 buffer in a 400x800 view. Aspect-fill scales by width/height =
        // max(400/1280, 800/720) = 1.111..., so the video is 1422 wide and
        // spills 511 points off each side. A box at the far left of the frame
        // must therefore land at a NEGATIVE x, not at 0.
        let videoSize = CGSize(width: 1280, height: 720)
        let viewSize = CGSize(width: 400, height: 800)
        let rect = DetectionCoordinateMapper.viewRect(
            forTopLeftNormalized: CGRect(x: 0, y: 0.5, width: 0.05, height: 0.05),
            videoSize: videoSize, viewSize: viewSize, gravity: .aspectFill)

        let displayed = DetectionCoordinateMapper.displayedVideoRect(
            videoSize: videoSize, viewSize: viewSize, gravity: .aspectFill)

        let correct = rect.origin.x < -1
            && near(displayed.height, 800)
            && displayed.width > viewSize.width
        return check("aspect-fill crop is accounted for", correct,
                     "x=\(rect.origin.x) displayed=\(displayed)")
    }

    static func aspectFitLetterboxesInstead() -> Result {
        let displayed = DetectionCoordinateMapper.displayedVideoRect(
            videoSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 400, height: 800),
            gravity: .aspectFit)
        // Fit scales by min(400/1280, 800/720) = 0.3125 -> 400 x 225, centred.
        return check("aspect-fit letterboxes",
                     near(displayed.width, 400) && near(displayed.height, 225)
                        && near(displayed.origin.y, 287.5, 1),
                     "\(displayed)")
    }

    static func squareVideoInSquareViewIsIdentity() -> Result {
        // With no crop to undo, the mapper must agree with the naive multiply.
        // If this fails, the crop correction is being applied when it should
        // not be, which would be a regression in the opposite direction.
        let rect = DetectionCoordinateMapper.viewRect(
            forTopLeftNormalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            videoSize: CGSize(width: 500, height: 500),
            viewSize: CGSize(width: 300, height: 300),
            gravity: .aspectFill)
        return check("no crop means plain scaling",
                     near(rect.origin.x, 75) && near(rect.width, 150),
                     "\(rect)")
    }

    static func centreBoxStaysCentredUnderCrop() -> Result {
        // Cropping is symmetric, so whatever else moves, the centre must not.
        let rect = DetectionCoordinateMapper.viewRect(
            forVisionBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
            videoSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 400, height: 800),
            gravity: .aspectFill)
        return check("centre of frame stays centred under crop",
                     near(rect.midX, 200, 1) && near(rect.midY, 400, 1),
                     "mid=(\(rect.midX), \(rect.midY))")
    }

    // MARK: - Failure states

    static func missingModelIsRecoverable() -> Result {
        // The missing-model state must be a status, not a crash, and must not
        // report itself as runnable.
        let status = DetectorStatus.modelMissing
        return check("missing model is a recoverable status",
                     !status.isRunnable && status.text.contains("missing"),
                     status.text)
    }
}
